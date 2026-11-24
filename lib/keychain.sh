# shellcheck shell=bash
# macOS キーチェーンでの WireGuard 秘密鍵の保管
#
# - 項目は「信頼済みアプリなし」(-T "") で登録するので、取り出すたびに macOS の確認ダイアログが出る
#   (ダイアログで「常に許可」を押すと、以後は確認なしで取り出せるようになるので押さないこと)
# - 登録し直すときは、いったん削除してから追加する。`add-generic-password -U` は既存の
#   信頼済みアプリ一覧を引き継ぐので、過去に「常に許可」を押していると取り消されないため
# - 鍵の値はコマンドライン引数に書かない (ps やシェル履歴に残さない)。登録は security -i に標準入力で渡す
# - security は PATH から探さず、絶対パスで呼ぶ (信頼済みアプリの判定はこのパスに結び付くため)
# - NordVPN の専用IPの鍵は失効も作り直しもできない。漏れたときの回復は専用IPの変更 (契約ごとに1回) だけ

VPNSH_KC_SERVICE="vpnshell"
VPNSH_KC_ACCOUNT="wireguard-private-key"
VPNSH_SECURITY="/usr/bin/security"

# WireGuard の鍵の形式 (32 バイトの base64 = 44 文字、末尾 '=')
kc_valid_key() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/]{43}=$'
}

# kc_exists  項目があれば 0 (秘密の値は読まないので確認ダイアログは出ない)
kc_exists() {
	"$VPNSH_SECURITY" find-generic-password -s "$VPNSH_KC_SERVICE" -a "$VPNSH_KC_ACCOUNT" >/dev/null 2>&1
}

# kc_set <鍵>  既存の項目を削除してから、信頼済みアプリなしで登録する
kc_set() {
	local key="$1" out
	kc_valid_key "$key" || vpnsh_die "秘密鍵の形式が正しくありません (44文字の base64 であること)"
	if kc_exists; then
		kc_delete || vpnsh_die "キーチェーンの既存の項目を削除できませんでした"
		kc_exists && vpnsh_die "キーチェーンの既存の項目が削除されていません"
	fi
	# 値は printf (シェルの組み込み) → パイプ → security -i なので、プロセスの引数には現れない
	out="$(printf 'add-generic-password -s "%s" -a "%s" -l "VPNShell WireGuard private key" -j "VPNShell (NordVPN dedicated IP)" -T "" -w "%s"\n' \
		"$VPNSH_KC_SERVICE" "$VPNSH_KC_ACCOUNT" "$key" | "$VPNSH_SECURITY" -i 2>&1)"
	key=""
	# security -i は中のコマンドが失敗しても 0 で終わり得るので、出力と結果の両方で確かめる
	if printf '%s' "$out" | grep -qiE 'error|could not|failed|denied'; then
		vpnsh_err "キーチェーンへの登録に失敗しました:"
		printf '%s\n' "$out" | grep -v '^security> *$' | vpnsh_sanitize | sed 's/^/    /' >&2
		exit 1
	fi
	kc_exists || vpnsh_die "キーチェーンへの登録に失敗しました (項目が見つかりません)"
}

# kc_get  鍵を stdout に出す。失敗の理由を分けて表示し、0 以外を返す
kc_get() {
	local out rc errf
	errf="$(mktemp "${TMPDIR:-/tmp}/vpnsh-kc.XXXXXX")"
	out="$("$VPNSH_SECURITY" find-generic-password -s "$VPNSH_KC_SERVICE" -a "$VPNSH_KC_ACCOUNT" -w 2>"$errf")"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 44 ] || grep -q 'could not be found' "$errf"; then
			vpnsh_err "キーチェーンに WireGuard の秘密鍵がありません。\`vpnsh setup --import <.conf>\` を実行してください"
		elif grep -qi 'interaction is not allowed' "$errf"; then
			vpnsh_err "キーチェーンがロックされているか、確認ダイアログを出せません (SSH 経由のログインなど)。Mac の画面上のターミナルで実行してください"
		else
			vpnsh_err "キーチェーンから秘密鍵を取り出せませんでした (拒否された可能性があります): $(head -n 1 "$errf" | vpnsh_sanitize)"
		fi
		rm -f "$errf"
		return 1
	fi
	rm -f "$errf"
	if ! kc_valid_key "$out"; then
		vpnsh_err "キーチェーンの秘密鍵の形式が正しくありません。\`vpnsh setup --import <.conf>\` で登録し直してください"
		return 1
	fi
	printf '%s' "$out"
}

# kc_delete
kc_delete() {
	"$VPNSH_SECURITY" delete-generic-password -s "$VPNSH_KC_SERVICE" -a "$VPNSH_KC_ACCOUNT" >/dev/null 2>&1
}
