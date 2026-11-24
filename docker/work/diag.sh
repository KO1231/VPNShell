#!/bin/bash
# VPNShell: work コンテナ内の追加の診断 (起動前チェックに通ったあとで、entrypoint.sh から呼ばれる)
#
#   diag.sh full   漏れの実地検査 (VPN を通らない経路で外に出られないことを、実際に送って確かめる)
#   diag.sh mtu    MTU の診断 (分割禁止の ping で、トンネルを通る最大の大きさを調べる)
#
# 入力 (環境変数):
#   EXPECTED_PUBLIC_IP   専用IP
#   VPNSH_LAN_ADDRS      Mac 側の LAN のアドレス (Mac 自身・ルーター。空白区切り。届かないことを確かめる)
#   VPNSH_EP_IP / VPNSH_EP_PORT  VPN の接続先 (WireGuard 以外では届かないことを確かめる)
# 結果は stderr に [OK] / [NG] / [--] (確かめられなかった) で出す。NG が1つでもあれば 1、なければ 0 で終わる
# ([--] は失敗としない。最後のまとめで件数を出す)
set -u

FAILED=0
ok() { printf 'vpnsh: \033[32m[OK]\033[0m %s\n' "$*" >&2; }
ng() { FAILED=1; printf 'vpnsh: \033[31m[NG]\033[0m %s\n' "$*" >&2; }
na() { printf 'vpnsh: [--] %s\n' "$*" >&2; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# tcp_try <eth0|-> <IP> <ポート>  TCP 接続を試みる (eth0: eth0 を直接指定して、トンネルを通さずに / -: 普通の経路で)
#   0 = つながった / 4 = 拒否された (RST が返った = 相手に届いている) / 1 = 遮断された・届かない / 2,3 = ソケットを作れない
#   遮断ルールの DROP に当たった接続は、時間切れ (2秒) まで待つ。検査は並列に走らせて全体の時間を抑える
tcp_try() {
	perl -MSocket -MIO::Select -MErrno=EINPROGRESS,ECONNREFUSED -e '
		my ($dev, $ip, $port) = @ARGV;
		socket(my $s, AF_INET, SOCK_STREAM, 0) or exit 2;
		if ($dev ne "-") { setsockopt($s, SOL_SOCKET, 25, pack("Z*", $dev)) or exit 3 }    # SO_BINDTODEVICE
		my $fl = fcntl($s, 3, 0); fcntl($s, 4, $fl | 04000);               # O_NONBLOCK
		unless (connect($s, sockaddr_in($port, inet_aton($ip)))) {
			exit 4 if $! == ECONNREFUSED;
			exit 1 unless $! == EINPROGRESS;
		}
		my $w = IO::Select->new($s);
		exit 1 unless $w->can_write(2);
		my $err = unpack("i", getsockopt($s, SOL_SOCKET, SO_ERROR));
		exit 0 if $err == 0;
		exit 4 if $err == ECONNREFUSED;
		exit 1;
	' "$1" "$2" "$3"
}
# reached <eth0|-> <IP>  よく使うポート (22, 80, 443) と ping を同時に試す
#   0 = どれかが届いた (届いた方法を出す) / 1 = どれも届かない / 2 = どれも試せなかった (ソケットを作れないなど)
#   eth0 を指定したときは、ping も eth0 を指定して送る (普通の経路の ping はトンネルに入るので、Mac の LAN の検査にならない)
reached() {
	local dev="$1" ip="$2" d p hit="" tried=""
	d="$(mktemp -d /tmp/vpnsh-reach.XXXXXX)"
	for p in 22 80 443; do
		(
			tcp_try "$dev" "$ip" "$p"; r=$?
			case "$r" in
				0 | 4) : >"$d/hit.$p" ;;
				1) : >"$d/tried.$p" ;;
			esac
		) &
	done
	(
		if [ "$dev" = "-" ]; then ping -c 1 -W 2 "$ip"; else ping -I "$dev" -c 1 -W 2 "$ip"; fi >/dev/null 2>&1
		case $? in
			0) : >"$d/hit.ping" ;;
			1) : >"$d/tried.ping" ;;    # 2 以上は ping のエラー (送れなかった)
		esac
	) &
	wait
	for p in "$d"/*; do
		case "$p" in
			*/hit.*) [ -z "$hit" ] && hit="${p##*/hit.}" ;;
			*/tried.*) tried=1 ;;
		esac
	done
	rm -f "$d"/*; rmdir "$d"
	if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
	[ -n "$tried" ] && return 1
	return 2
}
# dns_eth0 <IP>  eth0 を直接指定して DNS の問い合わせを送る
#   0 = 応答があった (外に出られる) / 5 = 送信が遮断ルールで止められた (EPERM。遮断を確認できた) /
#   1 = 送れたが応答がない (遮断を確認できない) / 2,3 = ソケットを作れない
dns_eth0() {
	perl -MSocket -MIO::Select -MErrno=EPERM -e '
		my ($ip) = @ARGV;
		socket(my $s, AF_INET, SOCK_DGRAM, 0) or exit 2;
		setsockopt($s, SOL_SOCKET, 25, pack("Z*", "eth0")) or exit 3;
		# example.com の A レコードの問い合わせ
		my $q = pack("n n n n n n", 0x1234, 0x0100, 1, 0, 0, 0) . "\x07example\x03com\x00" . pack("n n", 1, 1);
		for (1 .. 2) {
			# 遮断ルール (OUTPUT の DROP) に当たると、送信はその場で EPERM になる
			unless (defined send($s, $q, 0, sockaddr_in(53, inet_aton($ip)))) { exit($! == EPERM ? 5 : 1); }
		}
		my $r = IO::Select->new($s);
		exit($r->can_read(2) ? 0 : 1);
	' "$1"
}

# ---- 漏れの実地検査の各項目 (並列に実行し、結果は決まった順に表示する) ----

# Docker の組み込み DNS (Mac 側へ転送される) は拒否される
chk_docker_dns() {
	if dig +time=1 +tries=1 @127.0.0.11 example.com >/dev/null 2>&1; then
		ng "Docker の組み込み DNS (127.0.0.11) に問い合わせできました (Mac 側の DNS に漏れます)"
	else
		ok "Docker の組み込み DNS (127.0.0.11) には問い合わせできない"
	fi
}
# 外の DNS サーバーから見た問い合わせ元が専用IPであること (DNS も VPN を通っている)
chk_dns_source() {
	local out
	out="$(dig +short +time=2 +tries=2 TXT CH whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"' | head -n 1)"
	if ! is_ipv4 "$out"; then
		na "DNS の問い合わせ元を確かめられませんでした (whoami.cloudflare の応答なし)"
	elif [ "$out" = "${EXPECTED_PUBLIC_IP:-}" ]; then
		ok "DNS の問い合わせも専用IP ($out) から出ている"
	else
		ng "DNS の問い合わせ元が専用IPではありません (${out}。期待値 ${EXPECTED_PUBLIC_IP:-未設定})"
	fi
}
# Mac や Docker のローカルな名前が、Mac 側のアドレスに解決されないこと (解決されても届かなければよい)
chk_name() {
	local name="$1" out addr n=0
	out="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
	if [ -z "$out" ]; then
		ok "$name は解決されない"
		return
	fi
	for addr in $out; do
		reached - "$addr" >/dev/null && n=$((n + 1))
		reached eth0 "$addr" >/dev/null && n=$((n + 1))
	done
	if [ "$n" -eq 0 ]; then ok "$name は ${out% } に解決されるが、届かない"; else ng "$name (${out% }) に届きました (Mac 側に通信できます)"; fi
}
# コンテナの eth0 のゲートウェイ (OrbStack の VM / Mac 側) に届かないこと
chk_gateway() {
	local gw ifc dst h r
	gw="$(ip -4 route show table all default dev eth0 2>/dev/null | awk '$2 == "via" { print $3; exit }')"
	if [ -z "$gw" ]; then
		# /proc/net/route のゲートウェイは 16 進数のリトルエンディアン
		while read -r ifc dst h _; do
			if [ "$ifc" = "eth0" ] && [ "$dst" = "00000000" ] && [ "${#h}" -eq 8 ]; then
				gw="$((16#${h:6:2})).$((16#${h:4:2})).$((16#${h:2:2})).$((16#${h:0:2}))"
			fi
		done </proc/net/route
	fi
	if ! is_ipv4 "$gw"; then
		na "eth0 のゲートウェイが分かりませんでした"
		return
	fi
	# 普通の経路と eth0 の直接指定を同時に試す (どちらも遮断されていれば時間切れまで待つので、順番にすると倍かかる)
	local d rc1 rc2 r1 r2
	d="$(mktemp -d /tmp/vpnsh-gw.XXXXXX)"
	( reached - "$gw" >"$d/r1"; echo $? >"$d/c1" ) &
	( reached eth0 "$gw" >"$d/r2"; echo $? >"$d/c2" ) &
	wait
	rc1="$(cat "$d/c1")"; rc2="$(cat "$d/c2")"; r1="$(cat "$d/r1")"; r2="$(cat "$d/r2")"
	rm -f "$d"/*; rmdir "$d"
	if [ "$rc1" = "0" ]; then
		ng "eth0 のゲートウェイ ($gw:$r1) に届きました"
	elif [ "$rc2" = "0" ]; then
		ng "eth0 のゲートウェイ ($gw:$r2) に eth0 から届きました"
	elif [ "$rc1" = "2" ] && [ "$rc2" = "2" ]; then
		na "eth0 のゲートウェイ ($gw) への到達を確かめられませんでした (ソケットを作れない)"
	else
		ok "eth0 のゲートウェイ ($gw) には届かない"
	fi
}
# Mac のアドレス (Mac 自身・ルーター・OrbStack のブリッジなど) に、eth0 から (トンネルを通さずに) 届かないこと。
# すべて同時に試し、問題が無ければ1行にまとめて出す
chk_lan() {
	local d addr i=0 rc r list="" bad=0 untested=""
	d="$(mktemp -d /tmp/vpnsh-lan.XXXXXX)"
	for addr in "$@"; do
		i=$((i + 1))
		( reached eth0 "$addr" >"$d/$i.r"; echo $? >"$d/$i.c" ) &
	done
	wait
	i=0
	for addr in "$@"; do
		i=$((i + 1))
		rc="$(cat "$d/$i.c")"; r="$(cat "$d/$i.r")"
		case "$rc" in
			0) ng "Mac のアドレス ($addr:$r) に eth0 から届きました"; bad=1 ;;
			2) untested="$untested $addr" ;;
			*) list="$list $addr" ;;
		esac
	done
	rm -f "$d"/*; rmdir "$d"
	# shellcheck disable=SC2086  # 空白区切りの一覧を数える
	[ -n "$list" ] && ok "Mac のアドレス $(set -- $list; echo $#) 個 (${list# }) には、どれも届かない"
	[ -n "$untested" ] && na "Mac のアドレス (${untested# }) への到達を確かめられませんでした (ソケットを作れない)"
	return "$bad"
}
# トンネルを通さずに (eth0 を直接指定して) 外に出られないこと
chk_eth0_tcp() {
	tcp_try eth0 1.1.1.1 443; case $? in
		0 | 4) ng "eth0 を直接指定して 1.1.1.1:443 に届きました (VPN を通らずに外に出られます)" ;;
		1) ok "eth0 を直接指定した TCP (1.1.1.1:443) は届かない" ;;
		*) na "eth0 を直接指定した TCP を確かめられませんでした (ソケットを作れない)" ;;
	esac
}
chk_eth0_udp() {
	dns_eth0 1.1.1.1; case $? in
		0) ng "eth0 を直接指定した DNS の問い合わせ (1.1.1.1:53) に応答がありました (VPN を通らずに外に出られます)" ;;
		5) ok "eth0 を直接指定した UDP (1.1.1.1:53) は遮断ルールで送信が止められる" ;;
		1) na "eth0 を直接指定した UDP (1.1.1.1:53) には応答がないが、送信が止められたことは確かめられませんでした" ;;
		*) na "eth0 を直接指定した UDP を確かめられませんでした (ソケットを作れない)" ;;
	esac
}
# VPN の接続先には、WireGuard 以外 (TCP) では届かないこと
chk_endpoint() {
	tcp_try eth0 "$VPNSH_EP_IP" 443; case $? in
		0 | 4) ng "VPN の接続先 ($VPNSH_EP_IP) に eth0 から TCP で接続できました" ;;
		1) ok "VPN の接続先 ($VPNSH_EP_IP) には、eth0 から WireGuard 以外では届かない" ;;
		*) na "VPN の接続先への到達を確かめられませんでした (ソケットを作れない)" ;;
	esac
}
# IPv6 で外に出られないこと
chk_ipv6() {
	if curl -6 -s -o /dev/null --connect-timeout 2 --max-time 3 'https://[2606:4700:4700::1111]/' 2>/dev/null; then
		ng "IPv6 で外に出られました"
	else
		ok "IPv6 では外に出られない"
	fi
}

diag_full() {
	local dir n=0 addr own lan=() ng_n na_n
	dir="$(mktemp -d /tmp/vpnsh-diag.XXXXXX)"
	# job <関数> [引数...]  バックグラウンドで実行し、結果を番号順のファイルに書く
	job() { n=$((n + 1)); ("$@") >"$dir/$(printf '%03d' "$n")" 2>&1 & }
	job chk_docker_dns
	job chk_dns_source
	job chk_name host.docker.internal
	job chk_name host.orb.internal
	job chk_gateway
	# コンテナ自身のアドレス (Mac で NordVPN アプリなどを使っていると、Mac の VPN のアドレスが tun0 と同じになることがある)
	own=" $(ip -4 -o addr show 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }' | tr '\n' ' ') "
	for addr in ${VPNSH_LAN_ADDRS:-}; do
		is_ipv4 "$addr" || continue
		case "$own" in
			*" $addr "*) job na "Mac のアドレス $addr はコンテナ自身のアドレスと同じなので調べません (Mac で NordVPN アプリなどの VPN を使っていると起こります)" ;;
			*) lan+=("$addr") ;;
		esac
	done
	if [ "${#lan[@]}" -gt 0 ]; then
		job chk_lan "${lan[@]}"
	elif [ -z "${VPNSH_LAN_ADDRS:-}" ]; then
		job na "Mac のアドレスが渡されていないので、Mac・LAN への到達は確かめていません"
	fi
	job chk_eth0_tcp
	job chk_eth0_udp
	is_ipv4 "${VPNSH_EP_IP:-}" && job chk_endpoint
	job chk_ipv6
	wait
	cat "$dir"/* >&2
	ng_n="$(cat "$dir"/* | grep -c '\[NG\]')"
	na_n="$(cat "$dir"/* | grep -c '\[--\]')"
	rm -f "$dir"/*; rmdir "$dir"
	echo >&2
	if [ "$ng_n" -gt 0 ]; then
		FAILED=1
		printf 'vpnsh: \033[31m漏れの実地検査: NG %s 件\033[0m (確かめられなかったもの %s 件)\n' "$ng_n" "$na_n" >&2
		printf 'vpnsh:   → このシェルは使わないでください。vpnsh up --recreate で gluetun を作り直してから、もう一度 vpnsh check --full を実行してください\n' >&2
		printf 'vpnsh:   → 続く場合は vpnsh doctor と vpnsh -v check で、遮断ルールや設定を確かめてください\n' >&2
	else
		printf 'vpnsh: 漏れの実地検査: NG 0 件 (確かめられなかったもの %s 件)\n' "$na_n" >&2
	fi
	return "$FAILED"
}

# ping_ok <大きさ> <宛先>  分割禁止で1回ずつ送り、返れば 0 (3回まで。返った時点で終わる)
ping_ok() {
	local i
	for i in 1 2 3; do
		ping -M "do" -s "$1" -c 1 -W 2 -q "$2" >/dev/null 2>&1 && return 0
	done
	return 1
}

diag_mtu() {
	local mtu target="" t lo hi mid best
	mtu="$(cat /sys/class/net/tun0/mtu 2>/dev/null)"
	case "$mtu" in "" | *[!0-9]*) ng "トンネル (tun0) の MTU が分かりません"; return 1 ;; esac
	printf 'vpnsh: トンネルの MTU は %s です。分割禁止の ping で確かめます (問題がなければ数秒、問題があれば最大30秒ほどかかります)\n' "$mtu" >&2
	for t in 1.1.1.1 8.8.8.8; do
		if ping_ok "$((mtu - 28))" "$t"; then
			ok "MTU $mtu ($((mtu - 28)) バイトの ping) は分割されずに $t まで届きます"
			printf 'vpnsh:   (確かめたのは %s までの経路だけです。特定のサイトだけ固まる場合は vpnsh config set mtu 1280 を試してください)\n' "$t" >&2
			return 0
		fi
	done
	# 小さな ping が返る宛先を、このあとの探索に使う (1.1.1.1 が ping に応答しない環境もあるため)
	for t in 1.1.1.1 8.8.8.8; do
		if ping_ok 56 "$t"; then target="$t"; break; fi
	done
	if [ -z "$target" ]; then
		na "小さな ping も返りません (宛先が ping に応答しない、または VPN の通信の問題)。MTU は判定できません"
		return 0
	fi
	# 届く最大の大きさを二分探索する (1280 未満は WireGuard / IPv6 の最低値を下回るので調べない)
	lo=1252 hi=$((mtu - 29)) best=""
	ping_ok "$lo" "$target" && best="$lo"
	if [ -z "$best" ]; then
		ng "MTU 1280 でも分割されずに届きません。回線側の問題の可能性があります"
		return 1
	fi
	while [ "$lo" -lt "$hi" ]; do
		mid=$(((lo + hi + 1) / 2))
		if ping_ok "$mid" "$target"; then lo="$mid"; best="$mid"; else hi=$((mid - 1)); fi
	done
	ng "MTU $mtu では大きなパケットが届きません (届く最大は MTU $((best + 28)))。\`vpnsh config set mtu $((best + 28))\` で下げてください"
	return 1
}

case "${1:-}" in
	full) diag_full ;;
	mtu) diag_mtu ;;
	*) echo "vpnsh: diag.sh: 不明なモード: ${1:-}" >&2; exit 2 ;;
esac
