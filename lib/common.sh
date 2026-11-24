# shellcheck shell=bash
# VPNShell 共通処理 (macOS の /bin/bash 3.2 で動くように書く: 連想配列・${x,,} などは使わない)

# bin/vpnsh はこれらを上書きできないよう、読み込む前に unset する (テストだけが別の名前を使う)
VPNSH_PROJECT="${VPNSH_PROJECT:-vpnshell}"
VPNSH_CONTEXT="${VPNSH_CONTEXT:-orbstack}"
VPNSH_GLUETUN_NAME="${VPNSH_GLUETUN_NAME:-vpnshell-gluetun}"
# 事前チェックの失敗はすべてこの終了コード (vpnsh run のコマンドの終了コードとは衝突し得るので、理由は stderr で示す)
# shellcheck disable=SC2034  # bin/vpnsh が参照する
VPNSH_EXIT_PREFLIGHT=125
# Mac 側の docker 呼び出しの時間制限 (秒)
VPNSH_DOCKER_TIMEOUT=15

# ---- 表示 (すべて stderr) ----
_vpnsh_color() { [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; }
vpnsh_info() { if _vpnsh_color; then printf '\033[36mvpnsh:\033[0m %s\n' "$*" >&2; else printf 'vpnsh: %s\n' "$*" >&2; fi; }
vpnsh_warn() { if _vpnsh_color; then printf '\033[33mvpnsh: 警告:\033[0m %s\n' "$*" >&2; else printf 'vpnsh: 警告: %s\n' "$*" >&2; fi; }
vpnsh_err()  { if _vpnsh_color; then printf '\033[31mvpnsh: エラー:\033[0m %s\n' "$*" >&2; else printf 'vpnsh: エラー: %s\n' "$*" >&2; fi; }
vpnsh_verbose() { [ -n "${VPNSH_VERBOSE:-}" ] && printf 'vpnsh: [詳細] %s\n' "$*" >&2; return 0; }
# die <メッセージ> [終了コード]
vpnsh_die() { vpnsh_err "$1"; exit "${2:-1}"; }

# vpnsh_sanitize  (stdin → stdout) 端末の制御文字 (エスケープシーケンスなど) を取り除く
# gluetun のログなど、外から来た文字列を端末に出すときに使う (タブと改行は残す)
vpnsh_sanitize() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }
# vpnsh_visible  (stdin → stdout) 制御文字を消さずに ^[ のような見える形にする (人が確かめる差分の表示に使う。
# 消すと「何かが隠されていた」ことに気づけないため。日本語などはそのまま残す)
vpnsh_visible() { perl -pe 's/([\x00-\x08\x0b-\x1f\x7f])/"^" . chr(ord($1) ^ 64)/ge'; }

# vpnsh_lc <文字列>  英字を小文字にして出す (bash 3.2 には ${v,,} が無いため)
# tr は絶対パスで呼ぶ (vpnsh_safe_path は PATH を安全にする前に呼ばれるので、PATH から探すと偽物を使い得る)
vpnsh_lc() { printf '%s' "$1" | LC_ALL=C /usr/bin/tr 'A-Z' 'a-z'; }

# ---- PATH を安全にする ----
# vpnsh_safe_path <マウントできる場所の根元>  PATH から、マウントできる場所の配下・相対パス・存在しないものを除き、
# /usr/bin などを必ず含めたものを出す。シェルの中のコードは --mount-cwd-rw でマウントしたディレクトリに書けるので、
# そこが PATH に入っていると (direnv の PATH_add、node_modules/.bin など)、偽の docker などに秘密鍵を渡してしまうため
# APFS は既定で大文字・小文字を区別しないので (~/projects も ~/Projects を指す)、パスは小文字にそろえて比べる
# (区別するボリュームでは除く範囲が広がるだけなので、安全側に倒れる)
vpnsh_safe_path() {
	local root="$1" new="" d real lroot lhome IFS=:
	root="$(cd -P "$root" 2>/dev/null && pwd)" || root="$1"
	lroot="$(vpnsh_lc "$root")"
	lhome="$(vpnsh_lc "$HOME")"
	for d in $PATH; do
		case "$d" in /*) ;; *) continue ;; esac
		[ -d "$d" ] || continue
		# ホームの配下だけ、シンボリックリンクを解決して確かめる (それ以外は数が多いので、そのまま比べる)
		real="$d"
		case "$(vpnsh_lc "$d")" in "$lhome"/*) real="$(cd -P "$d" 2>/dev/null && pwd)" || continue ;; esac
		case "$(vpnsh_lc "$real")/" in "$lroot/"*) continue ;; esac
		case ":$new:" in *":$d:"*) continue ;; esac
		new="${new:+$new:}$d"
	done
	for d in /usr/bin /bin /usr/sbin /sbin; do
		case ":$new:" in *":$d:"*) ;; *) new="${new:+$new:}$d" ;; esac
	done
	printf '%s' "$new"
}

# ---- 環境変数の掃除 ----
# compose や docker の対象・値が Mac のシェルの環境変数で変わらないようにする
# - COMPOSE_* / DOCKER_* / BUILDX_* / BUILDKIT_*: 対象のプロジェクト・ファイル・ビルダーを変え得る
#   (COMPOSE_PROJECT_NAME は name: より優先され、COMPOSE_FILE は override を注入できる)
# - compose.yaml の変数展開に使う名前: シェルの環境変数は .env より優先されるため
VPNSH_COMPOSE_VARS="WIREGUARD_ENDPOINT_IP WIREGUARD_ENDPOINT_PORT WIREGUARD_PUBLIC_KEY WIREGUARD_ADDRESSES WIREGUARD_MTU EXPECTED_PUBLIC_IP VPNSH_IP_CHECK_URLS VPNSH_GLUETUN_NAME VPNSH_STATE_DIR VPNSH_UID VPNSH_GID VPNSH_TZ VPNSH_BUILD_HASH VPNSH_WG_PRIVATE_KEY VPNSH_CONTROL_DEFAULT_ROLE"
vpnsh_clean_env() {
	local v
	for v in $(env | sed -n \
		-e 's/^\(COMPOSE_[A-Za-z0-9_]*\)=.*/\1/p' \
		-e 's/^\(DOCKER_[A-Za-z0-9_]*\)=.*/\1/p' \
		-e 's/^\(BUILDX_[A-Za-z0-9_]*\)=.*/\1/p' \
		-e 's/^\(BUILDKIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$v"
	done
	for v in $VPNSH_COMPOSE_VARS; do
		case "$v" in
			# vpnsh 自身が使う変数は値を残し、子プロセスへの export だけ外す
			VPNSH_GLUETUN_NAME | VPNSH_STATE_DIR)
				# shellcheck disable=SC2163  # 変数名を間接的に指定している
				export -n "$v" 2>/dev/null
				;;
			*) unset "$v" ;;
		esac
	done
}

# ---- 所要時間の表示 (--timing) ----
# vpnsh_timing <段階の名前>  前回からの経過と累計をミリ秒で出す (VPNSH_TIMING が空なら何もしない)
VPNSH_TIMING=""
VPNSH_T0=""
VPNSH_T_LAST=""
vpnsh_now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
vpnsh_timing() {
	[ -n "$VPNSH_TIMING" ] || return 0
	local now
	now="$(vpnsh_now_ms)"
	[ -n "$VPNSH_T0" ] || VPNSH_T0="$now"
	[ -n "$VPNSH_T_LAST" ] || VPNSH_T_LAST="$VPNSH_T0"
	printf 'vpnsh: [時間] %+6d ms (累計 %5d ms)  %s\n' "$((now - VPNSH_T_LAST))" "$((now - VPNSH_T0))" "$1" >&2
	VPNSH_T_LAST="$now"
}

# ---- 時間制限 (macOS には timeout(1) が無いので perl の alarm を使う) ----
# vpnsh_timeout <秒> <コマンド...>  時間切れなら 124 を返す
vpnsh_timeout() {
	local secs="$1"; shift
	perl -e '
		my $s = shift @ARGV;
		my $pid = fork();
		die "fork: $!" unless defined $pid;
		if ($pid == 0) { exec @ARGV or exit 127; }
		local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 1; kill "KILL", $pid; exit 124; };
		alarm $s;
		waitpid($pid, 0);
		alarm 0;
		exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
	' "$secs" "$@"
}

# ---- docker / compose の呼び出し (対象を固定し、時間制限を付ける) ----
vpnsh_docker() { vpnsh_timeout "$VPNSH_DOCKER_TIMEOUT" docker --context "$VPNSH_CONTEXT" "$@"; }

# vpnsh_compose_t <秒> <args...>  時間制限つきの compose (up・down・config。OrbStack が固まっても無限に待たない)
vpnsh_compose_t() {
	local secs="$1"; shift
	vpnsh_timeout "$secs" docker --context "$VPNSH_CONTEXT" compose \
		-p "$VPNSH_PROJECT" \
		-f "$VPNSH_ROOT/compose.yaml" \
		--project-directory "$VPNSH_ROOT" \
		--env-file "$VPNSH_ENV_FILE" \
		"$@"
}

# vpnsh_compose <args...>  (時間制限なし: run や build は長くかかり得る)
# VPNSH_ROOT と VPNSH_ENV_FILE が設定済みであること
vpnsh_compose() {
	command docker --context "$VPNSH_CONTEXT" compose \
		-p "$VPNSH_PROJECT" \
		-f "$VPNSH_ROOT/compose.yaml" \
		--project-directory "$VPNSH_ROOT" \
		--env-file "$VPNSH_ENV_FILE" \
		"$@"
}

# ---- プロセスの開始時刻 (ロケールやタイムゾーンで表記が変わらないよう固定する) ----
vpnsh_proc_start() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' '_' | sed 's/^_//;s/_$//'; }

# ---- .env の読み込み ----
# 書式は厳密に「KEY=VALUE」だけ (export、引用符、コメント行以外の #、$、空白、バックスラッシュは不可)。
# vpnsh が読む値と compose の解釈が食い違わないようにするため。
VPNSH_ENV_LOADED=""
VPNSH_ENV_TEXT=""
vpnsh_env_load() {
	VPNSH_ENV_TEXT=""
	VPNSH_ENV_LOADED="$VPNSH_ENV_FILE"
	[ -f "$VPNSH_ENV_FILE" ] || return 0
	VPNSH_ENV_TEXT="$(cat "$VPNSH_ENV_FILE")"
}
# vpnsh_env_validate  書式に合わない行があれば行番号を出して 1
vpnsh_env_validate() {
	[ -f "$VPNSH_ENV_FILE" ] || return 0
	local bad
	bad="$(LC_ALL=C grep -nvE '^([A-Z][A-Z0-9_]*=[A-Za-z0-9+/=.:,_@-]*|#.*|[[:space:]]*)$' "$VPNSH_ENV_FILE")"
	if [ -n "$bad" ]; then
		vpnsh_err ".env の書式が正しくありません (KEY=VALUE のみ。引用符・空白・\$・行末コメントは使えません):"
		printf '%s\n' "$bad" | cut -c1-120 | sed 's/^/    /' | vpnsh_sanitize >&2
		return 1
	fi
	return 0
}
# vpnsh_env_get <KEY>  値を stdout に出す (無ければ空。同じキーが複数あれば最後のもの)
vpnsh_env_get() {
	[ "$VPNSH_ENV_LOADED" = "$VPNSH_ENV_FILE" ] || vpnsh_env_load
	local line val=""
	while IFS= read -r line; do
		case "$line" in "$1="*) val="${line#*=}" ;; esac
	done <<EOF
$VPNSH_ENV_TEXT
EOF
	printf '%s' "$val"
}

# vpnsh_table [字下げ]  (stdin: タブ区切りの行 → stdout: 列を揃えた表)
# 全角の文字は幅 2 として数える (printf はバイト数で数えるので日本語でずれるため)
vpnsh_table() {
	VPNSH_TABLE_INDENT="${1:-}" perl -CSD -e '
		sub w { my $n = 0; for (split //, $_[0]) { $n += (ord($_) >= 0x1100 && (ord($_) <= 0x115F || (ord($_) >= 0x2E80 && ord($_) <= 0xA4CF) || (ord($_) >= 0xAC00 && ord($_) <= 0xD7A3) || (ord($_) >= 0xF900 && ord($_) <= 0xFAFF) || (ord($_) >= 0xFE30 && ord($_) <= 0xFE4F) || (ord($_) >= 0xFF00 && ord($_) <= 0xFF60) || (ord($_) >= 0xFFE0 && ord($_) <= 0xFFE6))) ? 2 : 1 } $n }
		my (@rows, @wid);
		while (<STDIN>) { chomp; my @c = split /\t/, $_, -1; push @rows, [@c]; for my $i (0 .. $#c) { my $x = w($c[$i]); $wid[$i] = $x if !defined $wid[$i] || $x > $wid[$i] } }
		for my $r (@rows) {
			my $line = $ENV{VPNSH_TABLE_INDENT};
			for my $i (0 .. $#$r) { $line .= $r->[$i]; $line .= " " x ($wid[$i] - w($r->[$i]) + 2) if $i < $#$r }
			print "$line\n";
		}
	'
}
