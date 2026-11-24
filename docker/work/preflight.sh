#!/bin/bash
# VPNShell: work コンテナ内の起動前チェック
#
# 1つでも失敗したら 0 以外で終了する (entrypoint.sh がシェルを起動しない)。
# 機械的な検査なので、全体を VPNSH_PREFLIGHT_BUDGET 秒 (既定 8 秒) で打ち切る (呼び出し側の timeout)。
#
# 入力 (環境変数):
#   EXPECTED_PUBLIC_IP     照合する専用IP (setup の観測モードでは空)
#   VPNSH_GLUETUN_NETNS    ホスト側で取得した gluetun のネットワーク名前空間 (net:[...])
#   VPNSH_IP_CHECK_URLS    外部IP確認サービス (空白区切り。空なら既定の3か所)
#   VPNSH_PREFLIGHT_MODE   "check" (既定) / "observe" (setup 用: 照合せず観測したIPを出力)
# 出力:
#   成功時、/tmp/vpnsh/state に PUBLIC_IP=... を書く (プロンプト表示用)
#   observe モードでは、観測した IP を stdout に1行ずつ出す
set -u

MODE="${VPNSH_PREFLIGHT_MODE:-check}"
DEFAULT_URLS="https://1.1.1.1/cdn-cgi/trace https://api.ipify.org https://checkip.amazonaws.com"
URLS="${VPNSH_IP_CHECK_URLS:-$DEFAULT_URLS}"
TMP="$(mktemp -d /tmp/vpnsh-preflight.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
# --timing: 項目ごとの所要時間 (entrypoint.sh が起点の時刻を渡す)
now_ms() { local t="${EPOCHREALTIME/./}"; printf '%s' "$((t / 1000))"; }
T_LAST="${VPNSH_TIMING_LAST:-}"
tmark() {
	[ -n "${VPNSH_TIMING:-}" ] && [ -n "${VPNSH_TIMING_T0:-}" ] || return 0
	local now; now="$(now_ms)"
	printf 'vpnsh: [時間] %+6d ms (累計 %5d ms)  起動前チェック: %s\n' "$((now - ${T_LAST:-$now}))" "$((now - VPNSH_TIMING_T0))" "$1" >&2
	T_LAST="$now"
}
say() { printf 'vpnsh: %s\n' "$*" >&2; }
fail() { FAILED=1; printf 'vpnsh: \033[31m[NG]\033[0m %s\n' "$*" >&2; }
pass() { [ -n "${VPNSH_VERBOSE:-}" ] && printf 'vpnsh: [OK] %s\n' "$*" >&2; return 0; }

# --- 1. 同一性: gluetun と同じネットワーク名前空間にいること ---
self_ns="$(readlink /proc/self/ns/net)"
if [ -z "${VPNSH_GLUETUN_NETNS:-}" ]; then
	fail "gluetun のネットワーク名前空間が渡されていません (vpnsh 経由で起動してください)"
elif [ "$self_ns" != "$VPNSH_GLUETUN_NETNS" ]; then
	fail "ネットワーク名前空間が gluetun と一致しません ($self_ns != $VPNSH_GLUETUN_NETNS)。gluetun が作り直された可能性があります"
else
	pass "ネットワーク名前空間が一致 ($self_ns)"
fi

tmark "ネットワーク名前空間"

# --- 2. IPv6 が構造的に無効であること (通信を試すのではなく状態で確認) ---
v6_disabled="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo missing)"
v6_addrs="$(awk '$6 != "lo"' /proc/net/if_inet6 2>/dev/null | wc -l | tr -d ' ')"
# 既定ルート (lo 上の「到達不能」ルートは除く)
v6_default="$(awk '$1 == "00000000000000000000000000000000" && $2 == "00" && $10 != "lo"' /proc/net/ipv6_route 2>/dev/null | wc -l | tr -d ' ')"
if [ "$v6_disabled" = "1" ] && [ "$v6_addrs" = "0" ] && [ "$v6_default" = "0" ]; then
	pass "IPv6 は無効"
else
	fail "IPv6 が無効になっていません (disable_ipv6=$v6_disabled, アドレス=$v6_addrs, 既定ルート=$v6_default)"
fi

# --- 2b. 権限の無いプロセスが 1024 未満のポートで待ち受けられないこと ---
# (全シェルが同じ名前空間にいるので、これが無いと、あるシェルが 127.0.0.1:53 を取って他のシェルの名前解決を乗っ取れる)
ups="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null)"
if [ "$ups" = "1024" ]; then
	pass "1024 未満のポートは権限なしでは使えない"
else
	fail "権限の無いプロセスが ${ups:-?} 番以上のポートで待ち受けられます (1024 であること)。\`vpnsh up\` で gluetun を作り直してください"
fi

# --- 3. DNS の設定: gluetun 内蔵 DNS (127.0.0.1) だけを使うこと ---
ns_lines="$(grep -E '^[[:space:]]*nameserver[[:space:]]' /etc/resolv.conf | awk '{print $2}' | sort -u | tr '\n' ' ')"
if [ "$ns_lines" = "127.0.0.1 " ]; then
	pass "DNS は gluetun 内蔵 (127.0.0.1) のみ"
else
	fail "DNS の設定が想定外です (nameserver: ${ns_lines:-なし})。gluetun の DNS がまだ起動していない可能性があります"
fi

tmark "IPv6・DNS の設定"

# --- 4. ヘルスサーバー (:9999) が 200、制御用サーバー (:8000) が 401 ---
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://127.0.0.1:9999 2>/dev/null)"
if [ "$code" = "200" ]; then pass "gluetun のヘルスサーバーが 200"; else fail "gluetun のヘルスサーバーが 200 を返しません (${code:-応答なし})。VPN が健全ではありません"; fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://127.0.0.1:8000/v1/vpn/status 2>/dev/null)"
if [ "$code" = "401" ]; then pass "制御用サーバーは認証が必要 (401)"; else fail "制御用サーバーが 401 を返しません (${code:-応答なし})。認証が効いていない可能性があります"; fi

tmark "ヘルスサーバー・制御用サーバー"

# --- 5. 外部IP: 複数の確認サービスに並列で問い合わせ、応答した全件が一致すること ---
# 本文から IPv4 を取り出す (Cloudflare の trace は "ip=" 行、それ以外は1行目)
extract_ip() {
	local body="$1" ip
	ip="$(printf '%s\n' "$body" | sed -n 's/^ip=//p' | head -n 1)"
	[ -z "$ip" ] && ip="$(printf '%s\n' "$body" | head -n 1 | tr -d ' \r\t')"
	if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then printf '%s' "$ip"; fi
}
query() {
	local i="$1" url="$2" body rc try
	for try in 1 2; do
		body="$(curl -4 -sS --connect-timeout 2 --max-time 4 "$url" 2>"$TMP/$i.err")"
		rc=$?
		# 名前解決の失敗 (gluetun の DNS 再起動と重なった場合など) だけ1回再試行する
		[ "$rc" -eq 6 ] && [ "$try" -eq 1 ] && { sleep 1; continue; }
		break
	done
	if [ "$rc" -eq 0 ]; then
		printf '%s\n' "$(extract_ip "$body")" >"$TMP/$i.ip"
	else
		printf 'curl exit %s: %s\n' "$rc" "$(head -n 1 "$TMP/$i.err")" >"$TMP/$i.fail"
	fi
}
n=0
for url in $URLS; do
	n=$((n + 1))
	query "$n" "$url" &
done
wait
tmark "外部IP の確認 (3か所に並列)"

responded=0
observed=""
n=0
for url in $URLS; do
	n=$((n + 1))
	if [ -f "$TMP/$n.ip" ]; then
		ip="$(cat "$TMP/$n.ip")"
		if [ -z "$ip" ]; then
			fail "外部IP: $url の応答から IP を読み取れません"
			continue
		fi
		responded=$((responded + 1))
		observed="$observed $ip"
		if [ "$MODE" = "check" ] && [ "$ip" != "${EXPECTED_PUBLIC_IP:-}" ]; then
			fail "外部IP が一致しません: $url → $ip (期待値 ${EXPECTED_PUBLIC_IP:-未設定})"
		else
			pass "外部IP: $url → $ip"
		fi
	else
		say "外部IP: $url に届きません ($(cat "$TMP/$n.fail" 2>/dev/null))。※不一致ではありません"
	fi
done
if [ "$responded" -lt 2 ]; then
	fail "外部IP: 応答した確認サービスが ${responded} 件です (2件以上必要)。VPN の通信ができていない可能性があります"
fi

if [ "$MODE" = "observe" ]; then
	# setup 用: 観測した IP を出力する (応答した全件が同じであることは確認する)
	# shellcheck disable=SC2086  # 空白区切りの一覧を分割する
	uniq_ips="$(printf '%s\n' $observed | sort -u)"
	if [ "$(printf '%s\n' "$uniq_ips" | sed '/^$/d' | wc -l | tr -d ' ')" != "1" ]; then
		fail "確認サービスごとに異なる IP が返りました:$observed"
	fi
	[ "$FAILED" -eq 0 ] && printf '%s\n' "$uniq_ips"
	exit "$FAILED"
fi

if [ "$FAILED" -ne 0 ]; then
	exit 1
fi
mkdir -p /tmp/vpnsh
printf 'PUBLIC_IP=%s\n' "${EXPECTED_PUBLIC_IP}" >/tmp/vpnsh/state
exit 0
