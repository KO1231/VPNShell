# shellcheck shell=bash

# .env から gluetun に渡す値 (コンテナの Env と照合して「未適用の変更」を検出する)
GL_ENV_KEYS="WIREGUARD_ENDPOINT_IP WIREGUARD_ENDPOINT_PORT WIREGUARD_PUBLIC_KEY WIREGUARD_ADDRESSES WIREGUARD_MTU"

# 安全のため「この値でなければならない」環境変数 (イメージが既定値を持つので、値で判定する)
GL_REQUIRED_ENV="
FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT=on
FIREWALL_OUTBOUND_SUBNETS=
FIREWALL_INPUT_PORTS=
FIREWALL_VPN_INPUT_PORTS=
HTTPPROXY=
SHADOWSOCKS=off
VPN_PORT_FORWARDING=off
VPN_SERVICE_PROVIDER=custom
VPN_TYPE=wireguard
VPN_INTERFACE=tun0
DNS_SERVER=on
DNS_ADDRESS=127.0.0.1
DNS_KEEP_NAMESERVER=off
DNS_UPSTREAM_IPV6=off
HTTP_CONTROL_SERVER_ADDRESS=127.0.0.1:8000
HEALTH_SERVER_ADDRESS=127.0.0.1:9999
WIREGUARD_CONF_SECRETFILE=/run/secrets/wg0.conf
PPROF_ENABLED=no
"
# gluetun のコンテナに設定されていなければならない sysctl (compose.yaml と同じ。名前順、カンマ区切り)
GL_REQUIRED_SYSCTLS="net.ipv4.ip_unprivileged_port_start=1024,net.ipv6.conf.all.disable_ipv6=1,net.ipv6.conf.default.disable_ipv6=1"
# 存在してはいけない環境変数 (旧名、プロキシなど)
GL_ABSENT_ENV="FIREWALL FIREWALL_ENABLED HTTP_PROXY HTTPS_PROXY NO_PROXY FTP_PROXY ALL_PROXY http_proxy https_proxy no_proxy ftp_proxy all_proxy"

gl_pinned_image() {
	sed -n 's/^[[:space:]]*image:[[:space:]]*\(qmcgaw\/gluetun:[^[:space:]]*\)[[:space:]]*$/\1/p' "$VPNSH_ROOT/compose.yaml" | head -n 1
}

# gl_inspect  gluetun の状態を GL_* 変数に入れる (0=存在する / 1=存在しない / 2=Docker に接続できない)
gl_inspect() {
	local json errf rc
	errf="$(mktemp "${TMPDIR:-/tmp}/vpnsh-insp.XXXXXX")"
	json="$(vpnsh_docker inspect --type container "$VPNSH_GLUETUN_NAME" 2>"$errf")"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		if grep -qi 'no such' "$errf"; then rm -f "$errf"; return 1; fi
		# shellcheck disable=SC2034  # bin/vpnsh が表示に使う
		GL_DOCKER_ERROR="$( (head -n 1 "$errf"; [ "$rc" -eq 124 ] && echo "(時間切れ)") | tr '\n' ' ' | vpnsh_sanitize)"
		rm -f "$errf"
		return 2
	fi
	rm -f "$errf"
	local parsed
	parsed="$(printf '%s' "$json" | perl -MJSON::PP -e '
		local $/; my $d = decode_json(<STDIN>)->[0];
		my %o;
		$o{ID} = $d->{Id};
		$o{STATUS} = $d->{State}{Status};
		$o{HEALTH} = ($d->{State}{Health} ? $d->{State}{Health}{Status} : "none");
		$o{CONFIG_IMAGE} = $d->{Config}{Image};
		$o{IMAGE_ID} = $d->{Image};
		$o{PRIVILEGED} = $d->{HostConfig}{Privileged} ? "true" : "false";
		$o{CAPADD} = join(",", sort @{ $d->{HostConfig}{CapAdd} // [] });
		$o{NETMODE} = $d->{HostConfig}{NetworkMode};
		$o{PIDMODE} = $d->{HostConfig}{PidMode} // "";
		my $sc = $d->{HostConfig}{Sysctls} // {};
		$o{SYSCTLS} = join(",", map { "$_=$sc->{$_}" } sort keys %$sc);
		my @m;
		for my $mt (@{ $d->{Mounts} // [] }) {
			push @m, join("|", $mt->{Type}, $mt->{Destination}, ($mt->{Type} eq "bind" ? $mt->{Source} : ($mt->{Name} // "-")), ($mt->{RW} ? "rw" : "ro"));
		}
		$o{MOUNTS} = join(";", sort @m);
		my ($net) = sort keys %{ $d->{NetworkSettings}{Networks} // {} };
		if (defined $net) {
			my $n = $d->{NetworkSettings}{Networks}{$net};
			$o{NET_NAME} = $net; $o{ETH_IP} = $n->{IPAddress}; $o{ETH_PREFIX} = $n->{IPPrefixLen}; $o{ETH_GW} = $n->{Gateway};
		}
		my (%seen, @dup);
		for my $e (@{ $d->{Config}{Env} // [] }) { my ($k) = split /=/, $e, 2; push @dup, $k if $seen{$k}++; }
		$o{DUP_ENV} = join(" ", sort @dup);
		for my $k (sort keys %o) { my $v = $o{$k} // ""; $v =~ s/[\r\n]/ /g; print "GL_$k=$v\n"; }
		print "--ENV--\n";
		for my $e (sort @{ $d->{Config}{Env} // [] }) { (my $x = $e) =~ s/[\r\n]/ /g; print "$x\n"; }
	')" || return 2
	# 値に空白などを含み得るので eval は使わず1行ずつ読む (Env は GL_ENV_TEXT に持つ)
	local line k v in_env=""
	GL_ENV_TEXT=""
	while IFS= read -r line; do
		if [ -n "$in_env" ]; then
			GL_ENV_TEXT="$GL_ENV_TEXT$line
"
			continue
		fi
		[ "$line" = "--ENV--" ] && { in_env=1; continue; }
		k="${line%%=*}"; v="${line#*=}"
		case "$k" in
			GL_ID | GL_STATUS | GL_HEALTH | GL_CONFIG_IMAGE | GL_IMAGE_ID | GL_PRIVILEGED | GL_CAPADD | GL_NETMODE | GL_PIDMODE | GL_SYSCTLS | GL_MOUNTS | GL_NET_NAME | GL_ETH_IP | GL_ETH_PREFIX | GL_ETH_GW | GL_DUP_ENV)
				printf -v "$k" '%s' "$v" ;;
		esac
	done <<EOF
$parsed
EOF
	GL_ENV_TEXT="${GL_ENV_TEXT%
}"
	return 0
}

# gl_env_lines  (gl_inspect の後) コンテナの Env を1行ずつ出す (改行を含む値は空白に置き換え済み)
gl_env_lines() {
	[ -n "${GL_ENV_TEXT:-}" ] && printf '%s\n' "$GL_ENV_TEXT"
	return 0
}

# gl_env_value <KEY>  (gl_inspect の後。サブプロセスを使わない)
gl_env_value() {
	local line
	while IFS= read -r line; do
		case "$line" in "$1="*) printf '%s' "${line#*=}"; return 0 ;; esac
	done <<EOF
${GL_ENV_TEXT:-}
EOF
	return 0
}

# gl_expected_env  作成後の Env と完全一致すべき集合を出す (イメージの既定値に compose.yaml の environment を上書き)
gl_expected_env() {
	local ref img comp
	ref="$(gl_pinned_image)"
	img="$(vpnsh_docker image inspect -f '{{json .Config.Env}}' "$ref" 2>/dev/null)" || { vpnsh_err "固定した gluetun のイメージ ($ref) がありません。\`vpnsh build\` を実行してください"; return 1; }
	comp="$(vpnsh_compose_t 30 config --format json 2>/dev/null)" || { vpnsh_err "compose.yaml を読めません"; return 1; }
	IMG="$img" COMP="$comp" perl -MJSON::PP -e '
		my %env; my @order;
		for my $e (@{ decode_json($ENV{IMG}) }) { my ($k, $v) = split /=/, $e, 2; push @order, $k unless exists $env{$k}; $env{$k} = $v; }
		my $c = decode_json($ENV{COMP})->{services}{gluetun}{environment} // {};
		for my $k (keys %$c) { my $v = $c->{$k}; $v = "" unless defined $v; push @order, $k unless exists $env{$k}; $env{$k} = $v; }
		for my $k (sort keys %env) { (my $v = $env{$k}) =~ s/[\r\n]/ /g; print "$k=$v\n"; }
	'
}

# gl_env_policy  (gl_inspect の後) 決まりを満たさなければ理由を出して 1 (perl 1回で判定する)
gl_env_policy() {
	local out
	if [ -n "${GL_DUP_ENV:-}" ]; then
		vpnsh_err "gluetun の環境変数に重複があります: $GL_DUP_ENV"
		return 1
	fi
	out="$(GL_REQ="$GL_REQUIRED_ENV" GL_ABS="$GL_ABSENT_ENV" GL_ENV="${GL_ENV_TEXT:-}" perl -e '
		my %env;
		for (split /\n/, $ENV{GL_ENV}) { my ($k, $v) = split /=/, $_, 2; $env{$k} = $v // ""; }
		for (split /\n/, $ENV{GL_REQ}) {
			next unless length;
			my ($k, $want) = split /=/, $_, 2; $want //= "";
			my $have = exists $env{$k} ? $env{$k} : "(未設定)";
			print "gluetun の環境変数 $k が想定外の値です (", (length $have ? $have : "空"), " / 期待値 ", (length $want ? $want : "空"), ")\n" if $have ne $want;
		}
		for my $k (split /\s+/, $ENV{GL_ABS}) { print "gluetun に設定してはいけない環境変数があります: $k\n" if length $k && exists $env{$k}; }
	')"
	[ -z "$out" ] && return 0
	printf '%s\n' "$out" | while IFS= read -r line; do vpnsh_err "$line"; done
	return 1
}

# gl_render_post_rules  .env の値で state/post-rules.txt を作る
gl_render_post_rules() {
	fw_render_post_rules "$VPNSH_ROOT/templates/post-rules.txt.tmpl" "$VPNSH_STATE_DIR/post-rules.txt" \
		"$(vpnsh_env_get WIREGUARD_ENDPOINT_IP)" "$(vpnsh_env_get WIREGUARD_ENDPOINT_PORT)"
}

# gl_pending_changes  (gl_inspect の後) .env とコンテナの設定が違えば、違う項目名を出して 0 を返す
gl_pending_changes() {
	local k want have found=1 rendered
	for k in $GL_ENV_KEYS; do
		want="$(vpnsh_env_get "$k")"
		have="$(gl_env_value "$k")"
		if [ "$want" != "$have" ]; then echo "$k"; found=0; fi
	done
	# compose.yaml の sysctl を変えたあと、作り直していない
	if [ "${GL_SYSCTLS:-}" != "$GL_REQUIRED_SYSCTLS" ]; then echo "sysctls"; found=0; fi
	# 遮断ルールのファイルが .env の値から作ったものと違う (値は検証してから埋め込む)
	if ! rendered="$(fw_render "$VPNSH_ROOT/templates/post-rules.txt.tmpl" \
		"$(vpnsh_env_get WIREGUARD_ENDPOINT_IP)" "$(vpnsh_env_get WIREGUARD_ENDPOINT_PORT)" 2>/dev/null)"; then
		echo "post-rules(.env の値が不正)"; found=0
	elif ! printf '%s\n' "$rendered" | cmp -s - "$VPNSH_STATE_DIR/post-rules.txt"; then
		echo "post-rules"; found=0
	fi
	return "$found"
}

# gl_verify_static  (gl_inspect の後) イメージ・権限・マウント・Env が作成時の記録と一致するか確かめる
gl_verify_static() {
	local bad=0 ref image_id
	ref="$(gl_pinned_image)"
	image_id="$(vpnsh_docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)"
	if [ "$GL_CONFIG_IMAGE" != "$ref" ] || [ -z "$image_id" ] || [ "$GL_IMAGE_ID" != "$image_id" ]; then
		vpnsh_err "gluetun のイメージが固定したもの ($ref) と違います"
		bad=1
	fi
	if [ "$GL_PRIVILEGED" != "false" ] || [ "${GL_CAPADD#CAP_}" != "NET_ADMIN" ] || [ "$GL_PIDMODE" != "" ]; then
		vpnsh_err "gluetun の権限設定が想定外です (privileged=$GL_PRIVILEGED, cap_add=$GL_CAPADD, pid=$GL_PIDMODE)"
		bad=1
	fi
	case "$GL_NETMODE" in host | container:* | none) vpnsh_err "gluetun のネットワークモードが想定外です ($GL_NETMODE)"; bad=1 ;; esac
	if [ "${GL_SYSCTLS:-}" != "$GL_REQUIRED_SYSCTLS" ]; then
		vpnsh_err "gluetun の sysctl が想定外です (${GL_SYSCTLS:-なし})。\`vpnsh up\` で作り直してください"
		bad=1
	fi
	# マウントは「遮断ルールのファイル (読み取り専用)」だけ (/gluetun などからの設定の注入を防ぐ)
	local expect_bind="bind|/iptables/post-rules.txt|$VPNSH_STATE_DIR/post-rules.txt|ro"
	if [ "$GL_MOUNTS" != "$expect_bind" ]; then
		vpnsh_err "gluetun のマウントが想定外です: ${GL_MOUNTS:-なし} (期待値: $expect_bind)"
		bad=1
	fi
	gl_env_policy || bad=1
	if [ ! -f "$VPNSH_STATE_DIR/gluetun.env" ] || ! gl_env_lines | cmp -s - "$VPNSH_STATE_DIR/gluetun.env"; then
		vpnsh_err "gluetun の環境変数が期待値と違います (vpnsh 以外の方法で作られた、または設定が注入された可能性)"
		if [ -n "${VPNSH_VERBOSE:-}" ] && [ -f "$VPNSH_STATE_DIR/gluetun.env" ]; then
			diff "$VPNSH_STATE_DIR/gluetun.env" <(gl_env_lines) | sed -n -e 's/^< /  - /p' -e 's/^> /  + /p' | sed 's/=.*/=…/' | vpnsh_visible >&2
		fi
		bad=1
	fi
	return "$bad"
}

# gl_verify  (gl_inspect の後) gluetun が vpnsh の作ったとおりのものか確かめる
gl_verify() {
	if [ ! -f "$VPNSH_STATE_DIR/gluetun.id" ] || [ "$(cat "$VPNSH_STATE_DIR/gluetun.id")" != "$GL_ID" ]; then
		vpnsh_err "gluetun が vpnsh 以外で作り直された可能性があります (記録と ID が違います)。\`vpnsh up --recreate\` で作り直してください"
		return 1
	fi
	gl_verify_static
}

# gl_fw_check  (gl_inspect の後) ファイアウォールとルーティングを期待値と比べる
# shellcheck disable=SC2034,SC2153
gl_fw_check() {
	local nv
	nv="$(fw_net_values "$GL_ETH_IP" "$GL_ETH_PREFIX")" || { vpnsh_err "gluetun の eth0 の情報が正しくありません ($GL_ETH_IP/$GL_ETH_PREFIX)"; return 1; }
	FW_ETH_IP="$GL_ETH_IP"
	FW_SUBNET="${nv% *}"
	FW_BCAST="${nv#* }"
	FW_GW="$GL_ETH_GW"
	FW_EP_IP="$(gl_env_value WIREGUARD_ENDPOINT_IP)"
	FW_EP_PORT="$(gl_env_value WIREGUARD_ENDPOINT_PORT)"
	FW_WG_ADDR="$(gl_env_value WIREGUARD_ADDRESSES)"; FW_WG_ADDR="${FW_WG_ADDR%/*}"
	fw_check "$VPNSH_GLUETUN_NAME" "$VPNSH_ROOT/templates/firewall-expected.txt"
}

# gl_create [--recreate]  作成 → 検査 → 記録 → 起動の順で gluetun を作る (ロックの中で呼ぶこと)
gl_create() {
	local recreate="" key role apikey rc errf idf mine expected
	[ "${1:-}" = "--recreate" ] && recreate="--force-recreate"
	gl_render_post_rules || return 1
	expected="$(gl_expected_env)" || return 1
	vpnsh_info "gluetun を作成します。キーチェーンの確認ダイアログが出たら「許可」を押してください (「常に許可」は押さないでください)"
	key="$(kc_get)" || return 1
	apikey="$(openssl rand -hex 24)" || return 1
	# shellcheck disable=SC2089,SC2090  # JSON の文字列としてそのまま渡す (コマンドとして解釈しない)
	role="{\"auth\":\"apikey\",\"apikey\":\"$apikey\"}"
	errf="$(mktemp "${TMPDIR:-/tmp}/vpnsh-up.XXXXXX")"
	# この呼び出しが作ったコンテナの ID (失敗したときに消してよいのは、これだけ)
	idf="$(mktemp "${TMPDIR:-/tmp}/vpnsh-upid.XXXXXX")"
	# 鍵は export せず、このサブシェルの compose にだけ渡す (作成と起動の両方に必要)
	(
		VPNSH_WG_PRIVATE_KEY="$key"
		VPNSH_CONTROL_DEFAULT_ROLE="$role"
		# shellcheck disable=SC2090
		export VPNSH_WG_PRIVATE_KEY VPNSH_CONTROL_DEFAULT_ROLE
		# shellcheck disable=SC2086
		vpnsh_compose_t 120 up -d --no-start --no-deps $recreate gluetun || exit 10
		gl_inspect || exit 11
		[ "$GL_STATUS" = "created" ] || { vpnsh_err "作成した gluetun の状態が想定外です (${GL_STATUS}。別の vpnsh が作った可能性があります)"; exit 12; }
		printf '%s' "$GL_ID" >"$idf"
		printf '%s\n' "$expected" >"$VPNSH_STATE_DIR/gluetun.env"
		gl_verify_static || exit 13
		printf '%s\n' "$GL_ID" >"$VPNSH_STATE_DIR/gluetun.id"
		vpnsh_compose_t 120 up -d --no-deps --no-recreate gluetun || exit 14
	) >"$errf" 2>&1
	rc=$?
	key=""; role=""; apikey=""
	mine="$(cat "$idf" 2>/dev/null)"
	rm -f "$idf"
	if [ "$rc" -ne 0 ]; then
		vpnsh_err "gluetun を作成できませんでした:"
		vpnsh_sanitize <"$errf" | sed 's/^/    /' >&2
		rm -f "$errf"
		# 検査に通らなかったコンテナは破棄する (この呼び出しが作ったと確かめたものだけ)
		if [ -n "$mine" ]; then
			vpnsh_docker rm -f "$mine" >/dev/null 2>&1
			rm -f "$VPNSH_STATE_DIR/gluetun.id" "$VPNSH_STATE_DIR/gluetun.env"
		fi
		return 1
	fi
	[ -n "${VPNSH_VERBOSE:-}" ] && vpnsh_sanitize <"$errf" | sed 's/^/    /' >&2
	rm -f "$errf"
	gl_inspect || { vpnsh_err "作成した gluetun を確認できません"; return 1; }
	if [ "$(cat "$VPNSH_STATE_DIR/gluetun.id")" != "$GL_ID" ]; then
		vpnsh_err "起動した gluetun が検査したものと違います"
		vpnsh_docker rm -f "$VPNSH_GLUETUN_NAME" >/dev/null 2>&1
		return 1
	fi
	return 0
}

# 外部IPの確認サービスの既定値
GL_IP_CHECK_URLS_DEFAULT="https://1.1.1.1/cdn-cgi/trace https://api.ipify.org https://checkip.amazonaws.com"
# 経路を調べるコマンド (テストでは偽物に差し替える)
GL_ROUTE="/sbin/route"

# gl_host_vpn_routed  Mac から VPN の接続先へのパケットが Mac の VPN (utun) に入るなら 0
gl_host_vpn_routed() {
	local ip
	ip="$(vpnsh_env_get WIREGUARD_ENDPOINT_IP)"
	[ -n "$ip" ] || return 1
	"$GL_ROUTE" -n get "$ip" 2>/dev/null | awk '$1 == "interface:" && $2 ~ /^utun[0-9]+$/ { f = 1 } END { exit !f }'
}

# gl_mac_public_ip  Mac の外部IPを確認サービスに順に問い合わせ、最初に読み取れたものを出す (どこからも読み取れなければ 1)
gl_mac_public_ip() {
	local urls url body ip
	urls="$(vpnsh_env_get VPNSH_IP_CHECK_URLS)"
	for url in ${urls:-$GL_IP_CHECK_URLS_DEFAULT}; do
		body="$(/usr/bin/curl -q -4 -sS --connect-timeout 2 --max-time 3 "$url" 2>/dev/null)" || continue
		ip="$(printf '%s\n' "$body" | sed -n 's/^ip=//p' | head -n 1)"
		[ -n "$ip" ] || ip="$(printf '%s\n' "$body" | head -n 1 | tr -d ' \r\t')"
		fw_is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
	done
	return 1
}

# gl_host_vpn_state  Mac の外部IPが専用IPなら same、Mac の VPN を通るが外部IPを確かめられなければ unknown を出す
gl_host_vpn_state() {
	local ip
	gl_host_vpn_routed || return 0
	ip="$(gl_mac_public_ip)" || { echo unknown; return 0; }
	[ "$ip" = "$(vpnsh_env_get EXPECTED_PUBLIC_IP)" ] && echo same
	return 0
}

# gl_host_vpn_confirm  警告を出し、端末があれば続けるか確かめる (やめるなら 1)
gl_host_vpn_confirm() {
	vpnsh_warn "Mac の外部IPが専用IP ($(vpnsh_env_get EXPECTED_PUBLIC_IP)) です。NordVPN アプリなどで専用IPのサーバーに接続している間は、vpnsh はつながりません (アプリを切断するか、別のサーバーに接続してください)"
	[ -n "${VPNSH_YES:-}" ] && return 0
	{ [ -t 0 ] && [ -r /dev/tty ]; } || return 0
	confirm "続行しますか?"
}

# gl_wait_healthy <秒>  healthy になるまで 0.5 秒ごとに確認する
gl_wait_healthy() {
	local limit="$1" i=0 max shown="" host_vpn=""
	max=$((limit * 2))
	while :; do
		gl_inspect || return 1
		[ "$GL_STATUS" = "running" ] && [ "$GL_HEALTH" = "healthy" ] && { [ -n "$shown" ] && echo >&2; return 0; }
		if [ "$GL_STATUS" != "running" ] && [ "$GL_STATUS" != "restarting" ]; then
			[ -n "$shown" ] && echo >&2
			vpnsh_err "gluetun が動いていません (状態: $GL_STATUS)"
			return 1
		fi
		if [ -z "$shown" ]; then
			host_vpn="$(gl_host_vpn_state)"
			if [ "$host_vpn" = "same" ]; then
				gl_host_vpn_confirm || return 1
			fi
			printf 'vpnsh: VPN の接続を待っています (最大 %s 秒。スリープ復帰直後は時間がかかることがあります) ' "$limit" >&2
			shown=1
		fi
		i=$((i + 1))
		if [ "$i" -ge "$max" ]; then
			echo >&2
			vpnsh_err "gluetun が ${limit} 秒以内に healthy になりませんでした (状態: $GL_STATUS / $GL_HEALTH)。直近のログ:"
			vpnsh_docker logs --tail 30 "$VPNSH_GLUETUN_NAME" 2>&1 | vpnsh_sanitize | sed 's/^/    /' >&2
			case "$host_vpn" in
				same)
					vpnsh_err "Mac の NordVPN アプリなどが専用IPのサーバーに接続しています。アプリを切断するか、別のサーバーに接続してから再実行してください"
					vpnsh_err "ほかに、秘密鍵や .env の値の誤り、NordVPN 側の問題、ネットワークの問題が考えられます"
					;;
				unknown)
					vpnsh_err "秘密鍵や .env の値の誤り、NordVPN 側の問題、ネットワークの問題が考えられます"
					vpnsh_err "Mac の NordVPN アプリなどが専用IPのサーバーに接続していないかも確かめてください"
					;;
				*) vpnsh_err "秘密鍵や .env の値の誤り、NordVPN 側の問題、ネットワークの問題が考えられます" ;;
			esac
			return 1
		fi
		[ $((i % 2)) -eq 0 ] && printf '.' >&2
		sleep 0.5
	done
}

# Docker (OrbStack) に接続できないときの案内
docker_unreachable() {
	vpnsh_err "Docker (OrbStack) に接続できません: ${GL_DOCKER_ERROR:-}"
	vpnsh_die "OrbStack が起動しているか確認してください (\`orb start\`)" "$VPNSH_EXIT_PREFLIGHT"
}

# gluetun が healthy になるまで待つ上限 (秒)
GL_HEALTH_WAIT=60

# ---- gluetun を使える状態にして、ホスト側の検査をする (成功すると SESSION_NETNS が入る) ----
SESSION_NETNS=""
prepare_gluetun() {
	local r
	gl_inspect; r=$?
	[ "$r" -eq 2 ] && docker_unreachable
	vpnsh_timing "gluetun の状態の取得 (docker inspect)"
	if [ "$r" -eq 1 ]; then
		lock_acquire
		gl_inspect; r=$?
		if [ "$r" -eq 1 ]; then
			gl_create || { lock_release; exit "$VPNSH_EXIT_PREFLIGHT"; }
		fi
		lock_release
	fi
	gl_inspect || docker_unreachable
	case "$GL_STATUS" in
		exited)
			# 起動する前に、作成時のとおりか確かめる
			gl_verify || exit "$VPNSH_EXIT_PREFLIGHT"
			vpnsh_info "停止している gluetun を起動します"
			vpnsh_docker start "$VPNSH_GLUETUN_NAME" >/dev/null || vpnsh_die "gluetun を起動できません" "$VPNSH_EXIT_PREFLIGHT"
			;;
		created)
			# 一度も起動していない (作成の途中で止まった) コンテナには secret が入っていない
			vpnsh_die "gluetun が作成途中の状態です。\`vpnsh up --recreate\` で作り直してください" "$VPNSH_EXIT_PREFLIGHT"
			;;
		paused) vpnsh_die "gluetun が一時停止 (paused) しています。\`vpnsh restart\` を実行してください" "$VPNSH_EXIT_PREFLIGHT" ;;
	esac
	gl_wait_healthy "$GL_HEALTH_WAIT" || exit "$VPNSH_EXIT_PREFLIGHT"
	vpnsh_timing "gluetun の healthy の確認"
	host_checks || exit "$VPNSH_EXIT_PREFLIGHT"
}

# host_checks  (healthy な gluetun に対して) 整合性・未適用の変更・ファイアウォール
host_checks() {
	gl_verify || return 1
	vpnsh_timing "gluetun の整合性 (ID・イメージ・Env)"
	local pending
	if pending="$(gl_pending_changes)"; then
		vpnsh_err ".env の変更が gluetun に適用されていません ($(echo "$pending" | tr '\n' ' '))。\`vpnsh up\` で適用してください"
		return 1
	fi
	vpnsh_timing "未適用の変更の確認"
	if ! gl_fw_check; then
		vpnsh_err "遮断ルールが想定どおりではないため、シェルを起動しません。VPN の再接続中の可能性もあるので、少し待ってから再実行してください。続く場合は \`vpnsh up --recreate\`"
		return 1
	fi
	vpnsh_verbose "ファイアウォールは期待値どおり ($FW_NETNS)"
	vpnsh_timing "遮断ルール・ルーティングの比較"
	# shellcheck disable=SC2034  # bin/vpnsh の run_work が work に渡す
	SESSION_NETNS="$FW_NETNS"
	return 0
}
