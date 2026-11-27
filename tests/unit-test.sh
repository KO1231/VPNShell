#!/bin/bash
# shellcheck disable=SC2015  # ok / ng は常に 0 を返すので A && B || C で問題ない
# shellcheck disable=SC2030,SC2031,SC2034  # サブシェルで変数を差し替えて試す。GL_* などは lib が参照する
# shellcheck disable=SC2329  # 偽物の関数は、試す lib の関数から呼ばれる
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
# shellcheck source=lib/setup.sh
. "$ROOT/lib/setup.sh"
# shellcheck source=lib/lock.sh
. "$ROOT/lib/lock.sh"
# shellcheck source=lib/gluetun.sh
. "$ROOT/lib/gluetun.sh"
# shellcheck source=lib/ssh.sh
. "$ROOT/lib/ssh.sh"
# shellcheck source=lib/doctor.sh
. "$ROOT/lib/doctor.sh"
# shellcheck source=lib/idle.sh
. "$ROOT/lib/idle.sh"
# shellcheck source=lib/pins.sh
. "$ROOT/lib/pins.sh"

echo "== 1. PATH の安全化"
mkdir -p "$T/home/Projects/app/bin" "$T/home/Projects/app/node_modules/.bin" "$T/home/bin" "$T/other"
ln -s "$T/home/Projects/app/bin" "$T/home/linked-bin"
out="$(HOME="$T/home" PATH="$T/home/Projects/app/bin:./node_modules/.bin::$T/home/linked-bin:$T/nonexistent:$T/home/bin:$T/other:$T/home/Projects/app/node_modules/.bin" vpnsh_safe_path "$T/home/Projects")"
case ":$out:" in *"Projects"* | *":./"* | *"::"* | *"linked-bin"* | *nonexistent*) ng "残ってはいけないものが PATH に残った: $out" ;; *) ok "マウントできる場所の配下・相対パス・空・存在しない・シンボリックリンク経由のものを除く" ;; esac
case ":$out:" in *":$T/home/bin:$T/other:"*) ok "それ以外は順序を保って残す" ;; *) ng "残すべきものが消えた: $out" ;; esac
case ":$out:" in *":/usr/bin:/bin:/usr/sbin:/sbin:"*) ok "/usr/bin などを必ず含める" ;; *) ng "/usr/bin などが無い: $out" ;; esac
# vpnsh は PATH を安全にするまで、元の PATH からコマンドを探さない (.env の無い場所にコピーして試す)
mkdir -p "$T/home4/Projects/app/bin" "$T/bin4" "$T/repo4"
cp -R "$ROOT/bin" "$ROOT/lib" "$T/repo4/"
for c in dirname readlink env sed cat tr grep awk perl; do
	printf '#!/bin/sh\n/usr/bin/touch "%s/fake-called-%s"\nexec /usr/bin/%s "$@"\n' "$T" "$c" "$c" >"$T/home4/Projects/app/bin/$c"
	chmod +x "$T/home4/Projects/app/bin/$c"
done
ln -s "$T/repo4/bin/vpnsh" "$T/bin4/vpnsh"
out="$(HOME="$T/home4" PATH="$T/home4/Projects/app/bin:$PATH" "$T/bin4/vpnsh" --version 2>&1)"
called=""
for f in "$T"/fake-called-*; do [ -e "$f" ] && called="$called${f##*/} "; done
[ -z "$called" ] && [ "$out" = "vpnsh $(sed -n 's/^VPNSH_VERSION="\(.*\)"$/\1/p' "$ROOT/bin/vpnsh")" ] &&
	ok "PATH を安全にする前に、元の PATH (マウントできる場所の配下) のコマンドを使わない" ||
	ng "元の PATH の偽のコマンドが呼ばれた: ${called:-なし} (出力: $out)"
# CDPATH が export されていても、相対パス (bin/vpnsh) で起動したときにリポジトリの場所を取り違えない
mkdir -p "$T/cdpath5/bin"
out="$(cd "$T/repo4" && HOME="$T/home4" CDPATH="$T/cdpath5" bin/vpnsh --version 2>&1)"
[ "$out" = "vpnsh $(sed -n 's/^VPNSH_VERSION="\(.*\)"$/\1/p' "$ROOT/bin/vpnsh")" ] &&
	ok "CDPATH があっても、リポジトリの場所を取り違えない" || ng "CDPATH でリポジトリの場所を取り違えた: $out"
# 大文字・小文字を区別しない場合に備え、小文字の綴りのディレクトリを作って試す
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
# 大文字・小文字を区別しない場合に備え、小文字の library を作った別のホームでも試す
mkdir -p "$T/home3/library/x"
bad=0
for d in "$T/home/library" "$T/home/library/x" "$T/home/LIBRARY/x" "$T/home/LiBrArY/x"; do
	HOME="$T/home" mnt_root_ok "$d" >/dev/null 2>&1 && { bad=$((bad + 1)); echo "    受け付けた: $d"; }
done
for d in "$T/home3/library" "$T/home3/library/x"; do
	HOME="$T/home3" mnt_root_ok "$d" >/dev/null 2>&1 && { bad=$((bad + 1)); echo "    受け付けた: $d"; }
done
[ "$bad" -eq 0 ] && ok "綴りの大文字・小文字を変えても (~/library・~/LIBRARY など) ~/Library の中は使えない" || ng "綴りを変えた ~/Library を $bad 個受け付けた"

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

echo "== 3b. Mac の外部IPの読み取り (確認サービスの代わりにファイルを読む)"
printf 'fl=1\nip=203.0.113.7\nts=1\n' >"$T/ip-trace"
printf '203.0.113.8' >"$T/ip-plain"
printf '203.0.113.9\n' >"$T/ip-line"
printf '<html>\n<body>203.0.113.1</body>\n' >"$T/ip-html"
: >"$T/ip-empty"
# macip <URL...>  .env の VPNSH_IP_CHECK_URLS をその URL にして gl_mac_public_ip を呼び、結果と終了コードを出す
macip() { ( VPNSH_ENV_FILE="$T/env-macip"; printf 'VPNSH_IP_CHECK_URLS=%s\n' "$*" >"$VPNSH_ENV_FILE"; gl_mac_public_ip; echo " rc=$?" ); }
out="$(macip "file://$T/ip-trace")"
[ "$out" = "203.0.113.7 rc=0" ] && ok "Cloudflare の trace の形式 (ip= の行) を読む" || ng "trace の形式の結果が想定外: $out"
out="$(macip "file://$T/ip-plain")"
[ "$out" = "203.0.113.8 rc=0" ] && ok "IP だけの応答 (末尾に改行が無い) を読む" || ng "改行の無い応答の結果が想定外: $out"
out="$(macip "file://$T/ip-line")"
[ "$out" = "203.0.113.9 rc=0" ] && ok "IP だけの応答 (末尾に改行がある) を読む" || ng "改行のある応答の結果が想定外: $out"
out="$(macip "file://$T/ip-html" "file://$T/ip-empty" "file://$T/no-such-file" "file://$T/ip-line" "file://$T/ip-trace")"
[ "$out" = "203.0.113.9 rc=0" ] && ok "IP を読み取れない応答・空の応答・失敗は飛ばし、最初に読み取れたものを出す" || ng "読み取れない応答の扱いが想定外: $out"
out="$(macip "file://$T/ip-html" "file://$T/ip-empty" "file://$T/no-such-file")"
[ "$out" = " rc=1" ] && ok "どこからも読み取れなければ 1 を返す" || ng "読み取れないときの結果が想定外: $out"

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
# bash 3.2 では変数の直後の日本語が変数名の一部と読まれるので、${x} と書いていること
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

# 中継 (ssh_relay_start) が work を探すための開始時刻を設定していること
if grep -q '^	SESSION_START="\$start"$' "$ROOT/bin/vpnsh" && grep -q 'label=vpnsh.start=\$SESSION_START' "$ROOT/bin/vpnsh"; then
	ok "SSH の中継が work を探すための開始時刻を設定している"
else
	ng "SSH の中継が使う開始時刻 (SESSION_START) を設定していない"
fi

echo "== 8. .conf の取り込み (setup)"
KA="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
KB="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
# conf <ファイル名> <内容>  .conf を作る
conf() { printf '%s\n' "$2" >"$T/$1.conf"; }
# parse <ファイル名>  setup_parse_conf の結果を「秘密鍵|公開鍵|ホスト|ポート|アドレス」で出す (失敗なら「NG: 理由」)
parse() {
	(
		conf_resolve_ipv4() { case "$1" in vpn.example.com) echo 198.51.100.9 ;; esac; }
		( setup_parse_conf "$T/$1.conf" && printf '%s|%s|%s|%s|%s\n' "$SETUP_PRIV" "$SETUP_PUB" "$SETUP_HOST" "$SETUP_PORT" "$SETUP_ADDR" ) 2>"$T/parse.err" ||
			printf 'NG: %s\n' "$(grep 'エラー' "$T/parse.err" | head -n 1)"
	)
}
conf base "[Interface]
PrivateKey = $KA
Address = 10.5.0.2/32
DNS = 103.86.96.100

[Peer]
PublicKey = $KB
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.5:51820"
[ "$(parse base)" = "$KA|$KB|203.0.113.5|51820|10.5.0.2/32" ] && ok "NordVPN の .conf から秘密鍵・公開鍵・接続先・アドレスを読む" || ng "読み取りが想定外: $(parse base)"
conf case "[Interface]
privatekey=$KA   # コメント
address = fd00::2/128, 10.5.0.2/16
[ Peer ]
publickey=$KB
endpoint=203.0.113.5:443 ; コメント"
[ "$(parse case)" = "$KA|$KB|203.0.113.5|443|10.5.0.2/32" ] && ok "キーの大文字・小文字・空白・行末のコメント・セクション名の中の空白を問わず読み、IPv6 を除いた最初の IPv4 アドレスを /32 にそろえる" || ng "書き方の違いの扱いが想定外: $(parse case)"
conf noprefix "[Interface]
PrivateKey = $KA
Address = 10.5.0.2
[Peer]
PublicKey = $KB
Endpoint = 203.0.113.5:51820"
[ "$(parse noprefix)" = "$KA|$KB|203.0.113.5|51820|10.5.0.2/32" ] && ok "プレフィックスの無いアドレスも /32 にする" || ng "プレフィックスの無いアドレスの扱いが想定外: $(parse noprefix)"
conf host "[Interface]
PrivateKey = $KA
Address = 10.5.0.2/32
[Peer]
PublicKey = $KB
Endpoint = vpn.example.com:51820"
[ "$(parse host)" = "$KA|$KB|198.51.100.9|51820|10.5.0.2/32" ] && ok "接続先のホスト名は IPv4 アドレスに解決して使う" || ng "ホスト名の扱いが想定外: $(parse host)"
bad=0
check_bad() {
	# check_bad <説明> <.conf の内容> <エラーに含まれる文字列>
	conf bad "$2"
	local out; out="$(parse bad)"
	case "$out" in "NG: "*"$3"*) ;; *) bad=$((bad + 1)); echo "    $1 を拒否しない: $out" ;; esac
}
check_bad "PresharedKey 付き" "[Interface]
PrivateKey = $KA
Address = 10.5.0.2/32
[Peer]
PublicKey = $KB
PresharedKey = $KA
Endpoint = 203.0.113.5:51820" "PresharedKey"
check_bad "秘密鍵の形式の誤り" "[Interface]
PrivateKey = short=
Address = 10.5.0.2/32
[Peer]
PublicKey = $KB
Endpoint = 203.0.113.5:51820" "PrivateKey"
check_bad "公開鍵が [Interface] にある" "[Interface]
PrivateKey = $KA
PublicKey = $KB
Address = 10.5.0.2/32
[Peer]
Endpoint = 203.0.113.5:51820" "PublicKey"
check_bad "IPv4 のアドレスが無い" "[Interface]
PrivateKey = $KA
Address = fd00::2/128
[Peer]
PublicKey = $KB
Endpoint = 203.0.113.5:51820" "Address"
for ep in "203.0.113.5" "203.0.113.5:" "203.0.113.5:abc" "203.0.113.5:0" "203.0.113.5:70000"; do
	check_bad "Endpoint $ep" "[Interface]
PrivateKey = $KA
Address = 10.5.0.2/32
[Peer]
PublicKey = $KB
Endpoint = $ep" "Endpoint"
done
check_bad "解決できないホスト名" "[Interface]
PrivateKey = $KA
Address = 10.5.0.2/32
[Peer]
PublicKey = $KB
Endpoint = unknown.invalid:51820" "解決できません"
[ "$bad" -eq 0 ] && ok "PresharedKey 付き・鍵の形式の誤り・別のセクションの鍵・IPv4 のアドレスが無い・Endpoint の誤り (ポートが無い・範囲外)・解決できないホスト名を拒否する" || ng "拒否しない .conf が $bad 個"

echo "== 9. .env の値の検査"
GOOD_ENV="WIREGUARD_ENDPOINT_IP=203.0.113.5
WIREGUARD_ENDPOINT_PORT=51820
WIREGUARD_PUBLIC_KEY=$KB
WIREGUARD_ADDRESSES=10.5.0.2/32
WIREGUARD_MTU=1320
EXPECTED_PUBLIC_IP=198.51.100.7"
# envcheck <.env の内容> [関数]  その .env で require_env (または指定した関数) を呼び、「終了コード|エラー」を出す
envcheck() {
	(
		VPNSH_ENV_FILE="$T/env-check"; VPNSH_ENV_LOADED=""
		printf '%s\n' "$1" >"$VPNSH_ENV_FILE"
		( "${2:-require_env}" ) 2>"$T/env-check.err"
		printf '%s|%s\n' "$?" "$(grep 'エラー' "$T/env-check.err" | head -n 1)"
	)
}
# without <キー>  正しい .env からそのキーの行を除いたもの
without() { printf '%s\n' "$GOOD_ENV" | grep -v "^$1="; }
# with <キー> <値>  正しい .env のそのキーを置き換えたもの
with() { without "$1"; printf '%s=%s\n' "$1" "$2"; }
[ "$(envcheck "$GOOD_ENV")" = "0|" ] && [ "$(envcheck "$GOOD_ENV" require_expected_ip)" = "0|" ] && ok "正しい .env は検査に通る" || ng "正しい .env が検査に通らない: $(envcheck "$GOOD_ENV")"
out="$( (VPNSH_ENV_FILE="$T/no-such-env"; VPNSH_ENV_LOADED=""; require_env) 2>&1; echo "rc=$?")"
case "$out" in *"setup --import"*"rc=125") ok ".env が無ければ setup を案内して 125 で止まる" ;; *) ng ".env が無いときの結果が想定外: $out" ;; esac
bad=0
expect_bad() {
	# expect_bad <説明> <.env の内容> <エラーに含まれる文字列> [関数]
	local out; out="$(envcheck "$2" "${4:-require_env}")"
	case "$out" in "125|"*"$3"*) ;; *) bad=$((bad + 1)); echo "    $1 を拒否しない: $out" ;; esac
}
expect_bad "書式の誤り" "$GOOD_ENV
X = 1" "書式"
for k in WIREGUARD_ENDPOINT_IP WIREGUARD_ENDPOINT_PORT WIREGUARD_PUBLIC_KEY WIREGUARD_ADDRESSES WIREGUARD_MTU; do
	expect_bad "$k が無い" "$(without "$k")" "$k がありません"
done
expect_bad "接続先がホスト名" "$(with WIREGUARD_ENDPOINT_IP vpn.example.com)" "IPv4"
for v in 0 70000 abc; do expect_bad "ポート $v" "$(with WIREGUARD_ENDPOINT_PORT "$v")" "ポート番号"; done
expect_bad "公開鍵の形式の誤り" "$(with WIREGUARD_PUBLIC_KEY short=)" "PUBLIC_KEY"
for v in 10.5.0.2/24 10.5.0.2 10.5.0.2/32,10.5.0.3/32; do expect_bad "アドレス $v" "$(with WIREGUARD_ADDRESSES "$v")" "/32"; done
expect_bad "MTU が数値でない" "$(with WIREGUARD_MTU 1320x)" "MTU"
expect_bad "専用IP が無い" "$(without EXPECTED_PUBLIC_IP)" "EXPECTED_PUBLIC_IP" require_expected_ip
expect_bad "専用IP がホスト名" "$(with EXPECTED_PUBLIC_IP example.com)" "EXPECTED_PUBLIC_IP" require_expected_ip
[ "$bad" -eq 0 ] && ok "書式の誤り・必須の値が無い・接続先が IPv4 でない・ポートが範囲外・公開鍵の形式の誤り・/32 の1つでないアドレス・数値でない MTU・専用IP の誤りを、終了コード 125 で拒否する" || ng "拒否しない .env が $bad 個"

echo "== 10. シェルを起動してよいかの判定 (host_checks・prepare_gluetun)"
# gate <整合性> <未適用の変更> <遮断ルール>  各検査の結果 (0/1) を与えて host_checks を呼び、「終了コード|SESSION_NETNS」を出す
gate() {
	(
		r_verify="$1" r_pending="$2" r_fw="$3"
		gl_verify() { return "$r_verify"; }
		gl_pending_changes() { [ "$r_pending" -eq 0 ] && return 1; echo WIREGUARD_MTU; return 0; }
		gl_fw_check() { FW_NETNS="net:[4026532000]"; return "$r_fw"; }
		SESSION_NETNS=""
		host_checks 2>/dev/null
		printf '%s|%s\n' "$?" "$SESSION_NETNS"
	)
}
[ "$(gate 0 0 0)" = "0|net:[4026532000]" ] && ok "すべての検査に通れば、検査した gluetun の名前空間を work に渡す値にする" || ng "検査に通ったときの結果が想定外: $(gate 0 0 0)"
[ "$(gate 1 0 0)" = "1|" ] && [ "$(gate 0 1 0)" = "1|" ] && [ "$(gate 0 0 1)" = "1|" ] &&
	ok "整合性・未適用の変更・遮断ルールのどれかに落ちれば失敗し、名前空間を決めない" || ng "検査に落ちたときの結果が想定外: $(gate 1 0 0) $(gate 0 1 0) $(gate 0 0 1)"
# prep <最初の状態 (missing / unreachable / running / exited / created / paused)> [失敗させるもの...]  prepare_gluetun を呼び、「終了コード|呼ばれたもの」を出す
prep() {
	(
		state="$1"; shift
		fail=" $* "
		calls="$T/prep-calls"; : >"$calls"
		gl_inspect() {
			case "$state" in
				unreachable) return 2 ;;
				missing) return 1 ;;
			esac
			GL_STATUS="$state"; GL_ID=abc; return 0
		}
		lock_acquire() { echo lock >>"$calls"; }
		lock_release() { echo unlock >>"$calls"; }
		gl_create() { echo create >>"$calls"; case "$fail" in *" create "*) return 1 ;; esac; state=running; }
		gl_verify() { echo verify >>"$calls"; case "$fail" in *" verify "*) return 1 ;; esac; return 0; }
		vpnsh_docker() { echo "docker $*" >>"$calls"; state=running; }
		gl_wait_healthy() { echo wait >>"$calls"; case "$fail" in *" wait "*) return 1 ;; esac; return 0; }
		host_checks() { echo checks >>"$calls"; case "$fail" in *" checks "*) return 1 ;; esac; return 0; }
		( prepare_gluetun ) >/dev/null 2>&1
		printf '%s|%s\n' "$?" "$(tr '\n' ' ' <"$calls" | sed 's/ $//')"
	)
}
[ "$(prep running)" = "0|wait checks" ] && ok "動いている gluetun は、healthy を待ってから検査する" || ng "動いている gluetun の扱いが想定外: $(prep running)"
[ "$(prep missing)" = "0|lock create unlock wait checks" ] && ok "gluetun が無ければ、ロックの中で作ってから healthy を待って検査する" || ng "gluetun が無いときの扱いが想定外: $(prep missing)"
[ "$(prep missing create)" = "125|lock create unlock" ] && ok "作成に失敗すれば、ロックを解いて 125 で止まる" || ng "作成に失敗したときの扱いが想定外: $(prep missing create)"
[ "$(prep exited)" = "0|verify docker start vpnshell-gluetun wait checks" ] && ok "停止している gluetun は、作成時のとおりか確かめてから起動する" || ng "停止している gluetun の扱いが想定外: $(prep exited)"
[ "$(prep exited verify)" = "125|verify" ] && ok "停止している gluetun が作成時のとおりでなければ、起動せずに 125 で止まる" || ng "整合性に落ちた停止中の gluetun の扱いが想定外: $(prep exited verify)"
[ "$(prep created)" = "125|" ] && [ "$(prep paused)" = "125|" ] && [ "$(prep unreachable)" = "125|" ] &&
	ok "作成途中・一時停止中の gluetun や、Docker に接続できないときは 125 で止まる" || ng "作成途中・一時停止・接続できないときの扱いが想定外: $(prep created) / $(prep paused) / $(prep unreachable)"
[ "$(prep running wait)" = "125|wait" ] && [ "$(prep running checks)" = "125|wait checks" ] &&
	ok "healthy にならない・検査に落ちたときは 125 で止まる (シェルを起動しない)" || ng "healthy でない・検査に落ちたときの扱いが想定外: $(prep running wait) / $(prep running checks)"
# 起動の順序と、検査した名前空間を work に渡すこと (bin/vpnsh の cmd_session と run_work)
body="$(awk '/^cmd_session\(\) \{/,/^\}/' "$ROOT/bin/vpnsh")"
order="$(printf '%s\n' "$body" | grep -oE '^[[:space:]]+(require_env|require_expected_ip|prepare_gluetun|run_work)' | tr -d '\t ' | tr '\n' ' ')"
[ "$order" = "require_env require_expected_ip prepare_gluetun run_work " ] && ok "シェルは .env の検査と gluetun の準備・検査の後に起動する (cmd_session の順序)" || ng "cmd_session の順序が想定外: $order"
grep -q -- '-e "VPNSH_GLUETUN_NETNS=\$SESSION_NETNS"' "$ROOT/bin/vpnsh" && ok "work には検査した名前空間 (SESSION_NETNS) を渡す (中の起動前チェックが照合する)" || ng "work に検査した名前空間を渡していない"

echo "== 11. ロック"
LK_STATE="$T/lockstate"
ME="$$ $(vpnsh_proc_start $$)"
# lk_try <秒>  別のサブシェルでロックを取りにいき、その秒数のうちに取れたら「取れた」を出す (取れなければ待たせたまま)
lk_try() {
	rm -f "$T/lk-got"
	( VPNSH_STATE_DIR="$LK_STATE"; lock_acquire 2>"$T/lk-err" && echo got >"$T/lk-got"; LOCK_HELD="" ) >/dev/null &
	LK_BG=$!
	local i=0
	while [ ! -f "$T/lk-got" ] && [ "$i" -lt "$(($1 * 10))" ]; do sleep 0.1; i=$((i + 1)); done
	[ -f "$T/lk-got" ] && echo 取れた || echo 待っている
}
lk_owner() { cat "$LK_STATE/lock/owner" 2>/dev/null; }
lk_reset() { [ -n "${LK_BG:-}" ] && kill "$LK_BG" 2>/dev/null; wait "${LK_BG:-0}" 2>/dev/null; LK_BG=""; rm -f "$LK_STATE/lock/owner"; rmdir "$LK_STATE/lock" "$LK_STATE"/lock.stale.* 2>/dev/null; }
mkdir -p "$LK_STATE"
out="$( (VPNSH_STATE_DIR="$LK_STATE"; lock_acquire && printf '%s|%s|' "$LOCK_HELD" "$(lk_owner)"; lock_release; [ -d "$LK_STATE/lock" ] && echo 残った || echo 消えた) 2>&1)"
[ "$out" = "1|$ME|消えた" ] && ok "空いていれば取り、持ち主 (PID と開始時刻) を書き、解放すると消す" || ng "ロックの取得と解放が想定外: $out"
mkdir "$LK_STATE/lock"; echo "99999999 Mon_Jan__1_00:00:00_2001" >"$LK_STATE/lock/owner"
[ "$(lk_try 3)" = "取れた" ] && [ "$(lk_owner)" = "$ME" ] && grep -q '残したロックを解除しました' "$T/lk-err" && ok "持ち主のプロセスが無いロックは奪う (警告を出す)" || ng "持ち主のいないロックを奪わない ($(lk_owner))"
lk_reset
mkdir "$LK_STATE/lock"; echo "$$ Mon_Jan__1_00:00:00_2001" >"$LK_STATE/lock/owner"
[ "$(lk_try 3)" = "取れた" ] && ok "PID が同じでも開始時刻が違えば (PID の再利用) 奪う" || ng "開始時刻の違うロックを奪わない"
lk_reset
sleep 60 & holder=$!
mkdir "$LK_STATE/lock"; echo "$holder $(vpnsh_proc_start "$holder")" >"$LK_STATE/lock/owner"
hstart="$(vpnsh_proc_start "$holder")"
lk_try 2 >"$T/lk-r1"
r1="$(cat "$T/lk-r1")"
r1_owner="$(lk_owner)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
i=0; while [ ! -f "$T/lk-got" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
[ "$r1" = "待っている" ] && [ "$r1_owner" = "$holder $hstart" ] && grep -q '操作中です' "$T/lk-err" && [ -f "$T/lk-got" ] &&
	ok "持ち主が動いている間は奪わずに待ち、持ち主が終われば取る" || ng "動いている持ち主のロックの扱いが想定外 (${r1}、終了後: $([ -f "$T/lk-got" ] && echo 取れた || echo 取れない))"
lk_reset
mkdir "$LK_STATE/lock"
lk_try 2 >"$T/lk-r1"
r1="$(cat "$T/lk-r1")"
touch -t "$(date -v-1M +%Y%m%d%H%M.%S)" "$LK_STATE/lock"
i=0; while [ ! -f "$T/lk-got" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
[ "$r1" = "待っている" ] && [ -f "$T/lk-got" ] && ok "持ち主が書かれていないロックは、作られてから 10 秒たつまでは奪わず、たてば奪う" || ng "持ち主の無いロックの扱いが想定外 ($r1)"
lk_reset
mkdir "$LK_STATE/lock"; echo "1 other" >"$LK_STATE/lock/owner"
( VPNSH_STATE_DIR="$LK_STATE"; LOCK_DIR="$LK_STATE/lock"; LOCK_HELD=1; lock_release )
[ "$(lk_owner)" = "1 other" ] && ok "解放するのは自分が持ち主のロックだけ" || ng "他人のロックを解放した"
lk_reset
rm -f "$T/lk-r1" "$T/lk-err" "$T/lk-got"
rmdir "$LK_STATE" 2>/dev/null

echo "== 12. Mac の VPN が専用IPのサーバーに接続しているかの判定"
cat >"$T/fake-route" <<EOF
#!/bin/bash
echo "\$*" >>"$T/route-calls"
printf '   route to: %s\n  interface: %s\n' "\$3" "\$(cat "$T/route-iface")"
EOF
chmod +x "$T/fake-route"
printf '203.0.113.7\n' >"$T/ip-dedicated"
printf '198.51.100.1\n' >"$T/ip-other"
# hv <経路のインターフェース> <確認サービスの代わりのファイル> [.env に足す行]  gl_host_vpn_state の結果を出す
hv() {
	(
		VPNSH_ENV_FILE="$T/env-hv"; VPNSH_ENV_LOADED=""
		printf 'WIREGUARD_ENDPOINT_IP=192.0.2.10\nEXPECTED_PUBLIC_IP=203.0.113.7\nVPNSH_IP_CHECK_URLS=file://%s\n%s\n' "$2" "${3:-}" >"$VPNSH_ENV_FILE"
		GL_ROUTE="$T/fake-route"; echo "$1" >"$T/route-iface"; : >"$T/route-calls"
		gl_host_vpn_state
	)
}
[ "$(hv utun4 "$T/ip-dedicated")" = "same" ] && ok "接続先への経路が Mac の VPN (utun) を通り、Mac の外部IPが専用IPなら same" || ng "専用IPのときの判定が想定外: $(hv utun4 "$T/ip-dedicated")"
[ -z "$(hv utun4 "$T/ip-other")" ] && ok "Mac の VPN を通っても、外部IPが専用IPでなければ何も出さない" || ng "別のサーバーのときの判定が想定外: $(hv utun4 "$T/ip-other")"
[ "$(hv utun4 "$T/no-such-file")" = "unknown" ] && ok "Mac の VPN を通るが外部IPを確かめられなければ unknown" || ng "外部IPが分からないときの判定が想定外: $(hv utun4 "$T/no-such-file")"
[ -z "$(hv en0 "$T/ip-dedicated")" ] && ok "経路が Mac の VPN を通らなければ (en0)、外部IPが専用IPでも何も出さない" || ng "Mac の VPN を通らないときの判定が想定外: $(hv en0 "$T/ip-dedicated")"
( VPNSH_ENV_FILE="$T/env-hv2"; VPNSH_ENV_LOADED=""; printf 'EXPECTED_PUBLIC_IP=203.0.113.7\n' >"$VPNSH_ENV_FILE"; GL_ROUTE="$T/fake-route"; : >"$T/route-calls"; gl_host_vpn_state >"$T/hv-out"; [ ! -s "$T/hv-out" ] && [ ! -s "$T/route-calls" ] ) &&
	ok "接続先が .env に無ければ経路を調べず、何も出さない" || ng "接続先が無いときの判定が想定外"
out="$( (VPNSH_ENV_FILE="$T/env-hv"; VPNSH_ENV_LOADED=""; VPNSH_YES=1; gl_host_vpn_confirm; echo "rc=$?") 2>&1)"
case "$out" in *"警告"*"203.0.113.7"*"rc=0") ok "--yes のときは警告だけ出して続ける" ;; *) ng "--yes のときの結果が想定外: $out" ;; esac
out="$( (VPNSH_ENV_FILE="$T/env-hv"; VPNSH_ENV_LOADED=""; VPNSH_YES=""; gl_host_vpn_confirm </dev/null; echo "rc=$?") 2>&1)"
case "$out" in *"警告"*"rc=0") ok "端末が無いときは警告だけ出して続ける (確認で止めない)" ;; *) ng "端末が無いときの結果が想定外: $out" ;; esac
# wait_case <gl_host_vpn_state の結果> [confirm の結果]  healthy にならない gluetun で gl_wait_healthy を呼び、「終了コード|表示」を出す
wait_case() {
	(
		gl_inspect() { GL_STATUS=running; GL_HEALTH=starting; return 0; }
		vpnsh_docker() { echo "gluetun のログ"; }
		hv_state="$1"; hv_confirm="${2:-0}"
		gl_host_vpn_state() { [ -n "$hv_state" ] && echo "$hv_state"; return 0; }
		gl_host_vpn_confirm() { echo "確認" >&2; return "$hv_confirm"; }
		gl_wait_healthy 1 2>"$T/wait-err"
		printf '%s|%s\n' "$?" "$(tr '\n' ' ' <"$T/wait-err")"
	)
}
out="$(wait_case same)"
case "$out" in "1|確認 "*"待っています"*"healthy になりませんでした"*"専用IPのサーバーに接続しています"*"ほかに"*) ok "専用IPのときは確認してから待ち、healthy にならなければ専用IPを最初の原因として案内する" ;; *) ng "専用IPのときの案内が想定外: $out" ;; esac
out="$(wait_case same 1)"
case "$out" in "1|確認 ") ok "確認でやめれば、待たずに失敗する" ;; *) ng "確認でやめたときの結果が想定外: $out" ;; esac
out="$(wait_case unknown)"
case "$out" in *"確認"*) ng "unknown なのに確認した: $out" ;; "1|"*"healthy になりませんでした"*"接続していないかも確かめてください"*) ok "外部IPが分からないときは確認せずに待ち、失敗したら専用IPのサーバーへの接続も確かめるよう案内する" ;; *) ng "unknown のときの案内が想定外: $out" ;; esac
out="$(wait_case "")"
case "$out" in *"確認"* | *"専用IP"*) ng "Mac の VPN と関係ないのに専用IPの案内が出た: $out" ;; "1|"*"healthy になりませんでした"*"秘密鍵や .env の値の誤り"*) ok "Mac の VPN と関係なければ、いつもの案内だけを出す" ;; *) ng "いつもの案内が想定外: $out" ;; esac
out="$( (gl_inspect() { GL_STATUS=running; GL_HEALTH=healthy; return 0; }; gl_host_vpn_state() { echo called >>"$T/hv-called"; }; rm -f "$T/hv-called"; gl_wait_healthy 1 2>/dev/null; echo "rc=$?"; [ -f "$T/hv-called" ] && echo called) )"
[ "$out" = "rc=0" ] && ok "すでに healthy なら、Mac の外部IPを調べずに進む" || ng "healthy のときの結果が想定外: $out"

echo "== 13. install-shell (~/.zshrc の書き換え)"
MB="$(sed -n 's/^SHELL_MARK_BEGIN="\(.*\)"$/\1/p' "$ROOT/bin/vpnsh")"
ME="$(sed -n 's/^SHELL_MARK_END="\(.*\)"$/\1/p' "$ROOT/bin/vpnsh")"
IH="$T/ishome"; mkdir -p "$IH"
RC="$IH/.zshrc"
# ish [vpnsh のパス] [ホーム]  install-shell を --yes で実行する
ish() { env -u ZDOTDIR HOME="${2:-$IH}" "${1:-$ROOT/bin/vpnsh}" -y install-shell >/dev/null 2>"$T/ish.err" </dev/null; }
mode() { perl -e 'printf "%o", (stat shift)[2] & 07777' "$1"; }
nbak() { find "$IH" -maxdepth 1 -name '.zshrc.vpnsh-backup-*' | grep -c .; }
blocks() { grep -cxF "$MB" "$RC"; }
ish && [ "$(blocks)" = "1" ] && grep -qxF "$ME" "$RC" && [ "$(mode "$RC")" = "644" ] && zsh -n "$RC" && [ "$(nbak)" = "0" ] &&
	ok ".zshrc が無ければ、目印で囲んだ設定だけの .zshrc (権限 644) を作る" || ng "新しい .zshrc の結果が想定外: $(cat "$T/ish.err")"
cp "$RC" "$T/zshrc.prev"
ish && cmp -s "$RC" "$T/zshrc.prev" && grep -q '同じ設定' "$T/ish.err" && [ "$(nbak)" = "0" ] && ok "同じ設定が入っていれば書き換えない (バックアップも作らない)" || ng "2回目の実行で書き換えた"
printf 'alias ll="ls -l"' >"$RC"; chmod 600 "$RC"
ish
[ "$(head -n 1 "$RC")" = 'alias ll="ls -l"' ] && [ "$(sed -n 2p "$RC")" = "$MB" ] && [ "$(blocks)" = "1" ] && [ "$(mode "$RC")" = "600" ] &&
	[ "$(nbak)" = "1" ] && [ "$(cat "$(find "$IH" -maxdepth 1 -name '.zshrc.vpnsh-backup-*')")" = 'alias ll="ls -l"' ] &&
	ok "元の内容と権限を残して末尾に追記し (末尾に改行が無ければ足す)、元のファイルのバックアップを残す" || ng "既存の .zshrc への追記が想定外: $(cat "$RC")"
find "$IH" -maxdepth 1 -name '.zshrc.vpnsh-backup-*' -delete
printf '%s\n' 'export A=1' "$MB" 'old-vpnsh-line' "$ME" 'export B=2' >"$RC"
ish
[ "$(blocks)" = "1" ] && ! grep -q 'old-vpnsh-line' "$RC" && grep -qx 'export A=1' "$RC" && grep -qx 'export B=2' "$RC" &&
	ok "以前の vpnsh の設定は新しい内容に置き換え、目印の外は残す" || ng "以前の設定の置き換えが想定外: $(cat "$RC")"
find "$IH" -maxdepth 1 -name '.zshrc.vpnsh-backup-*' -delete
bad=0
for content in "x
$MB
y" "x
$ME" "$MB
a
$ME
$MB
b
$ME"; do
	printf '%s\n' "$content" >"$RC"; cp "$RC" "$T/zshrc.before"
	ish && { bad=$((bad + 1)); echo "    書き換えた: $(tr '\n' '|' <"$T/zshrc.before")"; }
	cmp -s "$RC" "$T/zshrc.before" || bad=$((bad + 1))
done
[ "$bad" -eq 0 ] && [ "$(nbak)" = "0" ] && ok "目印の組がそろっていない (終わりが無い・始まりが無い・2組ある) ときは、書き換えずに失敗する" || ng "目印のそろわない .zshrc を書き換えた ($bad 件)"
rm -f "$RC"; mkdir -p "$IH/dotfiles"; echo 'export C=3' >"$IH/dotfiles/zshrc"; ln -s "$IH/dotfiles/zshrc" "$RC"
ish
[ -L "$RC" ] && grep -qx 'export C=3' "$IH/dotfiles/zshrc" && grep -qxF "$MB" "$IH/dotfiles/zshrc" && ok ".zshrc がシンボリックリンクなら、リンクを残してリンク先を書き換える" || ng "シンボリックリンクの扱いが想定外"
W="$T/we\"ird \$x \`y\` \\z"
mkdir -p "$W" "$T/ishome2"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/completions" "$W/"
ish "$W/bin/vpnsh" "$T/ishome2"
out="$(HOME="$T/ishome2" zsh -f -c 'source ~/.zshrc; print -r -- "$path[1]|$fpath[1]"' 2>&1)"
[ "$out" = "$W/bin|$W/completions" ] && ok "リポジトリのパスに \" \$ \` \\ や空白があっても、そのままの PATH と fpath になる" || ng "特殊な文字を含むパスの扱いが想定外: $out"

echo "== 14. git の作成者情報"
mkdir -p "$T/fakegit"
cat >"$T/fakegit/git" <<EOF
#!/bin/bash
case "\$*" in
	"config --global user.name") cat "$T/git-name" 2>/dev/null ;;
	"config --global user.email") cat "$T/git-email" 2>/dev/null ;;
esac
EOF
chmod +x "$T/fakegit/git"
# gitid <名前> <メール>  その設定の git で git_identity_args を呼ぶ
gitid() {
	printf '%b' "$1" >"$T/git-name"; printf '%b' "$2" >"$T/git-email"
	( PATH="$T/fakegit:/usr/bin:/bin"; git_identity_args )
}
out="$(gitid 'Taro Yamada\n' 'taro@example.com\n')"
[ "$out" = "GIT_AUTHOR_NAME=Taro Yamada
GIT_COMMITTER_NAME=Taro Yamada
GIT_AUTHOR_EMAIL=taro@example.com
GIT_COMMITTER_EMAIL=taro@example.com" ] && ok "git config --global の名前とメールアドレスを、作成者とコミッターの環境変数にする" || ng "作成者情報が想定外: $out"
out="$(gitid 'Ta\033[31mro\nGIT_AUTHOR_EMAIL=evil@example.com\n' 'a@b\r\n')"
[ "$(printf '%s\n' "$out" | grep -c .)" = "4" ] && ! printf '%s' "$out" | LC_ALL=C grep -q '[[:cntrl:]]' && printf '%s\n' "$out" | grep -qx 'GIT_AUTHOR_EMAIL=a@b' &&
	printf '%s\n' "$out" | grep -qx 'GIT_AUTHOR_NAME=Ta\[31mroGIT_AUTHOR_EMAIL=evil@example.com' &&
	ok "改行や制御文字は取り除き、別の環境変数を注入できない (1つの値は1行のまま)" || ng "制御文字の扱いが想定外: $(printf '%s' "$out" | vpnsh_visible)"
out="$(gitid "$(printf 'x%.0s' {1..300})" '')"
[ "$(printf '%s\n' "$out" | grep -c .)" = "2" ] && [ "$(printf '%s\n' "$out" | head -n 1)" = "GIT_AUTHOR_NAME=$(printf 'x%.0s' {1..200})" ] &&
	ok "長すぎる値は 200 文字で切り、空の値は渡さない" || ng "長さ・空の値の扱いが想定外: $(printf '%s\n' "$out" | cut -c1-40)"
out="$(gitid '' '')"
[ -z "$out" ] && ok "設定が無ければ何も渡さない" || ng "設定が無いのに渡した: $out"

echo "== 15. キーチェーンへの保存と取り出し (偽の security)"
cat >"$T/fake-sec" <<EOF
#!/bin/bash
echo "\$*" >>"$T/sec-args"
item="$T/sec-item"
case "\$1" in
	find-generic-password)
		[ -n "\${FAKE_SEC_FIND_ERR:-}" ] && { echo "\$FAKE_SEC_FIND_ERR" >&2; exit "\${FAKE_SEC_FIND_RC:-1}"; }
		[ -f "\$item" ] || { echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44; }
		case " \$* " in *" -w "*) cat "\$item" ;; esac
		exit 0 ;;
	delete-generic-password)
		[ -n "\${FAKE_SEC_DELETE_FAIL:-}" ] && exit 1
		rm -f "\$item"; exit 0 ;;
	-i)
		in="\$(cat)"; printf '%s\n' "\$in" >>"$T/sec-stdin"
		[ -n "\${FAKE_SEC_ADD_OUT:-}" ] && { echo "\$FAKE_SEC_ADD_OUT"; exit 0; }
		[ -n "\${FAKE_SEC_ADD_NOWRITE:-}" ] && exit 0
		printf '%s' "\$in" | sed -n 's/.* -w "\([^"]*\)".*/\1/p' | tr -d '\n' >"\$item"
		exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/fake-sec"
# kc <関数> [値] [偽の security に渡す設定...]  キーチェーンの関数を呼び、「終了コード|出力」を出す (エラーは $T/kc.err)
kc() {
	local fn="$1" val="${2:-}"; shift 2
	(
		VPNSH_SECURITY="$T/fake-sec"
		for kv in "$@"; do export "${kv?}"; done
		( "$fn" ${val:+"$val"} ) 2>"$T/kc.err"
		printf '%s|' "$?"
	)
}
kc_reset() { rm -f "$T/sec-item" "$T/sec-args" "$T/sec-stdin"; }
kc_reset
out="$(kc kc_set "$KA")"
[ "$out" = "0|" ] && [ "$(cat "$T/sec-item")" = "$KA" ] && grep -q 'add-generic-password .*-T "" -w "'"$KA"'"' "$T/sec-stdin" && ! grep -qF "$KA" "$T/sec-args" &&
	ok "秘密鍵は security -i の標準入力で渡し (コマンドの引数に出さない)、信頼済みアプリなし (-T \"\") で登録する" || ng "登録のしかたが想定外: $out"
out="$(kc kc_set "$KB")"
[ "$out" = "0|" ] && [ "$(cat "$T/sec-item")" = "$KB" ] && grep -q '^delete-generic-password' "$T/sec-args" && ok "既存の項目があれば、削除してから登録し直す" || ng "既存の項目の扱いが想定外: $out"
kc_reset
out="$(kc kc_set "short=")"
[ "$out" != "0|" ] && ! grep -q '^-i' "$T/sec-args" 2>/dev/null && ok "形式の正しくない鍵は、キーチェーンに触れずに拒否する" || ng "形式の正しくない鍵を登録しようとした: $out"
out="$(kc kc_set "$KA" "FAKE_SEC_ADD_OUT=security: SecKeychainItemCreateFromContent (<default>): Error")"
[ "$out" = "1|" ] && grep -q 'SecKeychainItemCreateFromContent' "$T/kc.err" && ok "security -i が 0 で終わっても、出力にエラーがあれば失敗にし、その出力を表示する" || ng "登録のエラーを見逃した: $out"
kc_reset
out="$(kc kc_set "$KA" FAKE_SEC_ADD_NOWRITE=1)"
[ "$out" = "1|" ] && grep -q '項目が見つかりません' "$T/kc.err" && ok "登録の後に項目が見つからなければ失敗にする" || ng "登録できていないのを見逃した: $out"
kc_reset
printf '%s' "$KA" >"$T/sec-item"
out="$(kc kc_set "$KB" FAKE_SEC_DELETE_FAIL=1)"
[ "$out" = "1|" ] && [ "$(cat "$T/sec-item")" = "$KA" ] && ! grep -q '^-i' "$T/sec-args" && ok "既存の項目を削除できなければ、登録せずに失敗する" || ng "削除できないときの扱いが想定外: $out"
kc_reset
printf '%s' "$KA" >"$T/sec-item"
out="$( (VPNSH_SECURITY="$T/fake-sec"; kc_get) 2>/dev/null)"
[ "$out" = "$KA" ] && ok "取り出した鍵をそのまま出す" || ng "取り出した鍵が想定外: $out"
printf 'short' >"$T/sec-item"
out="$(kc kc_get "")"
[ "$out" = "1|" ] && grep -q '形式が正しくありません' "$T/kc.err" && ok "取り出した値の形式が正しくなければ使わない" || ng "形式の正しくない値を使った: $out"
kc_reset
out="$(kc kc_get "")"
[ "$out" = "1|" ] && grep -q 'setup --import' "$T/kc.err" && ok "項目が無ければ setup を案内する" || ng "項目が無いときの案内が想定外: $(cat "$T/kc.err")"
out="$(kc kc_get "" "FAKE_SEC_FIND_ERR=security: SecKeychainSearchCopyNext: User interaction is not allowed." FAKE_SEC_FIND_RC=36)"
[ "$out" = "1|" ] && grep -q 'ロックされているか' "$T/kc.err" && ok "確認ダイアログを出せないときは、その理由を案内する" || ng "ダイアログを出せないときの案内が想定外: $(cat "$T/kc.err")"
out="$(kc kc_get "" "FAKE_SEC_FIND_ERR=security: The user name or passphrase you entered is not correct." FAKE_SEC_FIND_RC=51)"
[ "$out" = "1|" ] && grep -q '拒否された可能性' "$T/kc.err" && ok "拒否などで取り出せなければ失敗にする" || ng "拒否されたときの扱いが想定外: $(cat "$T/kc.err")"
kc_reset

echo "== 16. gluetun の作成に失敗したときの後片付け"
# create_case <失敗させるもの (なし / create / foreign / verify / start / swap)>  gl_create を呼び、「終了コード|docker rm の対象|gluetun.id」を出す
create_case() {
	(
		how="$1"
		VPNSH_STATE_DIR="$T/gcstate"; mkdir -p "$VPNSH_STATE_DIR"
		rm -f "$T/gc-calls" "$VPNSH_STATE_DIR/gluetun.env"
		echo "old-id" >"$VPNSH_STATE_DIR/gluetun.id"
		gl_render_post_rules() { return 0; }
		gl_expected_env() { echo "A=1"; }
		kc_get() { echo "$KA"; }
		gl_inspect() { GL_ID="$(cat "$T/gc-id")"; GL_STATUS="$(cat "$T/gc-status")"; return 0; }
		gl_verify_static() { [ "$how" != "verify" ]; }
		vpnsh_compose_t() {
			case "$*" in
				*"--no-start"*)
					[ "$how" = "create" ] && return 1
					if [ "$how" = "foreign" ]; then echo "other-id" >"$T/gc-id"; echo running >"$T/gc-status"; else echo "new-id" >"$T/gc-id"; echo created >"$T/gc-status"; fi ;;
				*)
					[ "$how" = "start" ] && return 1
					echo running >"$T/gc-status"
					[ "$how" = "swap" ] && echo "swapped-id" >"$T/gc-id" ;;
			esac
			return 0
		}
		vpnsh_docker() { echo "$*" >>"$T/gc-calls"; }
		gl_create 2>/dev/null
		printf '%s|%s|%s\n' "$?" "$(sed -n 's/^rm -f //p' "$T/gc-calls" 2>/dev/null | tr '\n' ' ')" "$(cat "$VPNSH_STATE_DIR/gluetun.id" 2>/dev/null)"
	)
}
[ "$(create_case none)" = "0||new-id" ] && [ "$(cat "$T/gcstate/gluetun.env")" = "A=1" ] && ok "作成 → 検査 → 記録 → 起動の順に進み、作ったコンテナの ID と環境変数を記録する" || ng "作成の結果が想定外: $(create_case none)"
[ "$(create_case verify)" = "1|new-id |" ] && [ ! -e "$T/gcstate/gluetun.env" ] && ok "検査に通らなければ、自分が作ったコンテナだけを破棄し、記録も消す" || ng "検査に落ちたときの後片付けが想定外: $(create_case verify)"
[ "$(create_case start)" = "1|new-id |" ] && ok "起動に失敗しても、自分が作ったコンテナを破棄する" || ng "起動に失敗したときの後片付けが想定外: $(create_case start)"
[ "$(create_case foreign)" = "1||old-id" ] && ok "作成の直後に別の vpnsh のコンテナが見えたら、それを壊さず、記録も消さない" || ng "別の vpnsh のコンテナの扱いが想定外: $(create_case foreign)"
[ "$(create_case create)" = "1||old-id" ] && ok "作成そのものに失敗したら、何も破棄しない" || ng "作成に失敗したときの扱いが想定外: $(create_case create)"
[ "$(create_case swap)" = "1|vpnshell-gluetun |new-id" ] && ok "起動したコンテナが検査したものと違えば、破棄して失敗にする" || ng "検査の後にすり替わったときの扱いが想定外: $(create_case swap)"
rm -f "$T/gc-id" "$T/gc-status" "$T/gc-calls" "$T/gcstate/gluetun.id" "$T/gcstate/gluetun.env"

echo "== 17. update-pins のインデックスの判定"
D="sha256:$(printf 'a%.0s' {1..64})"
# idx <ダイジェスト> <アーキテクチャ...>  imagetools inspect の Manifest の形の JSON
idx() {
	local d="$1" a list=""; shift
	for a in "$@"; do list="$list${list:+,}{\"platform\":{\"architecture\":\"$a\",\"os\":\"linux\"}}"; done
	printf '{"digest":"%s","manifests":[%s]}' "$d" "$list"
}
# pins <JSON>  pins_index_digest の「終了コード|出力」
pins() { local out; out="$(printf '%s' "$1" | pins_index_digest)"; printf '%s|%s\n' "$?" "$out"; }
[ "$(pins "$(idx "$D" amd64 arm64 arm)")" = "0|$D" ] && ok "arm64 と amd64 を含むインデックスなら、そのダイジェストを出す" || ng "インデックスの判定が想定外: $(pins "$(idx "$D" amd64 arm64)")"
[ "$(pins "$(idx "$D" amd64)")" = "2|" ] && [ "$(pins "$(idx "$D" arm64)")" = "2|" ] && [ "$(pins '{"digest":"'"$D"'"}')" = "2|" ] &&
	ok "arm64 か amd64 が無い (単一のアーキテクチャのイメージを含む) ときは使わない" || ng "アーキテクチャの足りないインデックスを受け付けた"
[ "$(pins "$(idx "sha256:abc" amd64 arm64)")" = "0|" ] && [ "$(pins "$(idx "md5:$(printf 'a%.0s' {1..64})" amd64 arm64)")" = "0|" ] &&
	ok "ダイジェストの形が正しくなければ何も出さない" || ng "正しくないダイジェストを出した"
[ "$(pins 'not json')" = "1|" ] && [ "$(pins '')" = "1|" ] && ok "JSON として読めなければ失敗にする" || ng "読めない JSON の扱いが想定外"

echo "== 18. doctor の点検"
# dr <関数> [引数...]  点検をサブシェルで動かし、表示を $T/dr.out に書いて「NG=件数 警告=件数」を出す
dr() { ( DR_NG=0; DR_WARN=0; "$@" >"$T/dr.out" 2>&1; echo "NG=$DR_NG 警告=$DR_WARN" ); }
drhas() { sed 's/\x1b\[[0-9;]*m//g' "$T/dr.out" | grep -qF -- "$1"; }
SHELL_MARK_BEGIN="# >>> vpnsh >>> (テスト)"
DRH="$T/drhome"; mkdir -p "$DRH"; printf '%s\n' "$SHELL_MARK_BEGIN" >"$DRH/.zshrc"
# drcfg <.env の内容 (- なら無し)> <.env の権限> <state/ の権限>
drcfg() {
	(
		HOME="$DRH"; VPNSH_ENV_FILE="$T/dr-env"; VPNSH_ENV_LOADED=""; VPNSH_STATE_DIR="$T/dr-state"
		mkdir -p "$VPNSH_STATE_DIR" && chmod "$3" "$VPNSH_STATE_DIR"
		rm -f "$VPNSH_ENV_FILE"; [ "$1" = "-" ] || { printf '%s\n' "$1" >"$VPNSH_ENV_FILE"; chmod "$2" "$VPNSH_ENV_FILE"; }
		zshrc_path() { printf '%s' "$HOME/.zshrc"; }
		dr dr_config
	)
}
[ "$(drcfg "$GOOD_ENV" 600 700)" = "NG=0 警告=0" ] && drhas "専用IP 198.51.100.7" && ok "設定: 正しい .env・権限・~/.zshrc の設定なら問題なし" || ng "設定の点検が想定外: $(drcfg "$GOOD_ENV" 600 700) $(cat "$T/dr.out")"
[ "$(drcfg - 600 700)" = "NG=1 警告=0" ] && drhas ".env がありません" && ok "設定: .env が無ければ NG" || ng ".env が無いときの点検が想定外"
[ "$(drcfg "$(with WIREGUARD_ENDPOINT_PORT 0)" 600 700)" = "NG=1 警告=0" ] && drhas "ポート番号" && ok "設定: .env の値が不正なら NG にして理由を出す (起動時と同じ検査)" || ng "不正な .env の点検が想定外"
[ "$(drcfg "$GOOD_ENV" 644 700)" = "NG=0 警告=1" ] && drhas "権限が 644" && [ "$(drcfg "$GOOD_ENV" 600 755)" = "NG=0 警告=1" ] && drhas "state/ の権限が 755" &&
	ok "設定: .env や state/ を他のユーザーが読める権限なら警告" || ng "権限の点検が想定外"
printf 'export X=1\n' >"$DRH/.zshrc"
[ "$( VPNSH_ORIG_PATH=/usr/bin:/bin drcfg "$GOOD_ENV" 600 700)" = "NG=0 警告=1" ] && drhas "PATH にありません" && ok "設定: install-shell の設定が無く PATH にも無ければ警告" || ng "PATH の点検が想定外"
printf '#!/bin/sh\necho "    \\"/nonexistent/login.keychain-db\\""\n' >"$T/fake-defkc"; chmod +x "$T/fake-defkc"
drkc() { ( HOME="$DRH"; kc_ok="$1"; kc_exists() { return "$kc_ok"; }; dr_kc_acl() { echo "applications (0):"; }; VPNSH_SECURITY="$T/fake-defkc"; VPNSH_STATE_DIR="$T/dr-state"; dr dr_keychain ); }
[ "$(drkc 1)" = "NG=1 警告=0" ] && drhas "秘密鍵がありません" && ok "秘密鍵: キーチェーンに無ければ NG" || ng "キーチェーンに無いときの点検が想定外"
mkdir -p "$DRH/Downloads/sub" "$DRH/Desktop"
printf '[Interface]\nAddress = 10.5.0.2/32\n' >"$DRH/Downloads/other.conf"
[ "$(drkc 0)" = "NG=0 警告=0" ] && drhas "見当たらない" && ok "秘密鍵: キーチェーンにあり、秘密鍵を含む .conf が残っていなければ問題なし" || ng "秘密鍵の点検が想定外: $(cat "$T/dr.out")"
printf '[Interface]\n  PrivateKey = %s\n' "$KA" >"$DRH/Downloads/sub/nord.conf"
[ "$(drkc 0)" = "NG=0 警告=1" ] && drhas "sub/nord.conf" && ! drhas "other.conf" && ok "秘密鍵: ダウンロードなどに秘密鍵を含む .conf が残っていれば警告 (含まないものは出さない)" || ng ".conf の残りの点検が想定外: $(cat "$T/dr.out")"
# drgl <gl_inspect の結果> <状態> <health> <未適用の変更 (0/1)> <整合性 (0/1)>
drgl() {
	(
		r_in="$1" st="$2" hl="$3" pend="$4" ver="$5"
		gl_inspect() { GL_STATUS="$st"; GL_HEALTH="$hl"; return "$r_in"; }
		gl_pending_changes() { [ "$pend" = 1 ] && { echo WIREGUARD_MTU; return 0; }; return 1; }
		gl_verify() { return "$ver"; }
		gl_fw_check() { return 0; }
		dr dr_gluetun
	)
}
[ "$(drgl 0 running healthy 0 0)" = "NG=0 警告=0" ] && drhas "期待値どおり" && [ "$(drgl 1 "" "" 0 0)" = "NG=0 警告=0" ] &&
	ok "gluetun: healthy で整合性も期待値どおり、または gluetun が無ければ問題なし" || ng "gluetun の点検が想定外"
[ "$(drgl 2 "" "" 0 0)" = "NG=1 警告=0" ] && [ "$(drgl 0 running healthy 0 1)" = "NG=1 警告=0" ] && drhas "検査に通りません" &&
	[ "$(drgl 0 running unhealthy 0 0)" = "NG=1 警告=0" ] && drhas "確かめていません" &&
	ok "gluetun: Docker に接続できない・整合性に落ちる・healthy でなければ NG (healthy でなければ整合性は確かめない)" || ng "gluetun の NG の点検が想定外"
[ "$(drgl 0 exited "" 0 0)" = "NG=0 警告=1" ] && [ "$(drgl 0 running starting 0 0)" = "NG=0 警告=1" ] && [ "$(drgl 0 running healthy 1 0)" = "NG=0 警告=1" ] && drhas "適用されていません" &&
	ok "gluetun: 停止中・起動中・未適用の変更があれば警告" || ng "gluetun の警告の点検が想定外"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; D40="$(date -u -v-40d +%Y-%m-%dT%H:%M:%SZ)"; D200="$(date -u -v-200d +%Y-%m-%dT%H:%M:%SZ)"
# drimg <work イメージのラベル> <work の作成日時> <gluetun の作成日時 (空なら未取得)>
drimg() {
	(
		lbl="$1" wc="$2" gc="$3"
		work_build_hash() { echo hash1; }
		vpnsh_docker() {
			case "$*" in
				*build-hash*) [ -n "$lbl" ] && echo "$lbl" ;;
				*"{{.Created}} vpnshell-work:local") echo "$wc" ;;
				*"{{.Created}} qmcgaw/gluetun"*) [ -n "$gc" ] && echo "$gc" || return 1 ;;
			esac
		}
		dr dr_images
	)
}
[ "$(drimg hash1 "$NOW" "$NOW")" = "NG=0 警告=0" ] && ok "イメージ: work が最新で、固定した gluetun も新しければ問題なし" || ng "イメージの点検が想定外: $(cat "$T/dr.out")"
[ "$(drimg "" "" "$NOW")" = "NG=1 警告=0" ] && ok "イメージ: work イメージが無ければ NG" || ng "work イメージが無いときの点検が想定外"
[ "$(drimg hash0 "$NOW" "$NOW")" = "NG=0 警告=1" ] && [ "$(drimg hash1 "$D40" "$NOW")" = "NG=0 警告=1" ] && drhas "40 日前" && [ "$(drimg hash1 "$NOW" "$D200")" = "NG=0 警告=1" ] && drhas "200 日前" &&
	ok "イメージ: work が docker/work より古い・30 日より前のビルド・固定した gluetun が 120 日より前の版なら警告" || ng "古いイメージの点検が想定外"
[ "$(drimg hash1 "$NOW" "")" = "NG=0 警告=0" ] && drhas "まだ取得されていません" && ok "イメージ: 固定した gluetun が未取得なら知らせるだけ" || ng "未取得の gluetun の点検が想定外"
drsh() { ( drsh_list="$1"; work_list() { printf '%s\n' "$drsh_list" | sed '/^$/d'; }; dr dr_shells ); }
[ "$(drsh "a 1 s alive")" = "NG=0 警告=0" ] && [ "$(drsh "a 1 s alive
b 2 s orphan")" = "NG=0 警告=1" ] && [ "$(drsh "c - - unknown")" = "NG=0 警告=1" ] &&
	ok "シェル: 持ち主のいないシェルや、vpnsh 以外で起動された work があれば警告" || ng "シェルの点検が想定外"
(
	HOME="$T/drssh"; mkdir -p "$HOME/.ssh"
	VPNSH_STATE_DIR="$T/drssh-state"; mkdir -p "$VPNSH_STATE_DIR"
	SSH_HOSTS_FILE="$VPNSH_STATE_DIR/hosts"; SSH_KNOWN_HOSTS="$VPNSH_STATE_DIR/known_hosts"; SSH_GEN_DIR="$VPNSH_STATE_DIR/ssh"
	SSH_AGENT_DIR="$VPNSH_STATE_DIR/agent"; SSH_AGENT_SOCK="$SSH_AGENT_DIR/agent.sock"
	ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_a"
	cfg() { printf 'Host srv\n  HostName %s\n  User u\n  IdentityFile ~/.ssh/id_a\n%s\n' "$1" "${2:-}" >"$HOME/.ssh/config"; }
	cfg s.example.com
	export VPNSH_TEST_SSH_CONFIG="$HOME/.ssh/config"
	ssh_hosts_put srv s.example.com 22 u "$HOME/.ssh/id_a"
	ssh_kh_replace s.example.com 22 "s.example.com $(cut -d' ' -f1-2 "$HOME/.ssh/id_a.pub")"
	ssh_render_fingerprints
	[ "$(dr dr_ssh)" = "NG=0 警告=0" ] && drhas "接続先 1 件に問題はない" && echo "OK|SSH: 鍵・ホスト鍵・~/.ssh/config・指紋の対応表がそろっていれば問題なし" || echo "NG|SSH の点検が想定外: $(tr '\n' ' ' <"$T/dr.out")"
	chmod 644 "$HOME/.ssh/id_a"
	[ "$(dr dr_ssh)" = "NG=0 警告=1" ] && drhas "秘密鍵の権限が 644" && echo "OK|SSH: 秘密鍵を他のユーザーが読める権限なら警告" || echo "NG|秘密鍵の権限の点検が想定外"
	chmod 600 "$HOME/.ssh/id_a"; mv "$HOME/.ssh/id_a.pub" "$T/id_a.pub.saved"
	r="$(dr dr_ssh)"; case "$r" in "NG=1 "*) drhas "公開鍵がありません" && echo "OK|SSH: 公開鍵が無ければ NG" || echo "NG|公開鍵が無いときの表示が想定外" ;; *) echo "NG|公開鍵が無いときの点検が想定外 ($r)" ;; esac
	mv "$T/id_a.pub.saved" "$HOME/.ssh/id_a.pub"; mv "$SSH_KNOWN_HOSTS" "$T/kh.saved"
	[ "$(dr dr_ssh)" = "NG=0 警告=1" ] && drhas "ホスト鍵が保存されていません" && echo "OK|SSH: ホスト鍵が保存されていなければ警告" || echo "NG|ホスト鍵が無いときの点検が想定外"
	mv "$T/kh.saved" "$SSH_KNOWN_HOSTS"
	cfg other.example.com
	[ "$(dr dr_ssh)" = "NG=0 警告=1" ] && drhas "登録した内容が違います" && echo "OK|SSH: ~/.ssh/config が登録した内容と違えば警告" || echo "NG|~/.ssh/config のずれの点検が想定外"
	cfg other.example.com "Match exec \"true\""
	[ "$(dr dr_ssh)" = "NG=0 警告=0" ] && drhas "Match exec" && echo "OK|SSH: ~/.ssh/config に Match exec があれば、ずれは確かめない (コマンドを実行させない)" || echo "NG|Match exec の扱いが想定外"
	cfg s.example.com
	sleep 0 & dead=$!; wait "$dead"; mkdir -p "$SSH_GEN_DIR/s.$dead"
	printf '%s\tdeny(relay:type=17)\tx\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$VPNSH_STATE_DIR/ssh-audit.log"
	[ "$(dr dr_ssh)" = "NG=0 警告=2" ] && drhas "設定が 1 個残っています" && drhas "拒否した SSH の要求が 1 件" && echo "OK|SSH: 終わったシェルの設定の残りと、直近24時間に拒否した要求があれば警告" || echo "NG|残りと拒否の点検が想定外: $(tr '\n' ' ' <"$T/dr.out")"
) >"$T/drssh-result" 2>/dev/null
while IFS='|' read -r st msg; do
	if [ "$st" = "OK" ]; then ok "$msg"; else ng "$msg"; fi
done <"$T/drssh-result"
# cmd_doctor の流れ (各点検は偽物)
# shellcheck disable=SC2119  # 引数なしで呼ぶ
out="$( (DR_NG=0; DR_WARN=0; VPNSH_VERSION=0.0.0; dr_docker() { return 1; }; dr_config() { echo C; }; dr_keychain() { echo K; }; dr_gluetun() { echo G; }; dr_images() { echo I; }; dr_shells() { echo S; }; dr_ssh() { echo X; }; cmd_doctor; echo "rc=$?") 2>&1 | tr '\n' ' ')"
case "$out" in *" C K X "*"NG 0 件"*"rc=0 ") ok "doctor: Docker に接続できなければ、Docker を使う点検を飛ばして続ける" ;; *) ng "Docker に接続できないときの doctor の流れが想定外: $out" ;; esac
# shellcheck disable=SC2119
out="$( (DR_NG=0; DR_WARN=0; VPNSH_VERSION=0.0.0; dr_docker() { return 0; }; dr_config() { DR_NG=$((DR_NG + 1)); }; dr_keychain() { :; }; dr_gluetun() { :; }; dr_images() { :; }; dr_shells() { :; }; dr_ssh() { :; }; NO_COLOR=1 cmd_doctor; echo "rc=$?") 2>&1 | tr '\n' ' ')"
case "$out" in *"NG 1 件"*"rc=1 ") ok "doctor: NG があれば終了コード 1" ;; *) ng "NG があるときの doctor の終了コードが想定外: $out" ;; esac

echo
echo "結果: OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ]
