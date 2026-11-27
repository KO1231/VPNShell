#!/bin/bash
# shellcheck disable=SC2015  # ok / ng は常に 0 を返すので A && B || C で問題ない
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/mount.sh
. "$ROOT/lib/mount.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/vpnsh-mnttest.XXXXXX")"
T="$(cd "$T" && pwd -P)"
cleanup() {
	# 作ったものだけを名前で消す
	rm -f "$T/outside/to-proj" "$T/allowed/to-outside" "$T/allowed/to-repo"
	for d in "$T/allowed/vs/repo/sub" "$T/allowed/vs/repo" "$T/allowed/vs" "$T/allowed/proj/deep" "$T/allowed/proj" \
		"$T/allowed/a:b" "$T/allowed/a,b" "$T/allowed/日本語" "$T/allowed" "$T/outside"; do
		rmdir "$d" 2>/dev/null
	done
	rmdir "$T" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$T/allowed/proj/deep" "$T/allowed/vs/repo/sub" "$T/outside" "$T/allowed/a:b" "$T/allowed/a,b" "$T/allowed/日本語"
ln -s "$T/allowed/proj" "$T/outside/to-proj"
ln -s "$T/outside" "$T/allowed/to-outside"
ln -s "$T/allowed/vs/repo" "$T/allowed/to-repo"
ALLOWED="$T/allowed"
REPO="$T/allowed/vs/repo"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$*"; }
ng() { FAIL=$((FAIL + 1)); printf '  \033[31mNG\033[0m   %s\n' "$*"; }
# skip <説明>  省略したことを表示する (VPNSH_CI=1 なら NG にする)
skip() { if [ "${VPNSH_CI:-}" = 1 ]; then ng "省略した (CI では省略しない): $*"; else printf '  (%s)\n' "$*"; fi; }

allow() {
	local out
	if out="$(mnt_check "$1" "$ALLOWED" "$REPO" 2>&1)"; then ok "許可: ${1#"$T"/} → ${out#"$T"/}"; else ng "許可されるはずが拒否: ${1#"$T"/} ($out)"; fi
}
deny() {
	local out
	if out="$(mnt_check "$1" "$ALLOWED" "$REPO" 2>&1)"; then ng "拒否されるはずが許可: ${1#"$T"/} → $out"; else ok "拒否: ${1#"$T"/}"; fi
}

echo "== 許可されるもの"
allow "$T/allowed/proj"
allow "$T/allowed/proj/deep"
allow "$T/outside/to-proj"
allow "$T/allowed/日本語"
# APFS は大文字小文字を区別しないので、大文字で書いても同じ実体として許可される
[ -d "$T/allowed/PROJ" ] && allow "$T/allowed/PROJ" || skip "このファイルシステムは大文字小文字を区別するので省略"

echo "== 拒否されるもの"
deny "$T/allowed"
deny "$T"
deny "$T/outside"
deny "$T/allowed/to-outside"
deny "$T/allowed/vs"
deny "$REPO"
deny "$REPO/sub"
deny "$T/allowed/to-repo"
deny "$T/allowed/a:b"
deny "$T/allowed/a,b"
deny "$T/allowed/no-such-dir"
if [ -d "$T/allowed/VS/REPO/SUB" ]; then
	deny "$T/allowed/VS/REPO/SUB"
	deny "$T/ALLOWED"
fi

echo "== 表示用のパス"
d="$(HOME="$T" mnt_display "$T/allowed/proj")"
# shellcheck disable=SC2088  # 表示用の文字列として ~ を比べる
[ "$d" = "~/allowed/proj" ] && ok "\$HOME を ~ に置き換える ($d)" || ng "表示が想定外: $d"
d="$(mnt_display "/x/\$(id)/y")"
case "$d" in *'$('*) ng "記号が残っている: $d" ;; *) ok "表示に使えない文字を置き換える ($d)" ;; esac

echo
echo "結果: OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ]
