#!/bin/bash
# shellcheck disable=SC2015  # ok / ng は常に 0 を返すので A && B || C で問題ない
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vpnsh-fwtest.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"

# lib/*.sh が参照する変数 (テスト用の名前にする)
VPNSH_ROOT="$ROOT"
VPNSH_PROJECT="vpnshell-fwtest"
VPNSH_GLUETUN_NAME="vpnshell-fwtest-gluetun"
VPNSH_STATE_DIR="$WORK"
VPNSH_ENV_FILE="$WORK/env"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/fwcheck.sh
. "$ROOT/lib/fwcheck.sh"
# shellcheck source=lib/keychain.sh
. "$ROOT/lib/keychain.sh"
# shellcheck source=lib/gluetun.sh
. "$ROOT/lib/gluetun.sh"
vpnsh_clean_env
export VPNSH_UID VPNSH_GID
VPNSH_UID="$(id -u)"; VPNSH_GID="$(id -g)"

# キーチェーンの代わり (本物のキーチェーンには触れない)
kc_get() { openssl rand -base64 32 | tr -d '\n'; }

NAME="$VPNSH_GLUETUN_NAME"
EP_IP="192.0.2.10"
EP_PORT="51820"
MODE="${1:-test}"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$*"; }
ng() { FAIL=$((FAIL + 1)); printf '  \033[31mNG\033[0m   %s\n' "$*"; }
# skip <説明>  省略したことを表示する (VPNSH_CI=1 なら NG にする)
skip() { if [ "${VPNSH_CI:-}" = 1 ]; then ng "省略した (CI では省略しない): $*"; else printf '  (%s)\n' "$*"; fi; }

cleanup() {
	vpnsh_docker rm -f "$VPNSH_PROJECT-ipsrv" >/dev/null 2>&1
	vpnsh_compose down -v --remove-orphans >/dev/null 2>&1
	rm -f "$WORK/env" "$WORK/post-rules.txt" "$WORK/gluetun.id" "$WORK/gluetun.env" "$WORK/post-rules.txt.tmp."* 2>/dev/null
	rmdir "$WORK" 2>/dev/null
}
trap cleanup EXIT

cat >"$WORK/env" <<EOF
WIREGUARD_ENDPOINT_IP=$EP_IP
WIREGUARD_ENDPOINT_PORT=$EP_PORT
WIREGUARD_PUBLIC_KEY=$(openssl rand -base64 32)
WIREGUARD_ADDRESSES=10.5.0.2/32
WIREGUARD_MTU=1320
VPNSH_GLUETUN_NAME=$NAME
VPNSH_STATE_DIR=$WORK
EOF

wait_fw() {
	local i=0
	until gl_inspect && gl_fw_check 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -gt 30 ] && return 1
		sleep 0.5
	done
}

if [ "$MODE" != "--dump" ]; then
	echo "== 0. post-rules の元ファイルが無いときは作成に失敗する"
	# (gl_create は post-rules を生成するので、ここでは compose を直接呼んで確かめる)
	rm -f "$WORK/post-rules.txt"
	if VPNSH_WG_PRIVATE_KEY="$(kc_get)" VPNSH_CONTROL_DEFAULT_ROLE='{"auth":"apikey","apikey":"x0123456789"}' \
		vpnsh_compose up -d --no-start gluetun >/dev/null 2>&1; then
		ng "post-rules の元ファイルが無いのにコンテナを作成できた"
	else
		ok "post-rules の元ファイルが無いとコンテナを作成できない (create_host_path: false)"
	fi
	vpnsh_compose down -v >/dev/null 2>&1
fi

echo "== 1. vpnsh と同じ手順で作成 (作成 → 検査 → 起動)"
# shellcheck disable=SC2119  # 引数なし (初回作成) で呼ぶ
if ! gl_create >/dev/null 2>"$WORK/create.err"; then
	cat "$WORK/create.err" >&2; rm -f "$WORK/create.err"
	echo "gluetun を作成できません" >&2
	exit 1
fi
rm -f "$WORK/create.err"
ok "作成・検査・起動に成功"
gl_inspect

if [ "$MODE" = "--dump" ]; then
	wait_fw
	gl_inspect
	nv="$(fw_net_values "$GL_ETH_IP" "$GL_ETH_PREFIX")"
	fw_dump "$NAME" | FW_ETH_IP="$GL_ETH_IP" FW_SUBNET="${nv% *}" FW_BCAST="${nv#* }" FW_GW="$GL_ETH_GW" \
		FW_EP_IP="$EP_IP" FW_EP_PORT="$EP_PORT" FW_WG_ADDR="10.5.0.2" fw_normalize
	exit 0
fi

if wait_fw; then
	gl_inspect
	gl_fw_check && ok "ファイアウォールとルーティングが期待値と一致 ($FW_NETNS)"
else
	gl_inspect
	gl_fw_check
	ng "期待値と一致しない"
fi
GLUETUN_NETNS="${FW_NETNS:-}"

echo "== 1b. 作成の重なりで、別の vpnsh が作った gluetun を壊さない"
id_before="$GL_ID"
gl_create >/dev/null 2>&1 && ng "動いている gluetun があるのに、作り直しなしの作成が成功した" || ok "動いている gluetun があれば、作り直しなしの作成は失敗する"
gl_inspect
[ "$GL_ID" = "$id_before" ] && [ "$GL_STATUS" = "running" ] && [ "$(cat "$WORK/gluetun.id")" = "$id_before" ] &&
	ok "そのとき既存の gluetun と記録は消さない" || ng "既存の gluetun か記録が壊れた ($GL_ID / $GL_STATUS)"

echo "== 2. 遮断ルール・ルーティングの改ざんを検出する"
# tamper <説明> <加えるコマンド> <戻すコマンド>  (gluetun の中で実行する)
tamper() {
	if ! vpnsh_docker exec "$NAME" sh -c "$2" >/dev/null 2>&1; then
		skip "この環境では「$1」を試せません"
		return
	fi
	gl_fw_check >/dev/null 2>&1 && ng "検出しない: $1" || ok "検出する: $1"
	vpnsh_docker exec "$NAME" sh -c "$3" >/dev/null 2>&1
}
tamper "OUTPUT の末尾への ACCEPT" "iptables -A OUTPUT -o eth0 -p tcp -j ACCEPT" "iptables -D OUTPUT -o eth0 -p tcp -j ACCEPT"
tamper "OUTPUT の先頭への ACCEPT" "iptables -I OUTPUT 1 -o eth0 -j ACCEPT" "iptables -D OUTPUT -o eth0 -j ACCEPT"
tamper "INPUT の先頭への ACCEPT" "iptables -I INPUT 1 -i eth0 -j ACCEPT" "iptables -D INPUT -i eth0 -j ACCEPT"
tamper "OUTPUT の既定の方針を ACCEPT に" "iptables -P OUTPUT ACCEPT" "iptables -P OUTPUT DROP"
tamper "nat の DNAT" "iptables -t nat -A OUTPUT -p tcp -j DNAT --to-destination 192.0.2.99" "iptables -t nat -D OUTPUT -p tcp -j DNAT --to-destination 192.0.2.99"
tamper "mangle で WireGuard の目印を付ける" "iptables -t mangle -A OUTPUT -j MARK --set-mark 0xca6c" "iptables -t mangle -D OUTPUT -j MARK --set-mark 0xca6c"
tamper "ip6tables への ACCEPT" "ip6tables -A OUTPUT -j ACCEPT" "ip6tables -D OUTPUT -j ACCEPT"
tamper "legacy の iptables への ACCEPT" "iptables-legacy -A OUTPUT -j ACCEPT" "iptables-legacy -D OUTPUT -j ACCEPT"
tamper "ルーティング規則の追加" "ip rule add from all lookup main priority 50" "ip rule del priority 50"
tamper "経路の追加" "ip route add 203.0.113.0/24 dev eth0 table 100" "ip route del 203.0.113.0/24 dev eth0 table 100"
# vpnsh の遮断ルール (post-rules) の1行の削除: 戻すのが難しいので、最後に作り直す
tamper "vpnsh の遮断ルールの削除 (eth0 の DROP)" "iptables -D OUTPUT -o eth0 -j DROP" "true"
gl_create --recreate >/dev/null 2>&1 || { echo "gluetun を作り直せません" >&2; exit 1; }
wait_fw >/dev/null 2>&1
gl_inspect
gl_fw_check >/dev/null 2>&1 && ok "作り直すと期待値に戻る" || ng "作り直しても期待値に戻らない"
GLUETUN_NETNS="${FW_NETNS:-}"

echo "== 3. work 相当のコンテナからの確認"
probe() {
	vpnsh_docker run --rm --cap-drop ALL --security-opt no-new-privileges \
		--network "container:$NAME" --entrypoint sh vpnshell-work:local -c "$1" 2>&1
}
if ! vpnsh_docker image inspect vpnshell-work:local >/dev/null 2>&1; then
	skip "work イメージが無いので 3〜4 は省略。bin/vpnsh build の後に再実行してください"
else
	out="$(probe 'start=$(date +%s%N); dig +time=2 +tries=1 @127.0.0.11 example.com >/dev/null 2>&1; rc=$?; end=$(date +%s%N); echo "$rc $(( (end-start)/1000000 ))"')"
	rc="${out%% *}"; ms="${out##* }"
	[ "$rc" != "0" ] && [ "$ms" -lt 1500 ] && ok "127.0.0.11 は即座に拒否される (${ms}ms)" || ng "127.0.0.11 が拒否されない: $out"

	out="$(probe 'curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:8000/v1/vpn/status')"
	[ "$out" = "401" ] && ok "制御用サーバー: キーなしで 401" || ng "制御用サーバー: キーなしで 401 にならない: $out"

	# 時間切れ (28) だけを「遮断された」とみなす (拒否 (RST) は相手に届いている)
	out="$(probe "curl -s -o /dev/null --connect-timeout 2 --max-time 3 http://$GL_ETH_GW/; echo \$?")"
	[ "$out" = "28" ] && ok "eth0 のゲートウェイ ($GL_ETH_GW) に届かない (時間切れ)" || ng "eth0 のゲートウェイへの接続の結果が想定外 (curl の終了コード $out)"

	before="$(vpnsh_docker exec "$NAME" sh -c 'iptables -v -x -n -L OUTPUT 3 2>/dev/null | awk "{print \$1}"')"
	out="$(probe "perl -MSocket -e 'socket(my \$s, AF_INET, SOCK_DGRAM, 0) or die \"socket: \$!\"; setsockopt(\$s, SOL_SOCKET, 25, pack(\"Z*\", \"eth0\")) or die \"bind: \$!\"; my \$a = sockaddr_in($EP_PORT, inet_aton(\"$EP_IP\")); send(\$s, \"x\" x 10, 0, \$a) for 1..5; print \"sent\\n\"'")"
	after="$(vpnsh_docker exec "$NAME" sh -c 'iptables -v -x -n -L OUTPUT 3 2>/dev/null | awk "{print \$1}"')"
	case "$out" in
		*sent*) [ "$after" -ge $((before + 5)) ] && ok "eth0 を直接指定した目印なしの UDP は遮断される (DROP +$((after - before)))" || ng "eth0 を直接指定した UDP が遮断ルールに当たらない ($before → $after)" ;;
		*"bind: Operation not permitted"*) ok "eth0 を直接指定したソケットは作れない" ;;
		*) ng "eth0 を直接指定した UDP の試験に失敗した: $out" ;;
	esac

	out="$(probe 'cat /proc/sys/net/ipv6/conf/all/disable_ipv6')"
	[ "$out" = "1" ] && ok "IPv6 は無効" || ng "IPv6 が無効ではない: $out"

	out="$(probe 'ls /run/secrets 2>&1 || true')"
	case "$out" in *"No such file"*) ok "gluetun の secret は見えない" ;; *) ng "secret が見える: $out" ;; esac

	out="$(probe 'readlink /proc/self/ns/net')"
	[ -n "$GLUETUN_NETNS" ] && [ "$out" = "$GLUETUN_NETNS" ] && ok "ネットワーク名前空間が一致 ($out)" || ng "名前空間が一致しない: $out / $GLUETUN_NETNS"

	echo "== 4. 起動前チェック (compose の work 設定のまま) は不健全な VPN で失敗する"
	t0="$(date +%s)"
	out="$(vpnsh_compose run --rm --no-deps -T -e "VPNSH_GLUETUN_NETNS=$GLUETUN_NETNS" -e VPNSH_VERBOSE=1 work check 2>&1)"
	rc=$?
	t1="$(date +%s)"
	[ "$rc" -eq 125 ] && ok "終了コード 125 で失敗する" || ng "終了コードが 125 ではない: $rc"
	[ $((t1 - t0)) -le 12 ] && ok "$((t1 - t0)) 秒で失敗が確定する" || ng "失敗の確定に $((t1 - t0)) 秒かかった"
	for item in "ネットワーク名前空間が一致" "IPv6 は無効" "1024 未満のポートは権限なしでは使えない" "DNS は gluetun 内蔵 (127.0.0.1) のみ" "制御用サーバーは認証が必要 (401)"; do
		case "$out" in *"[OK] $item"*) ok "確認している: $item" ;; *) ng "確認結果がない: $item" ;; esac
	done
	# 判定は1行ずつ (出力全体に対するパターンだと、別の行の [NG] と組み合わさって通ってしまう)
	ngline() { printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -F '[NG]' | grep -qF "$1"; }
	ngline "ヘルスサーバー" && ok "VPN が不健全であることを検出する" || ng "ヘルスサーバーの失敗を検出しない"
	ngline "応答した確認サービスが 0 件" && ok "外部IP を確認できないことを検出する" || ng "外部IP の失敗を検出しない"

	echo "== 4a. 外部IP の照合"
	# gluetun の名前空間に、確認サービスの代わりの HTTP サーバーを3つ立てる (本文は /tmp/ip.<ポート>)
	vpnsh_docker run -d --name "$VPNSH_PROJECT-ipsrv" --network "container:$NAME" --entrypoint perl vpnshell-work:local -e '
		use IO::Socket::INET;
		for my $p (18081, 18082, 18083) {
			next if fork;
			my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $p, Listen => 16, ReuseAddr => 1) or die;
			while (my $c = $s->accept) {
				while (<$c>) { last if /^\r?\n$/ }
				if (open my $fh, "<", "/tmp/ip.$p") { local $/; my $b = <$fh>; print $c "HTTP/1.0 200 OK\r\nContent-Length: " . length($b) . "\r\n\r\n$b" }
				close $c;
			}
			exit;
		}
		sleep;' >/dev/null
	ipset() { vpnsh_docker exec "$VPNSH_PROJECT-ipsrv" sh -c "rm -f /tmp/ip.*; $1"; }
	ipcheck() {
		vpnsh_compose run --rm --no-deps -T -e "VPNSH_GLUETUN_NETNS=$GLUETUN_NETNS" -e VPNSH_VERBOSE=1 \
			-e EXPECTED_PUBLIC_IP=203.0.113.7 -e VPNSH_IP_CHECK_URLS="http://127.0.0.1:18081/ http://127.0.0.1:18082/ http://127.0.0.1:18083/" \
			-e "VPNSH_PREFLIGHT_MODE=$1" --entrypoint /usr/local/lib/vpnsh/preflight.sh work 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
	}
	sleep 1
	ipset 'printf "fl=1\nip=203.0.113.7\nts=1\n" > /tmp/ip.18081; echo 203.0.113.7 > /tmp/ip.18082; echo 203.0.113.7 > /tmp/ip.18083'
	out="$(ipcheck check)"
	n="$(printf '%s\n' "$out" | grep -cF '[OK] 外部IP:')"
	[ "$n" = "3" ] && ! printf '%s\n' "$out" | grep -F '[NG]' | grep -qF '外部IP' && ok "全件一致なら外部IP の検査は通る (Cloudflare の trace の形式も読む)" || ng "全件一致の結果が想定外: $out"
	ipset 'echo 203.0.113.7 > /tmp/ip.18081; echo 198.51.100.1 > /tmp/ip.18082; echo 203.0.113.7 > /tmp/ip.18083'
	out="$(ipcheck check)"
	printf '%s\n' "$out" | grep -F '[NG]' | grep -qF '外部IP が一致しません: http://127.0.0.1:18082/' && ok "1件でも違えば失敗する" || ng "1件の不一致を検出しない: $out"
	ipset 'echo 203.0.113.7 > /tmp/ip.18081'
	out="$(ipcheck check)"
	printf '%s\n' "$out" | grep -F '[NG]' | grep -qF '応答した確認サービスが 1 件' && ok "応答が1件だけなら失敗する (2件以上必要)" || ng "応答が1件だけの場合を検出しない: $out"
	ipset 'echo 203.0.113.7 > /tmp/ip.18081; echo hello > /tmp/ip.18082; echo 203.0.113.7 > /tmp/ip.18083'
	out="$(ipcheck check)"
	printf '%s\n' "$out" | grep -F '[NG]' | grep -qF 'IP を読み取れません' && ok "応答から IP を読み取れなければ失敗する" || ng "読み取れない応答を検出しない: $out"
	ipset 'echo 203.0.113.7 > /tmp/ip.18081; echo 203.0.113.8 > /tmp/ip.18082; echo 203.0.113.7 > /tmp/ip.18083'
	out="$(ipcheck observe)"
	printf '%s\n' "$out" | grep -F '[NG]' | grep -qF '異なる IP' && ok "setup の観測で、サービスごとに IP が違えば失敗する" || ng "観測の不一致を検出しない: $out"
	vpnsh_docker rm -f "$VPNSH_PROJECT-ipsrv" >/dev/null 2>&1
	out="$(vpnsh_compose run --rm --no-deps -T -e "VPNSH_GLUETUN_NETNS=net:[1]" work check 2>&1)"
	case "$out" in *"一致しません"*) ok "名前空間が違えば失敗する" ;; *) ng "名前空間の不一致を検出しない" ;; esac
	out="$(vpnsh_compose run --rm --no-deps -T --entrypoint sh work -c 'grep -E "^(CapEff|NoNewPrivs)" /proc/self/status; cat /etc/resolv.conf' 2>&1)"
	case "$out" in *"CapEff:	0000000000000000"*"NoNewPrivs:	1"*) ok "work は権限なし (CapEff=0, NoNewPrivs=1)" ;; *) ng "work の権限が想定外: $out" ;; esac
	case "$out" in *"nameserver 127.0.0.1"*) ok "work の DNS は 127.0.0.1 に固定" ;; *) ng "work の DNS が想定外: $out" ;; esac

	echo "== 4b. work イメージと実行時の固さ"
	out="$(vpnsh_compose --progress quiet run --rm --no-deps -T --entrypoint sh work -c 'echo "suid=$(find / -xdev -perm /6000 -type f 2>/dev/null | wc -l) caps=$(getcap -r / 2>/dev/null | wc -l)"' 2>&1)"
	[ "$out" = "suid=0 caps=0" ] && ok "setuid / setgid とファイル capability が無い" || ng "setuid / capability が残っている: $out"
	probe_w='w=""; for d in / /etc /usr/bin /usr/local/lib/vpnsh /home/vpnsh /tmp /var/tmp; do touch "$d/.w" 2>/dev/null && { w="$w $d"; rm -f "$d/.w"; }; done; echo "${w# }"'
	out="$(vpnsh_compose --progress quiet run --rm --no-deps -T --entrypoint sh work -c "$probe_w" 2>&1)"
	[ "$out" = "/home/vpnsh /tmp /var/tmp" ] && ok "一般ユーザーが書き込めるのはホームと /tmp・/var/tmp だけ" || ng "一般ユーザーが書き込める場所が想定外: $out"
	out="$(vpnsh_compose --progress quiet run --rm --no-deps -T --user 0 --entrypoint sh work -c "$probe_w" 2>&1)"
	[ "$out" = "/tmp /var/tmp" ] && ok "root でも書き込めるのは /tmp・/var/tmp だけ (読み取り専用のルート)" || ng "root が書き込める場所が想定外: $out"
	out="$(vpnsh_compose --progress quiet run --rm --no-deps -T --entrypoint sh work -c 'cp /usr/bin/true /tmp/t && /tmp/t && echo exec-ok; ping -c1 -W1 192.0.2.1 2>&1 | head -n 2' 2>&1)"
	case "$out" in *exec-ok*) ok "/tmp でプログラムを実行できる" ;; *) ng "/tmp で実行できない: $out" ;; esac
	case "$out" in
		*"Operation not permitted"*) ng "ping が起動できない: $out" ;;
		*PING*) ok "ping が起動できる (権限なしの ICMP ソケット)" ;;
		*) ng "ping の結果が想定外: $out" ;;
	esac
	out="$(vpnsh_compose --progress quiet run --rm --no-deps -T --entrypoint perl work -e 'use Socket; socket(my $s, AF_INET, SOCK_DGRAM, 0) or die; print bind($s, sockaddr_in(53, inet_aton("127.0.0.1"))) ? "bound" : "denied: $!"' 2>&1)"
	[ "$out" = "denied: Permission denied" ] && ok "権限なしでは 127.0.0.1:53 で待ち受けられない (他のシェルの DNS を乗っ取れない)" || ng "53 番ポートの結果が想定外: $out"
	out="$(vpnsh_compose --progress quiet run --rm --no-deps -T --entrypoint perl work -e 'my $p = fork(); if (!$p) { sleep 10; exit } my %n = (aarch64 => 117, x86_64 => 101); chomp(my $m = `uname -m`); print syscall($n{$m}, 16, $p, 0, 0) == 0 ? "attached" : "denied"; kill 9, $p' 2>&1)"
	[ "$out" = "denied" ] && ok "ptrace はできない (独自の seccomp)" || ng "ptrace ができる: $out"
	out="$(vpnsh_compose --progress quiet run --rm --no-deps -T --entrypoint bash work -ic 'echo "$PATH"' 2>/dev/null | tail -n 1)"
	# shellcheck disable=SC2088  # 表示の文字列
	case "$out" in *":/home/vpnsh/.local/bin") ok "~/.local/bin は PATH の最後 (標準のコマンドより優先されない)" ;; *) ng "PATH の順序が想定外: $out" ;; esac
	out="$(vpnsh_compose --progress quiet run --rm --no-deps -T --entrypoint sh work -c 'awk "\$2 == \"/home/vpnsh\" {print \$2}" /proc/mounts' 2>&1)"
	[ "$out" = "/home/vpnsh" ] && ok "ホームは別のボリューム (ルートは読み取り専用)" || ng "ホームがボリュームになっていない: $out"
	before="$(vpnsh_docker volume ls -q --filter dangling=true | wc -l | tr -d ' ')"
	vpnsh_compose --progress quiet run --rm --no-deps -T --entrypoint sh work -c 'echo x > ~/f' >/dev/null 2>&1
	after="$(vpnsh_docker volume ls -q --filter dangling=true | wc -l | tr -d ' ')"
	[ "$before" = "$after" ] && ok "使い捨てのホームはシェルの終了で消える (未使用のボリューム ${before} → ${after})" || ng "ホームのボリュームが残った (未使用のボリューム ${before} → ${after})"

	echo "== 4c. 漏れの実地検査 (vpnsh check --full の検査)"
	diag_full() {
		vpnsh_compose --progress quiet run --rm --no-deps -T -e "VPNSH_LAN_ADDRS=$GL_ETH_GW $GL_ETH_IP" -e "VPNSH_EP_IP=$EP_IP" -e "VPNSH_EP_PORT=$EP_PORT" \
			--entrypoint /usr/local/lib/vpnsh/diag.sh work full 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
	}
	out="$(diag_full)"
	case "$out" in *"[NG]"*) ng "正常な状態で漏れを検出した: $(printf '%s\n' "$out" | grep '\[NG\]')" ;; *) ok "正常な状態では漏れを検出しない" ;; esac
	for item in "127.0.0.11" "ゲートウェイ ($GL_ETH_GW) には届かない" "Mac のアドレス 1 個 ($GL_ETH_GW) には、どれも届かない" "eth0 を直接指定した TCP" "UDP (1.1.1.1:53) は遮断ルールで送信が止められる" "VPN の接続先" "IPv6 では外に出られない"; do
		printf '%s\n' "$out" | grep -F '[OK]' | grep -qF "$item" && ok "確かめている: $item" || ng "確認結果がない: $item"
	done
	printf '%s\n' "$out" | grep -qF "漏れの実地検査: NG 0 件" && ok "最後にまとめ (NG 0 件) を出す" || ng "まとめが無い: $out"
	printf '%s\n' "$out" | grep -F '[--]' | grep -qF "$GL_ETH_IP はコンテナ自身" && ok "コンテナ自身と同じアドレスは調べない (Mac の VPN のアドレスが重なっても誤検出しない)" || ng "コンテナ自身のアドレスの扱いが想定外: $out"
	t0="$(date +%s)"; diag_full >/dev/null; t1="$(date +%s)"
	[ $((t1 - t0)) -le 15 ] && ok "漏れの実地検査は $((t1 - t0)) 秒で終わる" || ng "漏れの実地検査に $((t1 - t0)) 秒かかった"
	# わざと穴を開ける (eth0 のゲートウェイとの通信を許す) と、検出すること
	vpnsh_docker exec "$NAME" sh -c "iptables -I OUTPUT 1 -o eth0 -d $GL_ETH_GW -j ACCEPT && iptables -I INPUT 1 -i eth0 -s $GL_ETH_GW -j ACCEPT"
	out="$(diag_full)"
	vpnsh_docker exec "$NAME" sh -c "iptables -D OUTPUT -o eth0 -d $GL_ETH_GW -j ACCEPT; iptables -D INPUT -i eth0 -s $GL_ETH_GW -j ACCEPT"
	printf '%s\n' "$out" | grep -F '[NG]' | grep -qF "$GL_ETH_GW" && ok "穴を開けると検出する: $(printf '%s\n' "$out" | grep -F '[NG]' | head -n 1 | sed 's/^vpnsh: //')" || ng "穴を開けても検出しない: $out"
	printf '%s\n' "$out" | grep -qE "漏れの実地検査: NG [1-9]" && printf '%s\n' "$out" | grep -qF "vpnsh up --recreate" &&
		ok "そのときはまとめに NG の件数と次の手順を出す" || ng "NG のときのまとめが想定外: $out"
fi

echo "== 4d. VPN の通信の監視 (Mac 側、lib/netmon.sh)"
(
	# shellcheck source=lib/netmon.sh
	. "$ROOT/lib/netmon.sh"
	gl_inspect
	netmon_probe "$GL_ID"; r=$?
	[ "$r" -eq 1 ] && echo "OK|トンネルで通信できない gluetun を「通信できない」と判定する" || echo "NG|判定が想定外 ($r)"
	netmon_probe 0000000000000000000000000000000000000000000000000000000000000000; r=$?
	[ "$r" -eq 2 ] && echo "OK|gluetun が無いことを判定する" || echo "NG|gluetun が無いときの判定が想定外 ($r)"
	# 状態の移り変わり (確認の結果を順に差し替える): 失敗・失敗・失敗・成功・成功・gluetun が無い
	NETMON_INTERVAL=1
	seqf="$WORK/netmon-seq"; outf="$WORK/netmon-out"
	printf '%s\n' 1 1 1 0 0 2 >"$seqf"; : >"$outf"
	netmon_probe() { local r; r="$(head -n 1 "$seqf")"; sed -i '' 1d "$seqf"; return "${r:-0}"; }
	(netmon_loop dummy "$$" "$outf")
	down="$(grep -c 'VPN で通信できません' "$outf")"; up="$(grep -c '戻りました' "$outf")"; gone="$(grep -c '作り直されたか' "$outf")"
	[ "$down" = "1" ] && echo "OK|2回続けて失敗したら「通信できません」を1回だけ出す" || echo "NG|「通信できません」が $down 回"
	[ "$up" = "1" ] && echo "OK|戻ったら「通信が戻りました」を1回だけ出す" || echo "NG|「戻りました」が $up 回"
	[ "$gone" = "1" ] && echo "OK|gluetun が無くなったら知らせて監視を終える" || echo "NG|gluetun が無いときの表示が $gone 回"
	# 持ち主の vpnsh が終わったら、監視も終わる
	sleep 30 & owner=$!
	printf '%s\n' 0 0 0 0 0 >"$seqf"
	netmon_loop dummy "$owner" "$outf" & mon=$!
	kill "$owner"; i=0
	while kill -0 "$mon" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.2; i=$((i + 1)); done
	kill -0 "$mon" 2>/dev/null && { echo "NG|持ち主が終わっても監視が残った"; kill "$mon"; } || echo "OK|持ち主の vpnsh が終わったら監視も終わる"
) >"$WORK/netmon-result" 2>/dev/null
while IFS='|' read -r st msg; do
	if [ "$st" = "OK" ]; then ok "$msg"; else ng "$msg"; fi
done <"$WORK/netmon-result"

echo "== 5. 整合性検査が作成時との違いを検出する"
gl_inspect
gl_verify 2>/dev/null && ok "作成直後は整合性検査に通る" || { gl_verify; ng "作成直後なのに整合性検査に通らない"; }
cp "$WORK/gluetun.env" "$WORK/gluetun.env.bak"
echo "EXTRA=1" >>"$WORK/gluetun.env"
gl_verify 2>/dev/null && ng "環境変数の違いを検出しない" || ok "環境変数の違いを検出した"
mv -f "$WORK/gluetun.env.bak" "$WORK/gluetun.env"
cp "$WORK/gluetun.id" "$WORK/gluetun.id.bak"
echo "0000" >"$WORK/gluetun.id"
gl_verify 2>/dev/null && ng "ID の違いを検出しない" || ok "ID の違いを検出した"
mv -f "$WORK/gluetun.id.bak" "$WORK/gluetun.id"
GL_DUP_ENV="FOO" gl_env_policy 2>/dev/null && ng "環境変数の重複を検出しない" || ok "環境変数の重複を検出した"

echo "== 6. 持ち主の判定がロケールやタイムゾーンに左右されない"
a="$(LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 TZ=Asia/Tokyo vpnsh_proc_start $$)"
b="$(LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TZ=UTC vpnsh_proc_start $$)"
[ -n "$a" ] && [ "$a" = "$b" ] && ok "開始時刻の表記が同じ ($a)" || ng "開始時刻の表記が違う ($a / $b)"

echo
echo "結果: OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ]
