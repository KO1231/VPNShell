# shellcheck shell=bash
# shellcheck disable=SC2034  # SETUP_* は bin/vpnsh が、VPNSH_ENV_LOADED は lib/common.sh が参照する

# require_env  .env の値を検査する (問題があれば終了コード 125 で終了する)
require_env() {
	if [ ! -f "$VPNSH_ENV_FILE" ]; then
		vpnsh_die "設定 (.env) がありません。まず \`vpnsh setup --import <NordVPN の .conf>\` を実行してください" "$VPNSH_EXIT_PREFLIGHT"
	fi
	vpnsh_env_validate || exit "$VPNSH_EXIT_PREFLIGHT"
	local k
	for k in WIREGUARD_ENDPOINT_IP WIREGUARD_ENDPOINT_PORT WIREGUARD_PUBLIC_KEY WIREGUARD_ADDRESSES WIREGUARD_MTU; do
		[ -n "$(vpnsh_env_get "$k")" ] || vpnsh_die ".env に $k がありません。\`vpnsh setup --import <.conf>\` をやり直してください" "$VPNSH_EXIT_PREFLIGHT"
	done
	fw_is_ipv4 "$(vpnsh_env_get WIREGUARD_ENDPOINT_IP)" || vpnsh_die ".env の WIREGUARD_ENDPOINT_IP が IPv4 アドレスではありません" "$VPNSH_EXIT_PREFLIGHT"
	fw_is_port "$(vpnsh_env_get WIREGUARD_ENDPOINT_PORT)" || vpnsh_die ".env の WIREGUARD_ENDPOINT_PORT がポート番号ではありません" "$VPNSH_EXIT_PREFLIGHT"
	kc_valid_key "$(vpnsh_env_get WIREGUARD_PUBLIC_KEY)" || vpnsh_die ".env の WIREGUARD_PUBLIC_KEY の形式が正しくありません" "$VPNSH_EXIT_PREFLIGHT"
	printf '%s' "$(vpnsh_env_get WIREGUARD_ADDRESSES)" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/32$' ||
		vpnsh_die ".env の WIREGUARD_ADDRESSES は IPv4 の /32 アドレス 1つにしてください" "$VPNSH_EXIT_PREFLIGHT"
	case "$(vpnsh_env_get WIREGUARD_MTU)" in "" | *[!0-9]*) vpnsh_die ".env の WIREGUARD_MTU が数値ではありません" "$VPNSH_EXIT_PREFLIGHT" ;; esac
}

# require_expected_ip  .env に確定した専用IP があること
require_expected_ip() {
	fw_is_ipv4 "$(vpnsh_env_get EXPECTED_PUBLIC_IP)" ||
		vpnsh_die ".env に EXPECTED_PUBLIC_IP (IPv4) がありません。\`vpnsh setup --import <.conf>\` を最後まで実行してください" "$VPNSH_EXIT_PREFLIGHT"
}

# conf_get <ファイル> <セクション> <キー>
conf_get() {
	awk -v sec="$2" -v key="$3" '
		/^[[:space:]]*\[/ { cur = $0; gsub(/[][[:space:]]/, "", cur); next }
		cur == sec {
			line = $0; sub(/[#;].*/, "", line)
			n = index(line, "=")
			if (n == 0) next
			k = substr(line, 1, n - 1); v = substr(line, n + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
			if (tolower(k) == tolower(key)) { print v; exit }
		}' <"$1"
}

is_ipv4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

# conf_resolve_ipv4 <ホスト名>  IPv4 アドレスに解決して出す
conf_resolve_ipv4() { dscacheutil -q host -a name "$1" 2>/dev/null | sed -n 's/^ip_address: //p' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n 1; }

# setup_parse_conf <.conf>  WireGuard の設定を読んで SETUP_* に入れる (使えない設定なら終了する)
SETUP_PRIV=""
SETUP_PUB=""
SETUP_HOST=""
SETUP_PORT=""
SETUP_ADDR=""
setup_parse_conf() {
	local conf="$1" priv addr pub endpoint psk host port ip4addr resolved
	priv="$(conf_get "$conf" Interface PrivateKey)"
	addr="$(conf_get "$conf" Interface Address)"
	pub="$(conf_get "$conf" Peer PublicKey)"
	endpoint="$(conf_get "$conf" Peer Endpoint)"
	psk="$(conf_get "$conf" Peer PresharedKey)"
	[ -n "$psk" ] && vpnsh_die "PresharedKey 付きの設定には対応していません"
	kc_valid_key "$priv" || vpnsh_die ".conf の [Interface] PrivateKey が見つからないか、形式が正しくありません"
	kc_valid_key "$pub" || vpnsh_die ".conf の [Peer] PublicKey が見つからないか、形式が正しくありません"
	ip4addr="$(printf '%s' "$addr" | tr ',' '\n' | tr -d ' ' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?$' | head -n 1)"
	[ -n "$ip4addr" ] || vpnsh_die ".conf の [Interface] Address に IPv4 アドレスがありません: $addr"
	# アドレスは /32 にそろえる (/16 などのままだとルーティングの期待値と合わない)
	if [ "${ip4addr#*/}" != "32" ]; then
		vpnsh_info "Address $ip4addr を ${ip4addr%/*}/32 にそろえます"
		ip4addr="${ip4addr%/*}/32"
	fi
	host="${endpoint%:*}"; port="${endpoint##*:}"
	case "$port" in "" | *[!0-9]*) vpnsh_die ".conf の [Peer] Endpoint の形式が正しくありません: $endpoint" ;; esac
	if ! is_ipv4 "$host"; then
		resolved="$(conf_resolve_ipv4 "$host")"
		[ -n "$resolved" ] || vpnsh_die "Endpoint のホスト名 $host を IPv4 アドレスに解決できません"
		vpnsh_info "Endpoint $host を $resolved に解決しました (gluetun にはホスト名を渡せないため)"
		host="$resolved"
	fi
	SETUP_PRIV="$priv"; SETUP_PUB="$pub"; SETUP_HOST="$host"; SETUP_PORT="$port"; SETUP_ADDR="$ip4addr"
	priv=""
}

# conf_sync_warning <ファイル>  .conf が同期・共有されやすい場所にあれば警告する
conf_sync_warning() {
	local real home lower
	real="$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) // ""' "$1")"
	home="$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) // ""' "$HOME")"
	lower="$(printf '%s' "$real" | tr '[:upper:]' '[:lower:]')"
	home="$(printf '%s' "$home" | tr '[:upper:]' '[:lower:]')"
	case "$lower" in
		"$home/library/mobile documents/"* | "$home/library/cloudstorage/"* | "$home/dropbox"* | "$home/google drive"* | "$home/onedrive"* | "$home/box"* | /volumes/*)
			vpnsh_warn "$1 は同期フォルダか外部ボリュームにあります。秘密鍵が他の端末やクラウドに残る恐れがあります。取り込んだら同期先からも確実に削除してください"
			;;
		"$home/desktop/"* | "$home/documents/"*)
			vpnsh_warn "$1 はデスクトップか書類フォルダにあります。iCloud の「デスクトップと書類」を使っている場合はクラウドに同期されます。取り込んだら確実に削除してください"
			;;
	esac
}

env_write() {
	# env_write <KEY> <VALUE>  .env の KEY を置き換える (無ければ追記)
	local tmp="$VPNSH_ENV_FILE.tmp.$$"
	if [ -f "$VPNSH_ENV_FILE" ]; then
		grep -v "^$1=" "$VPNSH_ENV_FILE" >"$tmp" || true
	else
		: >"$tmp"
	fi
	printf '%s=%s\n' "$1" "$2" >>"$tmp"
	chmod 0600 "$tmp" && mv -f "$tmp" "$VPNSH_ENV_FILE"
	VPNSH_ENV_LOADED=""  # 読み込み直させる
}
