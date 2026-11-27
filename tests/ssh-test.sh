#!/bin/bash
# shellcheck disable=SC2015  # ok / ng は常に 0 を返すので A && B || C で問題ない
# shellcheck disable=SC2030,SC2031,SC2088  # 1b はサブシェルで HOME を差し替える。"~/" は表示用の文字列として比べる
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/vpnsh-sshtest.XXXXXX")"
T="$(cd "$T" && pwd -P)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$*"; }
ng() { FAIL=$((FAIL + 1)); printf '  \033[31mNG\033[0m   %s\n' "$*"; }
# skip <説明>  省略したことを表示する (VPNSH_CI=1 なら NG にする)
skip() { if [ "${VPNSH_CI:-}" = 1 ]; then ng "省略した (CI では省略しない): $*"; else printf '  (%s)\n' "$*"; fi; }

# ---------------------------------------------------------------------------
echo "== 1. 確認ダイアログの判定"
mkdir -p "$T/state/ssh"
FP="SHA256:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
FP2="SHA256:ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponmlkj"
{
	echo "$FP serverA (deploy@a.example.com:22)"
	echo "$FP2 shared1 (admin@s1.example.com:22)"
	echo "$FP2 shared2 (deploy@s2.example.com:22)"
} >"$T/state/ssh/fingerprints"
cat >"$T/fake-osascript" <<'EOF'
#!/bin/bash
# 偽の osascript: 渡された引数を記録し、FAKE_RESULT を出力する
printf '%s\n' "$2" >"$FAKE_ARGS"
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
printf '%s' "${FAKE_RESULT:-}"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/fake-osascript"
PROMPT_TEXT="Allow use of key mykey? Key fingerprint $FP. public key authentication request for user \"deploy\" to listed host"
askpass() {
	# askpass <期待する終了コード> <説明> [環境変数...]   (PROMPT_TEXT を ssh-agent からの文言として渡す)
	local want="$1" what="$2"; shift 2
	rm -f "$T/args"
	env -i PATH=/usr/bin:/bin VPNSH_STATE_DIR="$T/state" VPNSH_ASKPASS_TEST=1 \
		VPNSH_ASKPASS_TEST_OSASCRIPT="$T/fake-osascript" VPNSH_ASKPASS_TEST_TIMEOUT=2 \
		FAKE_ARGS="$T/args" SSH_ASKPASS_PROMPT=confirm "$@" \
		"$ROOT/scripts/ssh-askpass" "$PROMPT_TEXT" >/dev/null 2>&1
	local rc=$?
	[ "$rc" -eq "$want" ] && ok "$what (exit $rc)" || ng "$what (exit ${rc}、期待値 $want)"
}
askpass 0 "許可ボタン → 許可" FAKE_RESULT="button=許可;gaveup=false"
askpass 1 "拒否ボタン → 拒否" FAKE_RESULT="error=-128"
askpass 1 "時間切れ → 拒否" FAKE_RESULT="button=;gaveup=true"
askpass 1 "許可ボタンでも時間切れの印があれば拒否" FAKE_RESULT="button=許可;gaveup=true"
askpass 1 "何も出力せず exit 0 → 拒否" FAKE_RESULT=""
askpass 1 "想定外の出力 → 拒否" FAKE_RESULT="button returned:許可, gave up:false"
askpass 1 "osascript が失敗 → 拒否" FAKE_RESULT="button=許可;gaveup=false" FAKE_RC=1
askpass 1 "応答しない osascript は打ち切って拒否" FAKE_RESULT="button=許可;gaveup=false" FAKE_SLEEP=30
askpass 1 "確認以外の問い合わせ (パスフレーズなど) → 拒否" SSH_ASKPASS_PROMPT=passphrase FAKE_RESULT="button=許可;gaveup=false"
askpass 0 "（ダイアログの文言の確認用）" FAKE_RESULT="button=許可;gaveup=false"
grep -q "serverA (deploy@a.example.com:22)" "$T/args" 2>/dev/null && ok "ダイアログに接続先の名前を出す" || ng "ダイアログに接続先の名前が出ない"
PROMPT_TEXT="Allow use of key evil SHA256:$(printf 'x%.0s' {1..43})? Key fingerprint $FP. public key authentication request for user \"deploy\" to listed host"
askpass 1 "文言に指紋が2つあれば (鍵のコメントで偽装) ダイアログを出さずに拒否" FAKE_RESULT="button=許可;gaveup=false"
[ ! -f "$T/args" ] && ok "そのときダイアログは出ない" || ng "偽装された文言でダイアログが出た"
PROMPT_TEXT="Allow use of key unknown? Key fingerprint SHA256:QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ. public key authentication request for user \"deploy\" to listed host"
askpass 1 "vpnsh で登録していない鍵の指紋なら、ダイアログを出さずに拒否" FAKE_RESULT="button=許可;gaveup=false"
[ ! -f "$T/args" ] && ok "そのときダイアログは出ない" || ng "登録していない鍵でダイアログが出た"
PROMPT_TEXT="Allow use of key shared? Key fingerprint $FP2. public key authentication request for user \"deploy\" to listed host"
askpass 0 "（共有した鍵の文言の確認用）" FAKE_RESULT="button=許可;gaveup=false"
grep -q "shared2 (deploy@s2.example.com:22)" "$T/args" 2>/dev/null && ! grep -q "shared1" "$T/args" 2>/dev/null &&
	ok "同じ鍵を複数の接続先で使うときは、ユーザー名で絞った接続先を出す" || ng "共有した鍵の表示が想定外: $(head -n 3 "$T/args" 2>/dev/null)"
PROMPT_TEXT="Allow use of key shared? Key fingerprint $FP2. public key authentication request for user \"nobody\" to listed host"
askpass 0 "（絞れないときの確認用）" FAKE_RESULT="button=許可;gaveup=false"
grep -q "shared1.*shared2" "$T/args" 2>/dev/null && ok "絞れないときは候補をすべて出す" || ng "候補がすべて出ない"
n="$(grep -c . "$T/state/ssh-audit.log" 2>/dev/null)"
[ "$n" -ge 8 ] && ok "結果を記録する ($n 件)" || ng "記録が足りない (${n:-0} 件)"
grep -q $'\tallow\t' "$T/state/ssh-audit.log" && grep -q 'deny(timeout)' "$T/state/ssh-audit.log" && ok "許可・時間切れが区別して記録される" || ng "記録の内容が想定外"

# ---------------------------------------------------------------------------
echo "== 1b. ~/.ssh/config からの読み取り (ssh -G) と state/hosts の書き込み"
(
	export HOME="$T/home"
	mkdir -p "$HOME/.ssh"
	VPNSH_ROOT="$ROOT"; VPNSH_STATE_DIR="$T/state1b"; mkdir -p "$VPNSH_STATE_DIR"
	# shellcheck source=lib/common.sh
	. "$ROOT/lib/common.sh"
	# shellcheck source=lib/fwcheck.sh
	. "$ROOT/lib/fwcheck.sh"
	# shellcheck source=lib/ssh.sh
	. "$ROOT/lib/ssh.sh"
	ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_alpha"
	ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"
	# macOS の ssh はシステム全体の設定 (/etc/ssh/ssh_config) も読むので、それを含めた条件で試す
	cat >"$HOME/.ssh/config" <<'CFG'
Include /etc/ssh/ssh_config
Host alpha
  HostName alpha.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_alpha
Host nokey
  HostName nokey.example.com
Host jump
  HostName j.example.com
  ProxyJump bastion
Host *.wild
  User x
CFG
	export VPNSH_TEST_SSH_CONFIG="$HOME/.ssh/config"
	ssh_resolve alpha && [ "$SR_HOST $SR_PORT $SR_USER $SR_IDS $SR_IDS_DEFAULT $SR_INCONFIG" = "alpha.example.com 2222 deploy $HOME/.ssh/id_alpha 0 1" ] &&
		ok "Host の HostName / Port / User / IdentityFile を読める" || ng "読み取りが想定外: $SR_HOST $SR_PORT $SR_USER $SR_IDS $SR_IDS_DEFAULT $SR_INCONFIG"
	ssh_resolve nokey && [ "$SR_IDS_DEFAULT" = "1" ] && ok "IdentityFile が無い Host は「既定の候補」と分かる" || ng "既定の候補の判定が想定外"
	ssh_resolve jump && [ -n "$SR_PROXY" ] && ok "踏み台 (ProxyJump) を検出する" || ng "踏み台を検出しない"
	ssh_resolve notinconfig && [ "$SR_INCONFIG" = "0" ] && ok "~/.ssh/config に無い Host を検出する (システム全体の設定を読む条件でも)" || ng "~/.ssh/config に無い Host を検出しない"
	ssh_resolve Alpha2 && [ "$SR_INCONFIG" = "0" ] && ok "打ち間違えた Host 名を検出する" || ng "打ち間違えた Host 名を検出しない"
	ssh_resolve alpha && [ "$SR_INCONFIG" = "1" ] && ok "書いてある Host は「ある」と判定する" || ng "書いてある Host を「ない」と判定した"
	ssh_hosts_put sp a.example.com 22 u "$HOME/.ssh/my key" 2>/dev/null && ng "空白を含む鍵のパスを受け付けた" || ok "空白を含む鍵のパスは拒否する"
	ssh_hosts_put hs a.example.com 22 u "$HOME/.ssh/id#vpn" 2>/dev/null && ng "# を含む鍵のパスを受け付けた" || ok "# を含む鍵のパスは拒否する"
	ssh_hosts_put alpha alpha.example.com 2222 deploy "$HOME/.ssh/id_alpha"
	ssh_hosts_put beta b.example.com 22 u "$HOME/.ssh/id_ed25519"
	ssh_hosts_put alpha alpha2.example.com 22 deploy "$HOME/.ssh/id_alpha"
	out="$(ssh_hosts)"
	[ "$(printf '%s\n' "$out" | grep -c .)" = "2" ] && printf '%s\n' "$out" | grep -q "^alpha alpha2.example.com 22 deploy $HOME/.ssh/id_alpha$" &&
		ok "同じ名前は置き換え、~ で書いた鍵は読むときに展開する" || ng "state/hosts の内容が想定外: $out"
	grep -q '~/.ssh/id_alpha' "$VPNSH_STATE_DIR/hosts" && ok "state/hosts には ~ のまま書く (Mac ごとの HOME の違いに強い)" || ng "state/hosts に絶対パスが書かれた"
	[ "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$VPNSH_STATE_DIR/hosts")" = "600" ] && ok "state/hosts の権限は 600" || ng "state/hosts の権限が想定外"
	ssh_hosts_del beta
	[ "$(ssh_hosts | grep -c .)" = "1" ] && ok "名前を指定して取り除ける" || ng "取り除けない"
	echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts" || FAIL=$((FAIL + 1))

# ---------------------------------------------------------------------------
echo "== 1c. 専用 ssh-agent の起動と停止"
(
	VPNSH_ROOT="$T/agentroot"; VPNSH_STATE_DIR="$T/state1c"; mkdir -p "$VPNSH_ROOT/scripts" "$VPNSH_STATE_DIR"
	# shellcheck source=lib/common.sh
	. "$ROOT/lib/common.sh"
	# shellcheck source=lib/ssh.sh
	. "$ROOT/lib/ssh.sh"
	# 偽の確認ダイアログ: 呼ばれたときの環境変数を記録して許可する
	cat >"$VPNSH_ROOT/scripts/ssh-askpass" <<EOF
#!/bin/bash
env >"$T/askpass-env-1c"
exit 0
EOF
	chmod +x "$VPNSH_ROOT/scripts/ssh-askpass"
	mkdir -p "$SSH_AGENT_DIR" && echo "古い記録" >"$SSH_AGENT_DIR/added"
	export VPNSH_TEST_LEAK=leak-value
	ssh_agent_start
	pid="$(cat "$SSH_AGENT_DIR/pid" 2>/dev/null)"
	agent_args="$(ps -o args= -p "${pid:-0}" 2>/dev/null)"
	[ -S "$SSH_AGENT_SOCK" ] && case "$agent_args" in *ssh-agent*"-a $SSH_AGENT_SOCK"*"-P none"*) true ;; *) false ;; esac &&
		ok "専用のソケットで、PKCS#11 などの読み込みを禁止 (-P none) して起動し、PID を記録する" || ng "起動のしかたが想定外: ${agent_args:-起動していない}"
	[ ! -s "$SSH_AGENT_DIR/added" ] && ok "起動すると、読み込んだ鍵の記録を空にする" || ng "鍵の記録が残った"
	ssh_agent_start
	[ "$(cat "$SSH_AGENT_DIR/pid" 2>/dev/null)" = "$pid" ] && ok "動いていれば起動し直さない" || ng "動いているのに起動し直した"
	ssh-keygen -q -t ed25519 -N '' -C vpnsh-1c -f "$T/id_1c"
	SSH_AUTH_SOCK="$SSH_AGENT_SOCK" /usr/bin/ssh-add -q -c "$T/id_1c" 2>/dev/null
	echo msg >"$T/msg-1c"
	SSH_AUTH_SOCK="$SSH_AGENT_SOCK" ssh-keygen -Y sign -n vpnsh-test -f "$T/id_1c.pub" "$T/msg-1c" >/dev/null 2>&1
	if [ ! -f "$T/askpass-env-1c" ]; then
		ng "確認付きの鍵を使っても確認ダイアログが呼ばれない"
	elif grep -q VPNSH_TEST_LEAK "$T/askpass-env-1c"; then
		ng "vpnsh の環境変数が確認ダイアログ (ssh-agent) に渡った"
	else
		grep -qxF "VPNSH_STATE_DIR=$VPNSH_STATE_DIR" "$T/askpass-env-1c" && grep -qx 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$T/askpass-env-1c" &&
			ok "確認ダイアログには決まった環境変数だけを渡す (vpnsh の環境を持ち込まない)" || ng "確認ダイアログの環境変数が想定外: $(cut -d= -f1 "$T/askpass-env-1c" | tr '\n' ' ')"
	fi
	ssh_agent_stop
	i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
	! kill -0 "$pid" 2>/dev/null && [ ! -e "$SSH_AGENT_SOCK" ] && [ ! -e "$SSH_AGENT_DIR/pid" ] && [ ! -e "$SSH_AGENT_DIR/added" ] &&
		ok "止めると、プロセスを終わらせてソケットと記録を消す" || ng "止めたあとにプロセスか記録が残った"
	sleep 30 & other=$!
	echo "$other" >"$SSH_AGENT_DIR/pid"
	ssh_agent_stop
	kill -0 "$other" 2>/dev/null && ok "記録の PID が vpnsh の ssh-agent でなければ、そのプロセスは終わらせない" || ng "vpnsh の ssh-agent ではないプロセスを終わらせた"
	kill "$other" 2>/dev/null
	echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts" || FAIL=$((FAIL + 1))

# ---------------------------------------------------------------------------
echo "== 1d. trust-host のホスト鍵の比較と保存"
(
	VPNSH_ROOT="$ROOT"; VPNSH_STATE_DIR="$T/state1d"; mkdir -p "$VPNSH_STATE_DIR"
	# shellcheck source=lib/common.sh
	. "$ROOT/lib/common.sh"
	# shellcheck source=lib/ssh.sh
	. "$ROOT/lib/ssh.sh"
	for n in 1 2 3; do ssh-keygen -q -t ed25519 -N '' -f "$T/hk$n"; done
	ssh-keygen -q -t ecdsa -N '' -f "$T/hk4"
	# khline <known_hosts の名前> <鍵>  ssh-keyscan が出す形の行
	khline() { printf '%s %s\n' "$1" "$(cut -d' ' -f1-2 "$2.pub")"; }
	KH="[h.example.com]:2222"
	A="$(khline "$KH" "$T/hk1")"; B="$(khline "$KH" "$T/hk4")"; C="$(khline "$KH" "$T/hk2")"
	O="$(khline other.example.com "$T/hk3")"
	[ "$(ssh_kh_compare h.example.com 2222 "$A")" = "new" ] && ok "保存済みのホスト鍵が無ければ new" || ng "保存前の比較が想定外"
	ssh_kh_replace other.example.com 22 "$O"
	ssh_kh_replace h.example.com 2222 "$A
$B"
	[ "$(ssh_kh_compare h.example.com 2222 "$B
$A")" = "same" ] && ok "順序が違っても同じ鍵の組なら same (保存し直さない)" || ng "同じ鍵の組の比較が想定外"
	[ "$(ssh_kh_compare h.example.com 2222 "$A")" = "partial" ] && [ "$(ssh_kh_compare h.example.com 2222 "$A
$B
$C")" = "partial" ] && ok "一部だけが一致 (種類が減った・増えた) なら partial" || ng "一部が一致するときの比較が想定外"
	[ "$(ssh_kh_compare h.example.com 2222 "$C")" = "different" ] && ok "1つも一致しなければ different (MITM の警告を出す側)" || ng "一致しないときの比較が想定外"
	[ "$(ssh_kh_compare h.example.com 22 "$(khline h.example.com "$T/hk1")")" = "new" ] && ok "ポートが違えば別の接続先として扱う" || ng "ポートの違う接続先を同じものとして扱った"
	ssh_kh_replace h.example.com 2222 "$C"
	[ "$(grep -c '^\[h\.example\.com\]:2222 ' "$SSH_KNOWN_HOSTS")" = "1" ] && grep -qxF "$C" "$SSH_KNOWN_HOSTS" && grep -qxF "$O" "$SSH_KNOWN_HOSTS" &&
		ok "保存し直すと、その接続先の古い鍵を消して新しい鍵だけにし、ほかの接続先は残す" || ng "保存し直した結果が想定外: $(cat "$SSH_KNOWN_HOSTS")"
	[ "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$SSH_KNOWN_HOSTS")" = "600" ] && [ ! -e "$SSH_KNOWN_HOSTS.old" ] &&
		ok "known_hosts の権限は 600 で、ssh-keygen -R の控え (.old) を残さない" || ng "known_hosts の権限か控えが想定外"
	echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts" || FAIL=$((FAIL + 1))

# ---------------------------------------------------------------------------
echo "== 1e. シェル専用の SSH の設定の片付け"
(
	VPNSH_ROOT="$ROOT"; VPNSH_STATE_DIR="$T/state1e"; mkdir -p "$VPNSH_STATE_DIR"
	# shellcheck source=lib/common.sh
	. "$ROOT/lib/common.sh"
	# shellcheck source=lib/ssh.sh
	. "$ROOT/lib/ssh.sh"
	# mksess <ディレクトリ>  シェル専用の設定と同じ形のディレクトリを作る
	mksess() { mkdir -p "$1/keys" && : >"$1/config" && : >"$1/known_hosts" && : >"$1/keys/srv.pub"; }
	sleep 0 & dead=$!; wait "$dead"
	mksess "$SSH_GEN_DIR/s.$dead"; mksess "$SSH_GEN_DIR/s.$$"
	ssh_session_gc
	[ ! -e "$SSH_GEN_DIR/s.$dead" ] && [ -f "$SSH_GEN_DIR/s.$$/config" ] && ok "持ち主の vpnsh が終わったシェルの設定だけを消す" || ng "片付けの結果が想定外: $(ls "$SSH_GEN_DIR")"
	mksess "$T/outside1e/s.$dead"
	ssh_session_remove "$T/outside1e/s.$dead"
	[ -f "$T/outside1e/s.$dead/config" ] && ok "vpnsh のディレクトリの外は消さない" || ng "vpnsh のディレクトリの外を消した"
	mksess "$SSH_GEN_DIR/s.$dead"; echo keep >"$SSH_GEN_DIR/s.$dead/keys/id_secret"
	ssh_session_remove "$SSH_GEN_DIR/s.$dead"
	[ -f "$SSH_GEN_DIR/s.$dead/keys/id_secret" ] && [ ! -e "$SSH_GEN_DIR/s.$dead/config" ] && [ ! -e "$SSH_GEN_DIR/s.$dead/keys/srv.pub" ] &&
		ok "消すのは vpnsh が作るファイル (config・known_hosts・*.pub) だけ (ほかのファイルは残す)" || ng "知らないファイルの扱いが想定外"
	ssh_session_remove "$SSH_GEN_DIR/s.$$"
	[ ! -e "$SSH_GEN_DIR/s.$$" ] && ok "自分のシェルの設定は終了時に消せる" || ng "自分のシェルの設定が残った"
	echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts" || FAIL=$((FAIL + 1))

# ---------------------------------------------------------------------------
echo "== 2. 通しの動作 (偽の gluetun + テスト用 sshd)"
VPNSH_ROOT="$ROOT"
VPNSH_PROJECT="vpnshell-sshtest"
VPNSH_GLUETUN_NAME="vpnshell-sshtest-gluetun"
VPNSH_STATE_DIR="$T/state"
VPNSH_ENV_FILE="$T/env"
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
vpnsh_clean_env
export VPNSH_UID VPNSH_GID
VPNSH_UID="$(id -u)"; VPNSH_GID="$(id -g)"
kc_get() { openssl rand -base64 32 | tr -d '\n'; }

SSHD_IMAGE="vpnshell-test-sshd:local"
AGENT_SOCK="$T/a.sock"
AGENT_PID=""
RELAY_PID=""
cleanup() {
	[ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null
	[ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
	vpnsh_docker rm -f vpnshell-sshtest-sshd vpnshell-sshtest-sshd2 >/dev/null 2>&1
	vpnsh_compose down -v --remove-orphans >/dev/null 2>&1
	find "$T" -depth -mindepth 1 \( -type f -o -type s -o -type l \) -delete 2>/dev/null
	find "$T" -depth -mindepth 1 -type d -empty -delete 2>/dev/null
	rmdir "$T" 2>/dev/null
}
trap cleanup EXIT

if [ "${VPNSH_TEST_SKIP_DOCKER:-}" = 1 ]; then
	echo "  (VPNSH_TEST_SKIP_DOCKER=1 なので省略)"
	echo; echo "結果: OK=$PASS NG=$FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
if ! vpnsh_docker image inspect vpnshell-work:local >/dev/null 2>&1; then
	skip "work イメージが無いので省略。bin/vpnsh build の後に再実行してください"
	echo; echo "結果: OK=$PASS NG=$FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
if ! vpnsh_docker image inspect "$SSHD_IMAGE" >/dev/null 2>&1; then
	mkdir -p "$T/sshd-image"
	cat >"$T/sshd-image/Dockerfile" <<'EOF'
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
RUN apk add --no-cache openssh-server && adduser -D -s /bin/sh tester && passwd -u tester >/dev/null 2>&1 || true
EOF
	vpnsh_timeout 300 docker --context "$VPNSH_CONTEXT" build -q -t "$SSHD_IMAGE" "$T/sshd-image" >/dev/null || { echo "テスト用 sshd のイメージを作れません" >&2; exit 1; }
fi

cat >"$T/env" <<EOF
WIREGUARD_ENDPOINT_IP=192.0.2.10
WIREGUARD_ENDPOINT_PORT=51820
WIREGUARD_PUBLIC_KEY=$(openssl rand -base64 32)
WIREGUARD_ADDRESSES=10.5.0.2/32
WIREGUARD_MTU=1320
VPNSH_GLUETUN_NAME=$VPNSH_GLUETUN_NAME
VPNSH_STATE_DIR=$T/state
EOF
# shellcheck disable=SC2119  # 引数なし (初回作成) で呼ぶ
gl_create >/dev/null 2>"$T/create.err" || { cat "$T/create.err" >&2; echo "gluetun を作成できません" >&2; exit 1; }

# テスト用の鍵 (使い捨て) と sshd 2台 (同じネットワーク名前空間の 127.0.0.1:2222 と :2223、ホスト鍵は別)
ssh-keygen -q -t ed25519 -N '' -C vpnsh-test-key -f "$T/id_test"
for n in 1 2; do
	port=$((2221 + n)); name="vpnshell-sshtest-sshd"; [ "$n" -eq 2 ] && name="vpnshell-sshtest-sshd2"
	vpnsh_docker run -d --name "$name" --network "container:$VPNSH_GLUETUN_NAME" \
		-e PUB="$(cat "$T/id_test.pub")" -e PORT="$port" --entrypoint sh "$SSHD_IMAGE" -c '
			ssh-keygen -A >/dev/null 2>&1
			mkdir -p /home/tester/.ssh && echo "$PUB" > /home/tester/.ssh/authorized_keys
			chown -R tester /home/tester/.ssh && chmod 700 /home/tester/.ssh && chmod 600 /home/tester/.ssh/authorized_keys
			exec /usr/sbin/sshd -D -e -o ListenAddress=127.0.0.1 -o Port=$PORT -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no' >/dev/null
done
sleep 1
for port in 2222 2223; do
	vpnsh_docker run --rm --network "container:$VPNSH_GLUETUN_NAME" --entrypoint ssh-keyscan vpnshell-work:local -t ed25519 -p "$port" 127.0.0.1 2>/dev/null
done >"$T/state/known_hosts.all"
[ "$(grep -c . "$T/state/known_hosts.all")" -eq 2 ] || { echo "テスト用 sshd のホスト鍵を取得できません" >&2; cat "$T/state/known_hosts.all" >&2; exit 1; }
grep '^\[127.0.0.1\]:2222 ' "$T/state/known_hosts.all" >"$T/state/known_hosts"
cat >"$T/state/hosts" <<EOF
# テスト用
srv1 127.0.0.1 2222 tester $T/id_test
srv2 127.0.0.1 2223 tester $T/id_test
EOF

# 偽の確認ダイアログ (MODE ファイルの内容で許可 / 拒否を切り替える) で専用 ssh-agent を起動する
echo allow >"$T/askpass-mode"
cat >"$T/fake-askpass" <<EOF
#!/bin/bash
echo "\$(date +%s) \$*" >> "$T/askpass-calls"
mode="\$(cat "$T/askpass-mode")"
# slow: 人がダイアログを読んでから拒否したときのように、時間をかけて拒否する
[ "\$mode" = "slow" ] && sleep 2
[ "\$mode" = "allow" ]
EOF
chmod +x "$T/fake-askpass"
out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin SSH_ASKPASS="$T/fake-askpass" SSH_ASKPASS_REQUIRE=force /usr/bin/ssh-agent -s -a "$AGENT_SOCK" -P none)"
AGENT_PID="$(printf '%s\n' "$out" | sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p')"
SSH_AGENT_SOCK="$AGENT_SOCK"
SSH_AGENT_DIR="$T/agentdir"; mkdir -p "$SSH_AGENT_DIR"; : >"$SSH_AGENT_DIR/added"
FP_TEST="$(ssh-keygen -lf "$T/id_test.pub" | awk '{print $2}')"
SSH_AUTH_SOCK="$AGENT_SOCK" /usr/bin/ssh-add -q -c -t 10m -H "$T/state/known_hosts" -h "tester@[127.0.0.1]:2222" "$T/id_test" 2>/dev/null &&
	ok "鍵を確認付き・期限付き・接続先 (srv1) に縛って登録" || ng "鍵を登録できない"
printf '%s\t%s\t%s\n' "$FP_TEST" "$(date +%s)" "srv1" >>"$SSH_AGENT_DIR/added"

# シェル専用の設定を生成 (known_hosts には srv2 のホスト鍵も入れる。縛りは agent 側にだけある)
cp "$T/state/known_hosts.all" "$T/state/known_hosts.container"
SSH_KNOWN_HOSTS="$T/state/known_hosts.container"
SESSION="$(ssh_session_dir $$)"
ssh_render_session "$SESSION" >/dev/null 2>&1 && ok "シェル専用の ssh_config を生成" || ng "ssh_config を生成できない"
grep -q "IdentityFile /etc/vpnsh/ssh/keys/srv1$" "$SESSION/config" && [ -f "$SESSION/keys/srv1.pub" ] && head -n 3 "$SESSION/config" | grep -q "^Host \*" &&
	ok "既定の設定が先頭にあり、IdentityFile は秘密鍵の無いパス (.pub だけを置く)" || ng "ssh_config の内容が想定外"
[ ! -e "$SESSION/keys/srv1" ] && [ ! -e "$SESSION/keys/id_test" ] && ok "秘密鍵はコンテナ用のディレクトリに無い" || ng "秘密鍵がある"

run_ssh() {
	# run_ssh <コンテナ内のコマンド>  中継をつないで work を1回動かす
	local cmd="$1" cid
	vpnsh_compose --progress quiet run -d --rm --no-deps -T --entrypoint sleep \
		-v "$SESSION/config:/etc/ssh/ssh_config.d/00-vpnsh.conf:ro" \
		-v "$SESSION/keys:/etc/vpnsh/ssh/keys:ro" \
		-v "$SESSION/known_hosts:/etc/vpnsh/ssh/known_hosts:ro" \
		-e "SSH_AUTH_SOCK=$SSH_IN_SOCK" --label vpnsh.test=ssh work 300 >"$T/cid" 2>/dev/null
	cid="$(cat "$T/cid")"
	cid="$(vpnsh_docker inspect -f '{{.Id}}' "$cid" 2>/dev/null)"
	/usr/bin/perl "$ROOT/scripts/ssh-relay" "$cid" "$AGENT_SOCK" "$VPNSH_CONTEXT" "$T/state/ssh-audit.log" </dev/null &
	RELAY_PID=$!
	local i=0
	until vpnsh_docker exec "$cid" test -S "$SSH_IN_SOCK" 2>/dev/null; do i=$((i + 1)); [ "$i" -gt 50 ] && break; sleep 0.1; done
	OUT="$(vpnsh_docker exec "$cid" sh -c "mkdir -p -m 700 /tmp/vpnsh-cm; $cmd" 2>&1)"
	CID="$cid"
}
in_c() { vpnsh_docker exec "$CID" sh -c "$1" 2>&1; }
end_ssh() { kill "$RELAY_PID" 2>/dev/null; RELAY_PID=""; vpnsh_docker rm -f "$CID" >/dev/null 2>&1; }
NOCM="-o ControlMaster=no -o ControlPath=none -o BatchMode=yes"

run_ssh "ssh $NOCM srv1 'echo login-ok'"
case "$OUT" in *login-ok*) ok "中継を通して専用 ssh-agent の鍵で認証できる" ;; *) ng "認証できない: $OUT" ;; esac
calls_before="$(grep -c . "$T/askpass-calls" 2>/dev/null)"
[ "${calls_before:-0}" -ge 1 ] && ok "鍵を使うときに確認が呼ばれた" || ng "確認が呼ばれていない"

echo deny >"$T/askpass-mode"
before="$(grep -c . "$T/askpass-calls")"
OUT="$(in_c "ssh $NOCM srv1 'echo login-ok'")"
after="$(grep -c . "$T/askpass-calls")"
case "$OUT" in *login-ok*) ng "拒否したのに認証できた" ;; *) [ "$after" -gt "$before" ] && ok "確認で拒否すると認証できない (確認が呼ばれて拒否された)" || ng "確認が呼ばれずに失敗した (拒否の確認になっていない): $OUT" ;; esac
echo allow >"$T/askpass-mode"

before="$(grep -c . "$T/askpass-calls")"
OUT="$(in_c "ssh $NOCM srv2 'echo login-ok'")"
after="$(grep -c . "$T/askpass-calls")"
case "$OUT" in *login-ok*) ng "縛っていないサーバー (srv2) に認証できた" ;; *) ok "縛っていないサーバー (srv2) には使われない" ;; esac
[ "$before" = "$after" ] && ok "そのとき確認ダイアログも出ない" || ng "縛っていないサーバーへの要求で確認が出た"

echo "== 2b. 中継が通す要求の種類を絞る"
cat >"$T/agentreq.pl" <<'EOF'
# 任意の種類の要求を中継のソケットに送り、応答の種類を出す
use strict; use IO::Socket::UNIX; use Socket qw(SOCK_STREAM); use IO::Select;
my ($type, $body) = @ARGV;
my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $ENV{SSH_AUTH_SOCK}) or die "connect: $!";
my $payload = chr($type) . ($body // "");
syswrite($s, pack("N", length $payload) . $payload);
my $n = read($s, my $h, 5);
print $n == 5 ? "resp=" . ord(substr($h, 4, 1)) : "closed";
# 応答のあと、中継が接続を閉じたか (拒否した要求のあとは閉じる)
my $sel = IO::Select->new($s);
print $sel->can_read(3) && !sysread($s, my $more, 1) ? " eof\n" : " open\n";
EOF
vpnsh_docker exec -i "$CID" sh -c 'cat > /tmp/agentreq.pl' <"$T/agentreq.pl"
ok_types=1
for t in 17 18 19 22 25 20; do
	out="$(in_c "perl /tmp/agentreq.pl $t \"\$(printf '\\000\\000\\000\\001x')\"")"
	[ "$out" = "resp=5 eof" ] || { ok_types=0; ng "種類 $t の要求の扱いが想定外: $out"; }
done
[ "$ok_types" = "1" ] && ok "鍵の追加 (17/25)・削除 (18/19)・ロック (22)・スマートカード (20) は失敗 (5) を返して接続を閉じる"
out="$(in_c 'ssh-keygen -q -t ed25519 -N "" -f /tmp/k && ssh-add /tmp/k; echo rc=$?; ssh-add -D; echo rc=$?')"
case "$out" in *"rc=0"*) ng "コンテナから鍵の追加か全削除ができた: $out" ;; *) ok "コンテナの ssh-add で鍵の追加・全削除はできない" ;; esac
n="$(SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -l 2>/dev/null | grep -c SHA256)"
[ "$n" = "1" ] && ok "専用 ssh-agent の鍵はそのまま (1個、ロックもされていない)" || ng "専用 ssh-agent の鍵が変わった ($n 個)"
grep -q 'deny(relay:type=17)' "$T/state/ssh-audit.log" && ok "拒否した要求を記録する" || ng "拒否した要求が記録されない"
out="$(in_c 'ssh-add -l')"
case "$out" in *"$FP_TEST"*) ok "鍵の一覧 (11) は通す" ;; *) ng "鍵の一覧が通らない: $out" ;; esac
# 拒否される要求を送り続けても、Mac 側の記録は増え続けない (最初の10件だけを1件ずつ記録する)
in_c 'for i in $(seq 1 60); do perl /tmp/agentreq.pl 17 x >/dev/null; done' >/dev/null
n="$(grep -c 'deny(relay:type=' "$T/state/ssh-audit.log")"
[ "$n" -le 10 ] && ok "拒否される要求を送り続けても、記録は1件ずつにならない (${n} 件)" || ng "拒否の記録が増え続けた (${n} 件)"
out="$(in_c 'ssh-add -l')"
case "$out" in *"$FP_TEST"*) ok "その後も中継は動いている" ;; *) ng "中継が止まった: $out" ;; esac

echo "== 2c. 同時接続数の上限"
cat >"$T/many.pl" <<'EOF'
use strict; use IO::Socket::UNIX; use Socket qw(SOCK_STREAM); use IO::Select;
$SIG{PIPE} = "IGNORE";    # 上限を超えて閉じられた接続に書いても終了しないように
my @s; for (1 .. 40) { my $c = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $ENV{SSH_AUTH_SOCK}) or next; push @s, $c; select(undef, undef, undef, 0.02); }
syswrite($_, pack("N", 1) . chr(11)) for @s;
my ($ans, $closed) = (0, 0);
for my $c (@s) { my $sel = IO::Select->new($c); if ($sel->can_read(3)) { my $n = sysread($c, my $b, 8); if ($n) { $ans++ } else { $closed++ } } else { $closed++ } }
print "answered=$ans closed=$closed\n";
EOF
vpnsh_docker exec -i "$CID" sh -c 'cat > /tmp/many.pl' <"$T/many.pl"
out="$(in_c 'perl /tmp/many.pl')"
case "$out" in "answered=32 closed=8") ok "1シェルあたり32本まで (40本中、超えた分は閉じる)" ;; *) ng "上限が想定外: [$out]" ;; esac
out="$(SSH_AUTH_SOCK="$AGENT_SOCK" vpnsh_timeout 5 ssh-add -l 2>&1 | grep -c SHA256)"
[ "$out" = "1" ] && ok "そのあとも専用 ssh-agent は応答する" || ng "専用 ssh-agent が応答しない"

echo "== 2d. 接続の動作"
OUT="$(in_c "for i in 1 2 3 4 5; do ssh $NOCM srv1 \"echo p\$i\" & done; wait")"
n="$(printf '%s\n' "$OUT" | grep -c '^p[0-9]$')"
[ "$n" -eq 5 ] && ok "同時に5本の接続を通せる" || ng "同時接続で失敗した ($n/5): $OUT"

OUT="$(in_c 'ssh -o BatchMode=yes srv1 "echo cm1" && ssh -o BatchMode=yes srv1 "echo cm2"; ssh -O check srv1 2>&1; ssh -O exit srv1 2>&1')"
case "$OUT" in *cm1*cm2*"Master running"*) ok "ControlMaster で接続を使い回せる (ssh -O exit で止められる)" ;; *) ng "ControlMaster が動かない: $OUT" ;; esac

OUT="$(in_c "ssh $NOCM srv1 'echo \${SSH_AUTH_SOCK:-none}'")"
case "$OUT" in *none*) ok "既定では接続先にエージェントを渡さない (ForwardAgent no)" ;; *) ng "既定で接続先にエージェントが渡った: $OUT" ;; esac

echo "== 2e. 同じコンテナの別のプロセスから中継を覗けない"
cat >"$T/pt.pl" <<'EOF'
use strict;
chomp(my $relay = `pgrep -f /usr/local/lib/vpnsh/ssh-relay | head -n 1`);
if ($relay !~ /^\d+$/) { print "nopid\n"; exit }
my $r = open(my $fh, "<", "/proc/$relay/fd/0") ? "open" : "denied";
my %nr = (aarch64 => 117, x86_64 => 101); chomp(my $m = `uname -m`);
my $p = syscall($nr{$m}, 16, $relay, 0, 0) == 0 ? "attached" : "denied";
print "fd=$r ptrace=$p\n";
EOF
vpnsh_docker exec -i "$CID" sh -c 'cat > /tmp/pt.pl' <"$T/pt.pl"
out="$(in_c 'perl /tmp/pt.pl')"
[ "$out" = "fd=denied ptrace=denied" ] && ok "中継の入出力を開けず、ptrace もできない" || ng "中継を覗けた: $out"

echo "== 2f. 同じ鍵を複数の接続先で使う"
SSH_HOSTS_FILE="$T/state/hosts"
out="$(ssh_add srv2 2>&1)"
names="$(ssh_added_names "$FP_TEST")"
[ "$names" = "srv1,srv2" ] && ok "srv2 を指定して読み込んでも、同じ鍵を使う srv1 も縛りに含める" || ng "縛りが想定外: $names ($out)"
OUT="$(in_c "ssh $NOCM srv1 'echo a1'; ssh $NOCM srv2 'echo a2'")"
case "$OUT" in *a1*a2*) ok "そのあと srv1 にも srv2 にもつながる" ;; *) ng "どちらかにつながらない: $OUT" ;; esac

echo "== 2g. 鍵がメモリに無いときの表示"
SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -D >/dev/null 2>&1
OUT="$(in_c "ssh $NOCM srv1 'echo x'")"
case "$OUT" in *UNPROTECTED*) ng "誤解を招く警告が出る: $OUT" ;; *"Permission denied"*) ok "UNPROTECTED PRIVATE KEY の警告を出さずに認証に失敗する" ;; *) ng "想定外の表示: $OUT" ;; esac

kill "$RELAY_PID" 2>/dev/null; RELAY_PID=""
i=0
while [ "$(vpnsh_docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null)" = "true" ] && [ "$i" -lt 30 ]; do sleep 0.2; i=$((i + 1)); done
[ "$(vpnsh_docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null)" != "true" ] && ok "Mac 側の中継が終わるとコンテナも終了する" || ng "中継が終わってもコンテナが残った"
end_ssh

echo "== 2h. 拒否が多すぎれば中継を終える"
run_ssh 'true'
vpnsh_docker exec -i "$CID" sh -c 'cat > /tmp/agentreq.pl' <"$T/agentreq.pl"
in_c 'for i in $(seq 1 1100); do perl /tmp/agentreq.pl 17 x >/dev/null 2>&1 || break; done' >/dev/null
i=0
while kill -0 "$RELAY_PID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
kill -0 "$RELAY_PID" 2>/dev/null && ng "拒否が1000件を超えても中継が続いた" || ok "拒否が1000件を超えると中継を終える (シェルも閉じる)"
grep -q 'too-many' "$T/state/ssh-audit.log" && ok "そのことを記録する" || ng "中継を終えたことが記録されない"
end_ssh

echo "== 2i. 署名の拒否・時間切れが続けば中継を終える (確認ダイアログの連打を防ぐ)"
# 2g で鍵を消したので登録し直す
SSH_AUTH_SOCK="$AGENT_SOCK" /usr/bin/ssh-add -q -c -t 10m -H "$T/state/known_hosts" -h "tester@[127.0.0.1]:2222" "$T/id_test" 2>/dev/null
run_ssh 'true'
echo deny >"$T/askpass-mode"
# 確認の文言は複数行なので、呼ばれた回数は先頭行 (Allow use of key) で数える
before="$(grep -c 'Allow use of key' "$T/askpass-calls")"
in_c "ssh $NOCM srv1 true; ssh $NOCM srv1 true" >/dev/null
after="$(grep -c 'Allow use of key' "$T/askpass-calls")"
sleep 1
[ $((after - before)) -eq 2 ] && kill -0 "$RELAY_PID" 2>/dev/null &&
	ok "署名の失敗が2回までなら中継は続く" || ng "署名の失敗2回で中継が止まった (確認 $((after - before)) 回)"
in_c "ssh $NOCM srv1 true" >/dev/null
i=0
while kill -0 "$RELAY_PID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
kill -0 "$RELAY_PID" 2>/dev/null && ng "署名の失敗が3回続いても中継が続いた" || ok "署名の失敗が5分以内に3回になると中継を終える (シェルも閉じる)"
grep -q 'sign-failed-too-often' "$T/state/ssh-audit.log" && ok "そのことを記録する" || ng "署名の失敗で中継を終えたことが記録されない"
echo allow >"$T/askpass-mode"
end_ssh

echo "== 2j. 応答の前に接続を閉じても数える・ダイアログの出ない失敗は数えない"
# 署名の要求 (13) を直接送る。close: 送ってすぐ閉じる / wait: 応答の種類を出す
cat >"$T/sign13.pl" <<'EOF'
use strict; use IO::Socket::UNIX; use Socket qw(SOCK_STREAM); use MIME::Base64;
# pipe <N>: 1本の接続に N 件をまとめて送る / multi <N>: N 本の接続で1件ずつ同時に送る (どちらも応答は待たない)
my ($pub, $mode, $n) = @ARGV;
my $blob = decode_base64((split ' ', $pub)[1]);
my $p = chr(13) . pack("N/a*", $blob) . pack("N/a*", "vpnsh-test-data") . pack("N", 0);
my $req = pack("N", length $p) . $p;
my $open = sub { IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $ENV{SSH_AUTH_SOCK}) or die "connect: $!" };
if ($mode eq "pipe") { my $s = $open->(); syswrite($s, $req x $n); sleep 60; exit 0; }
if ($mode eq "multi") { my @s = map { my $s = $open->(); syswrite($s, $req); $s } 1 .. $n; sleep 60; exit 0; }
my $s = $open->();
syswrite($s, $req);
if ($mode eq "close") { select(undef, undef, undef, 0.2); close $s; exit 0; }
my $n = read($s, my $h, 5);
print $n == 5 ? "resp=" . ord(substr($h, 4, 1)) . "\n" : "closed\n";
EOF
# 接続先に縛っていない、確認付きの鍵 (session-bind の無い接続でもダイアログが出る)
ssh-keygen -q -t ed25519 -N '' -C vpnsh-test-key2 -f "$T/id_test2"
SSH_AUTH_SOCK="$AGENT_SOCK" /usr/bin/ssh-add -q -c -t 10m "$T/id_test2" 2>/dev/null
run_ssh 'true'
vpnsh_docker exec -i "$CID" sh -c 'cat > /tmp/sign13.pl' <"$T/sign13.pl"
PUB1="$(cat "$T/id_test.pub")"; PUB2="$(cat "$T/id_test2.pub")"
# 接続先に縛った鍵を session-bind の無い接続で使う (コミットの署名など)。ダイアログを出さずに失敗する
echo deny >"$T/askpass-mode"
before="$(grep -c 'Allow use of key' "$T/askpass-calls")"
out="$(in_c "for i in 1 2 3 4; do perl /tmp/sign13.pl '$PUB1' wait; done")"
after="$(grep -c 'Allow use of key' "$T/askpass-calls")"
sleep 1
[ "$(printf '%s\n' "$out" | grep -c '^resp=5$')" -eq 4 ] && [ "$before" = "$after" ] && kill -0 "$RELAY_PID" 2>/dev/null &&
	ok "ダイアログの出ない署名の失敗は数えない (4回失敗しても中継は続く)" || ng "ダイアログの出ない失敗で中継が止まった: $out (確認 $((after - before)) 回)"
end_ssh
# 縛っていない鍵で署名を要求し、ダイアログが出ている間に接続を閉じる (新しい中継で試す)
run_ssh 'true'
vpnsh_docker exec -i "$CID" sh -c 'cat > /tmp/sign13.pl' <"$T/sign13.pl"
echo slow >"$T/askpass-mode"
in_c "for i in 1 2 3; do perl /tmp/sign13.pl '$PUB2' close; done" >/dev/null
i=0
while kill -0 "$RELAY_PID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
kill -0 "$RELAY_PID" 2>/dev/null && ng "応答の前に接続を閉じると、署名の失敗が数えられない" || ok "応答の前に接続を閉じた署名の要求も失敗として数える (3回で中継を終える)"
grep -q 'sign-failed;closed-before-response' "$T/state/ssh-audit.log" && ok "そのことを記録する" || ng "応答の前に閉じた署名の要求が記録されない"
# 専用 ssh-agent が残りのダイアログを終えるのを待ってから次へ (偽のダイアログは1回2秒)
sleep 7
end_ssh

echo "== 2k. 署名の要求をまとめて送っても、ダイアログは1件ずつ出し、3回で止める"
# askpass_settled  専用 ssh-agent が確認ダイアログを出し終えるまで待ち、それまでの回数を出す
askpass_settled() {
	local prev=-1 cur i=0
	while [ "$i" -lt 20 ]; do
		cur="$(grep -c 'Allow use of key' "$T/askpass-calls")"
		[ "$cur" = "$prev" ] && break
		prev="$cur"; sleep 3; i=$((i + 1))
	done
	printf '%s' "$cur"
}
for how in pipe multi; do
	run_ssh 'true'
	vpnsh_docker exec -i "$CID" sh -c 'cat > /tmp/sign13.pl' <"$T/sign13.pl"
	before="$(askpass_settled)"
	in_c "perl /tmp/sign13.pl '$PUB2' $how 6" >/dev/null 2>&1 &
	bg=$!
	i=0
	while kill -0 "$RELAY_PID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
	stopped="yes"; kill -0 "$RELAY_PID" 2>/dev/null && stopped="no"
	after="$(askpass_settled)"
	kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null
	case "$how" in pipe) what="1本の接続にまとめて6件" ;; *) what="6本の接続で同時に" ;; esac
	[ "$stopped" = "yes" ] && [ $((after - before)) -eq 3 ] &&
		ok "署名の要求を${what}送っても、ダイアログは3回だけ出て中継を終える" ||
		ng "署名の要求を${what}送ったとき: 中継の停止 ${stopped}、ダイアログ $((after - before)) 回 (期待値: yes、3 回)"
	end_ssh
done
echo allow >"$T/askpass-mode"
SSH_AUTH_SOCK="$AGENT_SOCK" /usr/bin/ssh-add -q -d "$T/id_test2.pub" 2>/dev/null
ssh_session_remove "$SESSION"
[ ! -d "$SESSION" ] && ok "シェル専用の設定を片付けられる" || ng "シェル専用の設定が残った"

echo
echo "結果: OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ]
