#!/bin/bash
# shellcheck disable=SC2015  # ok / ng は常に 0 を返すので A && B || C で問題ない
# shellcheck disable=SC2030,SC2031,SC2034  # サブシェルで変数を差し替えて試す。GL_* などは lib が参照する
# Docker を使わない単体テスト。本物の gluetun・キーチェーン・~/.ssh・~/Library には触れない
# (キーチェーンや docker を呼ぶ関数は、偽物の関数・スクリプトに差し替えて試す)。
#
#   1. PATH から、マウントできる場所・相対パスなどを除く (vpnsh_safe_path)
#   2. 環境変数・.env・遮断ルールの値からの注入を防ぐ (vpnsh_clean_env、vpnsh_env_validate、fw_render、fw_normalize)
#   3. gluetun の整合性の検査 (gl_env_policy、gl_verify_static、gl_pending_changes の sysctl)
#   4. ホスト鍵の行の検査 (ssh_valid_keyscan_line)
#   5. キーチェーンの権限の読み取り (dr_kc_acl。偽の security の出力で試す)
#   6. 自動 down の判定 (idle_seconds、cmd_idle_check)
#   7. 表示の安全 (vpnsh_visible) と、使い方の誤りの終了コード (bin/vpnsh)
#
# 使い方: tests/unit-test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/vpnsh-unittest.XXXXXX")"
T="$(cd "$T" && pwd -P)"
cleanup() {
	find "$T" -depth -mindepth 1 \( -type f -o -type l \) -delete 2>/dev/null
	find "$T" -depth -mindepth 1 -type d -empty -delete 2>/dev/null
	rmdir "$T" 2>/dev/null
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$*"; }
ng() { FAIL=$((FAIL + 1)); printf '  \033[31mNG\033[0m   %s\n' "$*"; }

VPNSH_ROOT="$ROOT"
VPNSH_STATE_DIR="$T/state"
VPNSH_ENV_FILE="$T/env"
mkdir -p "$VPNSH_STATE_DIR"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/fwcheck.sh
. "$ROOT/lib/fwcheck.sh"
# shellcheck source=lib/keychain.sh
. "$ROOT/lib/keychain.sh"
# shellcheck source=lib/gluetun.sh
. "$ROOT/lib/gluetun.sh"
# shellcheck source=lib/ssh.sh
. "$ROOT/lib/ssh.sh"
# shellcheck source=lib/doctor.sh
. "$ROOT/lib/doctor.sh"
# shellcheck source=lib/idle.sh
. "$ROOT/lib/idle.sh"

echo "== 1. PATH の安全化"
mkdir -p "$T/home/Projects/app/bin" "$T/home/Projects/app/node_modules/.bin" "$T/home/bin" "$T/other"
ln -s "$T/home/Projects/app/bin" "$T/home/linked-bin"
out="$(HOME="$T/home" PATH="$T/home/Projects/app/bin:./node_modules/.bin::$T/home/linked-bin:$T/nonexistent:$T/home/bin:$T/other:$T/home/Projects/app/node_modules/.bin" vpnsh_safe_path "$T/home/Projects")"
case ":$out:" in *"Projects"* | *":./"* | *"::"* | *"linked-bin"* | *nonexistent*) ng "残ってはいけないものが PATH に残った: $out" ;; *) ok "マウントできる場所の配下・相対パス・空・存在しない・シンボリックリンク経由のものを除く" ;; esac
case ":$out:" in *":$T/home/bin:$T/other:"*) ok "それ以外は順序を保って残す" ;; *) ng "残すべきものが消えた: $out" ;; esac
case ":$out:" in *":/usr/bin:/bin:/usr/sbin:/sbin:"*) ok "/usr/bin などを必ず含める" ;; *) ng "/usr/bin などが無い: $out" ;; esac
# 大文字・小文字を区別しないファイルシステム (APFS の既定) では、綴りを変えてもマウントできる場所の配下を指せる。
# 区別するファイルシステムでも判定を通すよう、小文字の綴りのディレクトリを実際に作って試す
mkdir -p "$T/home2/projects/app/bin" "$T/home2/bin"
out="$(HOME="$T/home2" PATH="$T/home2/projects/app/bin:$T/home2/bin" vpnsh_safe_path "$T/home2/projects")"
out2="$(HOME="$T/home2" PATH="$T/home2/projects/app/bin:$T/home2/bin" vpnsh_safe_path "$T/HOME2/PROJECTS")"
out3="$(HOME="$T/HOME2" PATH="$T/home2/projects/app/bin:$T/home2/bin" vpnsh_safe_path "$T/home2/Projects")"
case ":$out:$out2:$out3:" in
	*"projects/app/bin"*) ng "綴りの大文字・小文字が違うと、マウントできる場所の配下が PATH に残る: $out / $out2 / $out3" ;;
	*) ok "綴りの大文字・小文字が違っても、マウントできる場所の配下を PATH から除く" ;;
esac

echo "== 1b. マウントを許可する場所 (mount-root) の検査"
# shellcheck source=lib/mount.sh
. "$ROOT/lib/mount.sh"
mkdir -p "$T/home/src/app" "$T/home/.ssh" "$T/home/Library/x" "$T/home/a b" "$T/home/.config/dev"
out="$(HOME="$T/home" mnt_root_ok "$T/home/src" 2>/dev/null)" && [ "$out" = "$T/home/src" ] && ok "ホームの中のディレクトリは使える" || ng "ホームの中のディレクトリを拒否した: $out"
# shellcheck disable=SC2088  # "~/" という文字のまま渡して試す
out="$(HOME="$T/home" mnt_root_ok "~/src" 2>/dev/null)" && [ "$out" = "$T/home/src" ] && ok "~/… の書き方も使える" || ng "~/… の書き方を拒否した: $out"
bad=0
for d in "$T/home" "$T/home/.ssh" "$T/home/.config/dev" "$T/home/Library/x" "$T/home/a b" "$T" "src" "$T/home/nonexistent"; do
	HOME="$T/home" mnt_root_ok "$d" >/dev/null 2>&1 && { bad=$((bad + 1)); echo "    受け付けた: $d"; }
done
[ "$bad" -eq 0 ] && ok "ホームそのもの・. で始まるディレクトリの中・~/Library・空白を含むパス・ホームの外・相対パス・無いディレクトリは使えない" || ng "使えないはずの場所を $bad 個受け付けた"
# 大文字・小文字を区別しないファイルシステム (APFS の既定) では、綴りを変えても ~/Library の中を指せる。
# 区別するファイルシステムでも判定を通すよう、小文字の library を実際に作った別のホームでも試す
mkdir -p "$T/home3/library/x"
bad=0
for d in "$T/home/library" "$T/home/library/x" "$T/home/LIBRARY/x" "$T/home/LiBrArY/x"; do
	HOME="$T/home" mnt_root_ok "$d" >/dev/null 2>&1 && { bad=$((bad + 1)); echo "    受け付けた: $d"; }
done
for d in "$T/home3/library" "$T/home3/library/x"; do
	HOME="$T/home3" mnt_root_ok "$d" >/dev/null 2>&1 && { bad=$((bad + 1)); echo "    受け付けた: $d"; }
done
[ "$bad" -eq 0 ] && ok "~/library・~/LIBRARY など、綴りの大文字・小文字を変えても ~/Library の中は使えない" || ng "綴りを変えた ~/Library を $bad 個受け付けた"

echo "== 2. 注入を防ぐ"
out="$(export COMPOSE_FILE=x.yaml COMPOSE_PROJECT_NAME=evil DOCKER_HOST=tcp://1.2.3.4 BUILDKIT_HOST=x WIREGUARD_ENDPOINT_IP=6.6.6.6 EXPECTED_PUBLIC_IP=6.6.6.6 VPNSH_WG_PRIVATE_KEY=secret
	vpnsh_clean_env; env | grep -E '^(COMPOSE_|DOCKER_HOST|BUILDKIT_|WIREGUARD_|EXPECTED_PUBLIC_IP|VPNSH_WG_PRIVATE_KEY)' | cut -d= -f1 | tr '\n' ' ')"
[ -z "$out" ] && ok "COMPOSE_* / DOCKER_* / BUILDKIT_* / compose の変数 / 秘密鍵の変数を環境から消す" || ng "環境に残った: $out"
good=0 bad=0
for line in 'export A=1' 'A="x"' "A='x'" 'A=$(id)' 'A=`id`' 'A=1 # c' 'A= 1' 'A=a\b' 'a=1'; do
	printf '%s\n' "$line" >"$VPNSH_ENV_FILE"
	if vpnsh_env_validate 2>/dev/null; then bad=$((bad + 1)); echo "    受け付けた: $line"; else good=$((good + 1)); fi
done
[ "$bad" -eq 0 ] && ok ".env の不正な書式 ($good 種類) をすべて拒否する" || ng ".env の不正な書式を $bad 個受け付けた"
printf '%s\n' '# コメント' 'WIREGUARD_ENDPOINT_IP=1.2.3.4' 'WIREGUARD_ADDRESSES=10.5.0.2/32' '' >"$VPNSH_ENV_FILE"
vpnsh_env_validate 2>/dev/null && ok ".env の正しい書式は受け付ける" || ng ".env の正しい書式を拒否した"
printf '%s\n' '-A OUTPUT -d @@ENDPOINT_IP@@ -p udp --dport @@ENDPOINT_PORT@@ -j ACCEPT' >"$T/tmpl"
bad=0
for v in '1.2.3.4 -j ACCEPT' '1.2.3.4/0' '1.2.3.4;id' '0.0.0.0/0' 'a.b.c.d' '1.2.3'; do
	fw_render "$T/tmpl" "$v" 51820 >/dev/null 2>&1 && { bad=$((bad + 1)); echo "    受け付けた IP: $v"; }
done
for v in '51820 -j ACCEPT' '0' '70000' '1-65535' ''; do
	fw_render "$T/tmpl" 1.2.3.4 "$v" >/dev/null 2>&1 && { bad=$((bad + 1)); echo "    受け付けたポート: $v"; }
done
[ "$bad" -eq 0 ] && ok "遮断ルールに埋め込む値の不正なもの (IP・ポート) をすべて拒否する" || ng "不正な値を $bad 個受け付けた"
out="$(fw_render "$T/tmpl" 1.2.3.4 51820 2>/dev/null)"
[ "$out" = "-A OUTPUT -d 1.2.3.4 -p udp --dport 51820 -j ACCEPT" ] && ok "正しい値は埋め込む" || ng "埋め込みが想定外: $out"
out="$(printf '%s\n' '-A X -d 11.2.3.45 -j ACCEPT' '-A X -d 1.2.3.4 -j ACCEPT' '-A X --dport 518201 -j ACCEPT' | FW_EP_IP=1.2.3.4 FW_EP_PORT=51820 fw_normalize)"
case "$out" in *"11.2.3.45"*"@@ENDPOINT_IP@@"*"518201"*) ok "正規化は値の一部 (11.2.3.45、518201) を置き換えない" ;; *) ng "正規化が想定外: $out" ;; esac

echo "== 3. gluetun の整合性の検査"
PIN="$(gl_pinned_image)"
vpnsh_docker() { [ "$1 $2" = "image inspect" ] && echo "sha256:pinned"; return 0; }
baseline() {
	GL_CONFIG_IMAGE="$PIN"; GL_IMAGE_ID="sha256:pinned"; GL_PRIVILEGED=false; GL_CAPADD=CAP_NET_ADMIN; GL_PIDMODE=""
	GL_NETMODE=vpnshell_default; GL_SYSCTLS="$GL_REQUIRED_SYSCTLS"; GL_DUP_ENV=""
	GL_MOUNTS="bind|/iptables/post-rules.txt|$VPNSH_STATE_DIR/post-rules.txt|ro"
	GL_ENV_TEXT="$(printf '%s\n' "$GL_REQUIRED_ENV" | sed '/^$/d')"
	gl_env_lines >"$VPNSH_STATE_DIR/gluetun.env"
}
baseline
gl_verify_static 2>/dev/null && ok "正しい状態は検査に通る" || { gl_verify_static; ng "正しい状態が検査に通らない"; }
try() {
	# try <説明> <変更する代入...>  変更して検査に通らないことを確かめる
	local what="$1"; shift
	( baseline; eval "$*"; gl_verify_static >/dev/null 2>&1 ) && ng "検出しない: $what" || ok "検出する: $what"
}
try "固定と違うイメージ" 'GL_IMAGE_ID=sha256:other'
try "privileged" 'GL_PRIVILEGED=true'
try "余分な権限 (SYS_ADMIN)" 'GL_CAPADD=CAP_NET_ADMIN,CAP_SYS_ADMIN'
try "PID 名前空間の共有" 'GL_PIDMODE=host'
try "host ネットワーク" 'GL_NETMODE=host'
try "余分なマウント" 'GL_MOUNTS="$GL_MOUNTS;bind|/gluetun|/tmp/x|rw"'
try "sysctl が足りない (1024 未満のポートを使える)" 'GL_SYSCTLS=net.ipv6.conf.all.disable_ipv6=1,net.ipv6.conf.default.disable_ipv6=1'
for kv in FIREWALL_OUTBOUND_SUBNETS=0.0.0.0/0 FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT=off DNS_ADDRESS=1.1.1.1 DNS_KEEP_NAMESERVER=on PPROF_ENABLED=yes HTTP_CONTROL_SERVER_ADDRESS=:8000 FIREWALL_INPUT_PORTS=22; do
	try "必須の値と違う環境変数 ($kv)" "GL_ENV_TEXT=\"\$(printf '%s\n' \"\$GL_ENV_TEXT\" | grep -v '^${kv%%=*}=')
$kv\"; gl_env_lines >\"\$VPNSH_STATE_DIR/gluetun.env\""
done
try "あってはいけない環境変数 (HTTP_PROXY)" 'GL_ENV_TEXT="$GL_ENV_TEXT
HTTP_PROXY=http://x"; gl_env_lines >"$VPNSH_STATE_DIR/gluetun.env"'
try "作成時の記録と違う環境変数" 'echo EXTRA=1 >>"$VPNSH_STATE_DIR/gluetun.env"'
try "環境変数の重複" 'GL_DUP_ENV=FOO'
( baseline; GL_SYSCTLS=""; printf '%s\n' 'WIREGUARD_ENDPOINT_IP=1.2.3.4' >"$VPNSH_ENV_FILE"; gl_pending_changes 2>/dev/null | grep -qx sysctls ) &&
	ok "sysctl の足りない gluetun を「未適用の変更」として見つける" || ng "sysctl の未適用を見つけない"
unset -f vpnsh_docker

echo "== 4. ホスト鍵の行の検査"
K="AAAAC3NzaC1lZDI1NTE5AAAAIFk6l7nFAweysQeH6fmFfNAJ6fmh0d1zdbLfx+HwhOEq"
ssh_valid_keyscan_line "[a.example.com]:2222 ssh-ed25519 $K" "[a.example.com]:2222" && ok "正しい行は受け付ける" || ng "正しい行を拒否した"
bad=0
for l in "@cert-authority * ssh-ed25519 $K" "|1|abc=|def= ssh-ed25519 $K" "b.example.com ssh-ed25519 $K" "[a.example.com]:2222 ssh-ed25519 $K extra" "[a.example.com]:2222 ssh-dss $K" "[a.example.com]:2222 ssh-ed25519 \$(id)"; do
	ssh_valid_keyscan_line "$l" "[a.example.com]:2222" && { bad=$((bad + 1)); echo "    受け付けた: $l"; }
done
[ "$bad" -eq 0 ] && ok "@cert-authority・ハッシュ化・別のホスト・余分な項目・古い種類・不正な文字の行を拒否する" || ng "不正な行を $bad 個受け付けた"

echo "== 5. キーチェーンの権限の読み取り (偽の security の出力)"
fake_security() {
	# fake_security <decrypt の行> <applications の行> [アプリの行]
	cat >"$T/security" <<EOF
#!/bin/bash
cat <<'X'
keychain: "/x/login.keychain-db"
version: 256
class: "genp"
attributes:
    "acct"<blob>="other"
    "svce"<blob>="other-service"
access: 1 entries
    entry 0:
        authorizations (6): decrypt derive export_clear export_wrapped mac sign
        don't-require-password
        description: other
        applications: <null>
keychain: "/x/login.keychain-db"
version: 256
class: "genp"
attributes:
    "acct"<blob>="wireguard-private-key"
    "svce"<blob>="vpnshell"
access: 2 entries
    entry 0:
        authorizations (1): encrypt
        don't-require-password
        description: vpnshell
        applications: <null>
    entry 1:
        authorizations ($1
        don't-require-password
        description: vpnshell
        $2
$3
X
EOF
	chmod +x "$T/security"
}
VPNSH_SECURITY="$T/security"
fake_security "6): decrypt derive export_clear export_wrapped mac sign" "applications (0):" ""
[ "$(dr_kc_acl)" = "applications (0):" ] && ok "確認ありの項目を「アプリなし」と読む (他の項目の <null> に惑わされない)" || ng "読み取りが想定外: $(dr_kc_acl)"
fake_security "6): decrypt derive export_clear export_wrapped mac sign" "applications (1):" "            0: /usr/bin/security (OK)
                requirement: identifier \"com.apple.security\" and anchor apple"
[ "$(dr_kc_acl | tr '\n' '|')" = "applications (1):|app: /usr/bin/security (OK)|" ] && ok "「常に許可」で載ったアプリを読む" || ng "読み取りが想定外: $(dr_kc_acl)"
fake_security "1): any" "applications: <null>" ""
[ "$(dr_kc_acl)" = "applications: <null>" ] && ok "authorizations が any で全アプリ許可 (<null>) の項目を読む" || ng "any / <null> を読まない: $(dr_kc_acl)"
VPNSH_SECURITY="/usr/bin/security"

echo "== 6. 自動 down の判定"
v=""; for x in 10m 4h 1d 7d; do v="$v$(idle_seconds "$x")," ; done
[ "$v" = "600,14400,86400,604800," ] && ok "時間の指定 (10m、4h、1d、7d) を秒にする" || ng "時間の解釈が想定外: $v"
bad=0; for x in 9m 8d 0h 4 h 4x -1h "4h;id"; do idle_seconds "$x" >/dev/null && { bad=$((bad + 1)); echo "    受け付けた: $x"; }; done
[ "$bad" -eq 0 ] && ok "範囲外・不正な時間の指定を拒否する" || ng "不正な指定を $bad 個受け付けた"
idle_case() {
	# idle_case <説明> <idle-down の値> <シェルの一覧> <最後に使ってからの秒> <gluetun の起動からの秒> <down するか: yes|no>
	local what="$1" setting="$2" shells="$3" last_ago="$4" start_ago="$5" want="$6" got
	(
		printf 'VPNSH_IDLE_DOWN=%s\n' "$setting" >"$VPNSH_ENV_FILE"; VPNSH_ENV_LOADED=""
		now="$(date +%s)"
		if [ -n "$last_ago" ]; then echo $((now - last_ago)) >"$IDLE_LAST"; else rm -f "$IDLE_LAST"; fi
		fake_started="$(date -u -r $((now - start_ago)) +%Y-%m-%dT%H:%M:%S.000000000Z)"
		gl_inspect() { GL_STATUS=running; return 0; }
		gc_orphans() { :; }
		work_list() { [ -n "$shells" ] && printf '%s\n' "$shells"; return 0; }
		vpnsh_docker() { echo "$fake_started"; }
		cmd_down() { echo DOWN >"$T/down"; }
		rm -f "$T/down"
		cmd_idle_check
		[ -f "$T/down" ] && echo yes || echo no
	) >"$T/idle-out" 2>/dev/null
	got="$(tail -n 1 "$T/idle-out")"
	[ "$got" = "$want" ] && ok "$what" || ng "$what (down: ${got}、期待値 $want)"
}
idle_case "シェルが開いていれば破棄しない" 10m "abc 123 x alive" 3600 7200 no
idle_case "最後に使ってから指定の時間がたてば破棄する" 10m "" 700 7200 yes
idle_case "最後に使ってから指定の時間がたっていなければ破棄しない" 10m "" 100 7200 no
idle_case "一度も使っていなければ gluetun の起動から数える (たっていない)" 10m "" "" 100 no
idle_case "一度も使っていなければ gluetun の起動から数える (たった)" 10m "" "" 700 yes
idle_case "gluetun が最近起動し直していれば破棄しない" 10m "" 7200 100 no
idle_case "持ち主のいないシェルだけなら破棄する" 10m "abc 123 x orphan" 700 7200 yes
idle_case "無効 (off) なら破棄しない" off "" 99999 99999 no

echo "== 7. 表示の安全と使い方の誤り"
# macOS の bash 3.2 は UTF-8 のとき、"$x、" の「、」の先頭のバイトを変数名の一部として読む (set -u で異常終了する)。
# 変数の直後に日本語を書くときは ${x} にしなければならない
out="$(perl -ne 'next if /^\s*#/; while (/(?<!\\)\$([A-Za-z_][A-Za-z0-9_]*)[\x80-\xff]/g) { print "$ARGV:$.: \$$1\n" } close ARGV if eof' \
	"$ROOT"/bin/vpnsh "$ROOT"/lib/*.sh "$ROOT"/scripts/ssh-askpass "$ROOT"/scripts/update-pins "$ROOT"/tests/*.sh \
	"$ROOT"/docker/work/*.sh "$ROOT"/docker/work/bashrc)"
[ -z "$out" ] && ok "変数の直後に日本語が続く箇所 (bash 3.2 で壊れる) が無い" || ng "変数の直後に日本語が続く箇所がある (\${...} にすること):
$out"
out="$(printf 'a\033[8mhidden\rb 日本語…\n' | vpnsh_visible)"
[ "$out" = "a^[[8mhidden^Mb 日本語…" ] && ok "制御文字を ^[ の形で見せ、日本語はそのまま残す" || ng "表示が想定外: $out"
bad=0
for a in "up --recreat" "up -y --recreate" "down -y" "status x" "ps x" "gc x" "build --no-cache" "restart now" "install-shell x" "ssh stop x" "check --full --mtu" "doctor x" "idle-check x" "--bogus" "bogus"; do
	# shellcheck disable=SC2086  # 引数として分ける
	HOME="$T/home" "$ROOT/bin/vpnsh" $a >/dev/null 2>&1 </dev/null
	rc=$?
	[ "$rc" -eq 2 ] || { bad=$((bad + 1)); echo "    終了コード $rc: vpnsh $a"; }
done
[ "$bad" -eq 0 ] && ok "引数の誤り (打ち間違い・コマンドの後ろのオプション・余分な引数) は終了コード 2" || ng "終了コード 2 にならないものが $bad 個"

# 中継 (ssh_relay_start) は、この vpnsh の PID と開始時刻のラベルで work を探す。開始時刻を設定し忘れると、
# どの work も見つからず「中継につながりませんでした」になる (実際に起きた)
if grep -q '^	SESSION_START="\$start"$' "$ROOT/bin/vpnsh" && grep -q 'label=vpnsh.start=\$SESSION_START' "$ROOT/bin/vpnsh"; then
	ok "SSH の中継が work を探すための開始時刻を設定している"
else
	ng "SSH の中継が使う開始時刻 (SESSION_START) を設定していない"
fi

echo
echo "結果: OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ]
