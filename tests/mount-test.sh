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

echo "== マウントの準備 (-m / --mount-cwd-rw)"
H="$T/pm/home"
mkdir -p "$H/Projects/app" "$H/Library/x" "$T/pm/elsewhere"
# pm <ro|rw|""> <mount-root> <カレントディレクトリ>  prepare_mount を呼び、compose run に渡す引数と終了コードを出す
pm() {
	(
		HOME="$H"; VPNSH_MOUNT="$1"; VPNSH_MOUNT_ROOT="$2"; VPNSH_ROOT="$ROOT"
		cd "$3" || exit 9
		prepare_mount 2>"$T/pm.err" && mnt_run_args | tr '\n' ' '
	)
	echo "rc=$?"
}
# shellcheck disable=SC2088  # ~/ の書き方の mount-root と、表示用の ~ を試す
want="-v $H/Projects/app:/work:ro -w /work -e VPNSH_MOUNT=ro -e VPNSH_MOUNT_DISPLAY=~/Projects/app --label vpnsh.mount=ro rc=0"
# shellcheck disable=SC2088
out="$(pm ro "~/Projects" "$H/Projects/app")"
[ "$out" = "$want" ] && ok "-m では実体のパスを /work に読み取り専用 (:ro) でマウントする引数を作る" || ng "-m の引数が想定外: $out"
out="$(pm rw "$H/Projects" "$H/Projects/app")"
case "$out" in "-v $H/Projects/app:/work:rw "*"--label vpnsh.mount=rw rc=0") grep -q '警告' "$T/pm.err" && ok "--mount-cwd-rw では読み書き可能 (:rw) でマウントし、警告を出す" || ng "--mount-cwd-rw で警告が出ない" ;; *) ng "--mount-cwd-rw の引数が想定外: $out" ;; esac
out="$(pm "" "$H/Projects" "$H/Projects/app")"
[ "$out" = "rc=0" ] && ok "マウントしないときは引数を作らない" || ng "マウントしないときの結果が想定外: $out"
bad=0
for root in "$H/Library/x" "$T/pm/elsewhere" "$H" "Projects"; do
	out="$(pm ro "$root" "$H/Projects/app")"
	{ [ "$out" = "rc=125" ] && grep -q 'mount-root が正しくありません' "$T/pm.err"; } || { bad=$((bad + 1)); echo "    mount-root $root を拒否しない: $out"; }
done
[ "$bad" -eq 0 ] && ok ".env の mount-root も使う前に検査し直す (~/Library の中・ホームの外・ホームそのもの・相対パスなら 125 で止まる)" || ng "検査し直さない mount-root が $bad 個"
out="$(pm ro "$H/Projects" "$T/pm/elsewhere")"
[ "$out" = "rc=125" ] && ok "カレントディレクトリが mount-root の配下でなければ 125 で止まる" || ng "mount-root の外のディレクトリの結果が想定外: $out"
rm -f "$T/pm.err"
rmdir "$H/Projects/app" "$H/Projects" "$H/Library/x" "$H/Library" "$H" "$T/pm/elsewhere" "$T/pm" 2>/dev/null

echo
echo "結果: OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ]
