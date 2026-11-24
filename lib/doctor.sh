# shellcheck shell=bash
# shellcheck disable=SC2088  # 表示用に "~/..." の文字列をそのまま使う
# shellcheck disable=SC2153  # SSH_AGENT_DIR などは lib/ssh.sh で定義している
# vpnsh doctor: 設定や状態を一括で点検する
#
# - 通信はしない (Docker への問い合わせだけ)。vpnsh の確認ダイアログも出さない (キーチェーンは項目の権限を読むだけで、
#   秘密の値は読まない。ロックされていても解除のダイアログを出さない dump-keychain を使う。show-keychain-info は
#   ロック中に解除のダイアログを出すので使わない)
# - ~/.ssh/config に Match exec があるときは、ssh -G (コマンドが実行される) を呼ばない
# - 直すことはしない。何をすればよいかを表示する (キーチェーンの確認結果の控えだけ state/ に書く)
# - bin/vpnsh の関数 (work_list、work_build_hash、host_checks など) を使う

DR_NG=0
DR_WARN=0
# 色は端末に出すときだけ付ける
dr_c() { if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
dr_section() { printf '\n%s\n' "$1"; }
dr_ok() { printf '  %s   %s\n' "$(dr_c 32 '[OK]')" "$*"; }
dr_ng() { DR_NG=$((DR_NG + 1)); printf '  %s   %s\n' "$(dr_c 31 '[NG]')" "$*"; }
dr_warn() { DR_WARN=$((DR_WARN + 1)); printf '  %s %s\n' "$(dr_c 33 '[警告]')" "$*"; }
dr_info() { printf '  [情報] %s\n' "$*"; }
dr_na() { printf '  [--]   %s\n' "$*"; }
# 表示用のパス (ホームは ~ に縮める)
dr_path() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
# 次にすることの案内 (直前の行に続けて出す)
dr_hint() { printf '         → %s\n' "$*"; }

# dr_days_since <RFC3339 の日時>  今日までの日数
dr_days_since() {
	perl -MTime::Local -e '
		my ($y, $m, $d) = $ARGV[0] =~ /^(\d{4})-(\d{2})-(\d{2})/ or exit 1;
		printf "%d\n", (time - timegm(0, 0, 0, $d, $m - 1, $y)) / 86400;
	' "$1"
}

# dr_mode <パス>  権限 (8進数)
dr_mode() { stat -f %Lp "$1" 2>/dev/null; }

dr_docker() {
	dr_section "Docker (OrbStack)"
	local v
	if ! command -v docker >/dev/null 2>&1; then
		dr_ng "docker コマンドがありません"; dr_hint "OrbStack をインストールしてください"
		return 1
	fi
	if ! vpnsh_docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
		dr_ng "Docker (OrbStack, context $VPNSH_CONTEXT) に接続できません"; dr_hint "orb start"
		return 1
	fi
	dr_ok "Docker (context $VPNSH_CONTEXT) に接続できる"
	v="$(orb version 2>/dev/null | sed -n 's/^Version: *\([0-9][0-9.]*\).*/\1/p' | head -n 1)"
	if [ -z "$v" ]; then
		dr_warn "OrbStack の版が分かりません (orb コマンドがない)"
	elif perl -e 'my @a = split /\./, $ARGV[0]; my @b = (2, 2, 4); for (0 .. 2) { exit 0 if ($a[$_] // 0) > $b[$_]; exit 1 if ($a[$_] // 0) < $b[$_] } exit 0' "$v"; then
		dr_ok "OrbStack $v (2.2.4 以上)"
	else
		dr_ng "OrbStack $v は古いです (2.2.4 以上が必要)"; dr_hint "OrbStack を更新してください"
	fi
	# Docker のクライアント設定でコンテナにプロキシの環境変数が足されると、gluetun の整合性の検査に通らない
	if [ -f "$HOME/.docker/config.json" ] && grep -q '"proxies"' "$HOME/.docker/config.json" 2>/dev/null; then
		dr_warn "~/.docker/config.json に proxies の設定があります (コンテナにプロキシの環境変数が足され、gluetun を作れません)"
	fi
	return 0
}

dr_config() {
	dr_section "設定 (.env、state/、~/.zshrc)"
	local out m rc
	if [ ! -f "$VPNSH_ENV_FILE" ]; then
		dr_ng ".env がありません"; dr_hint "vpnsh setup --import <NordVPN の .conf>"
		return 1
	fi
	out="$( (require_env && require_expected_ip) 2>&1)"; rc=$?
	if [ "$rc" -eq 0 ]; then
		dr_ok ".env の書式と値は正しい (専用IP $(vpnsh_env_get EXPECTED_PUBLIC_IP)、MTU $(vpnsh_env_get WIREGUARD_MTU))"
	else
		dr_ng ".env に問題があります:"
		printf '%s\n' "$out" | sed 's/^vpnsh: //; s/^/         /'
	fi
	m="$(dr_mode "$VPNSH_ENV_FILE")"
	case "$m" in 600 | 400) dr_ok ".env の権限は $m" ;; *) dr_warn ".env の権限が $m です (他のユーザーが読めます)"; dr_hint "chmod 600 $VPNSH_ENV_FILE" ;; esac
	if [ -d "$VPNSH_STATE_DIR" ]; then
		m="$(dr_mode "$VPNSH_STATE_DIR")"
		case "$m" in 700) dr_ok "state/ の権限は 700" ;; *) dr_warn "state/ の権限が $m です"; dr_hint "chmod 700 $VPNSH_STATE_DIR" ;; esac
	fi
	local found
	# 元の PATH で探す (vpnsh は起動時に mount-root の配下を PATH から除くため、自分自身が見つからないことがある)
	found="$(PATH="${VPNSH_ORIG_PATH:-$PATH}" /usr/bin/which vpnsh 2>/dev/null)"
	[ -n "$found" ] && found="$(cd -P "$(dirname "$found")/.." 2>/dev/null && pwd)"
	if [ -f "$(zshrc_path)" ] && grep -qxF "$SHELL_MARK_BEGIN" "$(zshrc_path)"; then
		dr_ok "~/.zshrc に vpnsh の設定 (PATH と補完) がある"
	elif [ -n "$found" ] && [ "$found" = "$VPNSH_ROOT" ]; then
		dr_ok "vpnsh は PATH から使える (install-shell 以外の方法で設定済み。補完は確認していません)"
	else
		dr_warn "vpnsh が PATH にありません (~/.zshrc に install-shell の設定もない)"; dr_hint "vpnsh install-shell"
	fi
	return 0
}

# dr_kc_acl <キーチェーン>  vpnsh の項目の「取り出し (decrypt)」の権限を出す
#   "applications (0):" = 確認なしで取り出せるアプリは無い / その後の "app: <パス>" = 確認なしで取り出せるアプリ
dr_kc_acl() {
	"$VPNSH_SECURITY" dump-keychain -a ${1:+"$1"} 2>/dev/null | awk -v s="$VPNSH_KC_SERVICE" -v a="$VPNSH_KC_ACCOUNT" '
		/^keychain: / { svc = ""; acct = ""; dec = 0; inapps = 0; next }
		/"svce"<blob>="/ { svc = $0; sub(/.*"svce"<blob>="/, "", svc); sub(/"$/, "", svc) }
		/"acct"<blob>="/ { acct = $0; sub(/.*"acct"<blob>="/, "", acct); sub(/"$/, "", acct) }
		/authorizations \([0-9]+\):/ { dec = ($0 ~ / (decrypt|any)( |$)/); inapps = 0; next }
		dec && svc == s && acct == a && /applications/ { sub(/^[[:space:]]*/, ""); print; dec = 0; inapps = 1; next }
		inapps && /^[[:space:]]+[0-9]+: / { sub(/^[[:space:]]*[0-9]+: /, "app: "); print; next }
		/^[[:space:]]+requirement:/ { next }
		{ inapps = 0 }
	'
}

dr_keychain() {
	dr_section "秘密鍵 (キーチェーン、ダウンロードした .conf)"
	local acl kc files f
	if ! kc_exists; then
		dr_ng "キーチェーンに WireGuard の秘密鍵がありません"; dr_hint "vpnsh setup --import <NordVPN の .conf>"
	else
		dr_ok "キーチェーンに WireGuard の秘密鍵がある"
		# 取り出し (decrypt) を確認なしで許されたアプリが無いこと (「常に許可」を押すと /usr/bin/security が載る)。
		# 項目の属性と権限を読むだけで、秘密の値は読まない (確認ダイアログは出ない)
		kc="$("$VPNSH_SECURITY" default-keychain 2>/dev/null | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
		# キーチェーンのファイルが前回の確認から変わっていなければ、前回の結果 (問題なし) を使う
		# (「常に許可」を押すとキーチェーンに書き込みが起きるので、変わっていれば必ず確かめ直す)
		local stamp="" cache="$VPNSH_STATE_DIR/doctor-keychain"
		[ -f "$kc" ] && stamp="$kc $(stat -f '%i %z %m' "$kc" 2>/dev/null)"
		if [ -n "$stamp" ] && [ "$(cat "$cache" 2>/dev/null)" = "$stamp" ]; then
			acl="applications (0):"
			dr_info "キーチェーンは前回の点検から変わっていないので、前回の結果を使います"
		else
			[ -t 2 ] && printf '  (キーチェーンの項目の権限を確認しています。十数秒かかります)\n' >&2
			acl="$(dr_kc_acl "$kc")"
		fi
		case "$acl" in
			"applications (0):")
				dr_ok "取り出すたびに確認が出る設定のまま (「常に許可」は押されていない)"
				[ -n "$stamp" ] && [ -d "$VPNSH_STATE_DIR" ] && printf '%s\n' "$stamp" >"$cache"
				;;
			"")
				dr_warn "キーチェーンの項目の権限を読み取れませんでした (キーチェーンがロックされている可能性)"
				dr_hint "ロックを解除してから、もう一度 vpnsh doctor を実行してください"
				;;
			"applications: <null>")
				rm -f "$cache"
				dr_ng "どのアプリでも確認なしで秘密鍵を取り出せる設定になっています"
				dr_hint "open -a \"Keychain Access\" でキーチェーンアクセスを開き、「${VPNSH_KC_SERVICE}」の項目の「アクセス制御」タブで「アクセスを許可する前に確認」を選んでください"
				;;
			*)
				rm -f "$cache"
				dr_ng "確認なしで秘密鍵を取り出せるアプリがあります (「常に許可」が押された可能性):"
				printf '%s\n' "$acl" | sed -n 's/^app: /           /p' | vpnsh_sanitize
				dr_hint "open -a \"Keychain Access\" でキーチェーンアクセスを開き、「${VPNSH_KC_SERVICE}」の項目の「アクセス制御」タブで、上のアプリを取り除いてください"
				;;
		esac
	fi
	# ダウンロードした .conf (秘密鍵が平文) が残っていないか
	# (macOS が、ターミナルにフォルダへのアクセスの許可を求めることがある。読めなかったフォルダは [--] で示す)
	local unread="" checked=""
	files=""
	for f in "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" "$HOME/.Trash"; do
		[ -d "$f" ] || continue
		if ! ls "$f" >/dev/null 2>&1; then unread="$unread $(dr_path "$f")"; continue; fi
		checked="$checked $(dr_path "$f")"
		files="$files$(find "$f" -maxdepth 3 -type f -name '*.conf' -size -16k 2>/dev/null |
			while IFS= read -r c; do grep -qsE '^[[:space:]]*PrivateKey[[:space:]]*=' "$c" && printf '%s\n' "$c"; done)
"
	done
	files="$(printf '%s' "$files" | sed '/^$/d')"
	[ -n "$unread" ] && dr_na "読めなかったフォルダ:${unread} (フルディスクアクセスが無いなど。ここは確かめていません)"
	if [ -z "$files" ]; then
		[ -n "$checked" ] && dr_ok "${checked# } に、秘密鍵を含む .conf は見当たらない"
	else
		dr_warn "秘密鍵を含む WireGuard の .conf が残っています (同期やバックアップで漏れるおそれ):"
		printf '%s\n' "$files" | vpnsh_sanitize | sed 's/^/           /'
		dr_hint "取り込み済みなら削除してください (ゴミ箱も空にする)"
	fi
}

dr_gluetun() {
	dr_section "gluetun"
	local r pending
	gl_inspect; r=$?
	if [ "$r" -eq 2 ]; then dr_ng "Docker に接続できません"; return 1; fi
	if [ "$r" -eq 1 ]; then
		dr_info "gluetun はありません (次の vpnsh または vpnsh up で作成します)"
		return 0
	fi
	if [ "$GL_STATUS" != "running" ]; then
		dr_warn "gluetun は動いていません ($GL_STATUS)"; dr_hint "vpnsh up"
		return 0
	fi
	case "$GL_HEALTH" in
		healthy) dr_ok "gluetun は動いていて healthy" ;;
		starting) dr_warn "gluetun は起動中です (VPN の接続中)"; dr_hint "少し待ってから、もう一度 vpnsh doctor を実行してください" ;;
		*) dr_ng "gluetun が healthy ではありません ($GL_HEALTH)"; dr_hint "vpnsh logs --tail 50 で原因を確認" ;;
	esac
	if pending="$(gl_pending_changes)"; then
		dr_warn ".env の変更が適用されていません ($(echo "$pending" | tr '\n' ' '))"; dr_hint "vpnsh up"
	else
		dr_ok "未適用の変更はない"
	fi
	if [ "$GL_HEALTH" = "healthy" ]; then
		if gl_verify >/dev/null 2>&1 && gl_fw_check >/dev/null 2>&1; then
			dr_ok "整合性 (作成時のとおり) と遮断ルール・ルーティングは期待値どおり"
		else
			dr_ng "整合性または遮断ルールの検査に通りません"; dr_hint "vpnsh -v check で詳細を表示"
		fi
	else
		dr_na "整合性と遮断ルール・ルーティングは、healthy でないため確かめていません"
	fi
}

dr_images() {
	dr_section "イメージ"
	local label created days pin
	label="$(vpnsh_docker image inspect -f '{{index .Config.Labels "vpnshell.build-hash"}}' vpnshell-work:local 2>/dev/null)"
	if [ -z "$label" ]; then
		dr_ng "work イメージがありません"; dr_hint "vpnsh build"
	else
		if [ "$label" = "$(work_build_hash)" ]; then dr_ok "work イメージは docker/work の内容と一致"; else dr_warn "work イメージが docker/work の内容より古い"; dr_hint "vpnsh build"; fi
		created="$(vpnsh_docker image inspect -f '{{.Created}}' vpnshell-work:local 2>/dev/null)"
		days="$(dr_days_since "$created")"
		if [ -n "$days" ] && [ "$days" -gt 30 ]; then
			dr_warn "work イメージは ${days} 日前にビルドしたものです (apt のセキュリティ更新が入っていません)"; dr_hint "vpnsh build"
		elif [ -n "$days" ]; then
			dr_ok "work イメージは ${days} 日前にビルド"
		fi
	fi
	pin="$(gl_pinned_image)"
	created="$(vpnsh_docker image inspect -f '{{.Created}}' "$pin" 2>/dev/null)"
	if [ -n "$created" ]; then
		days="$(dr_days_since "$created")"
		if [ -n "$days" ] && [ "$days" -gt 120 ]; then
			dr_warn "固定している gluetun (${pin%%@*}) は ${days} 日前の版です"; dr_hint "$(dr_path "$VPNSH_ROOT")/scripts/update-pins で新しい版を確認"
		else
			dr_ok "固定している gluetun (${pin%%@*}) は ${days:-?} 日前の版"
		fi
	else
		dr_info "固定している gluetun のイメージはまだ取得されていません (${pin%%@*})"
	fi
}

dr_shells() {
	dr_section "シェル"
	local list alive orphan unknown
	list="$(work_list)"
	alive="$(printf '%s\n' "$list" | grep -c ' alive$')"
	orphan="$(printf '%s\n' "$list" | grep -c ' orphan$')"
	unknown="$(printf '%s\n' "$list" | grep -c ' unknown$')"
	dr_info "開いているシェル: ${alive} 個"
	if [ "$orphan" -gt 0 ]; then dr_warn "持ち主のいないシェルが ${orphan} 個あります"; dr_hint "vpnsh gc"; fi
	if [ "$unknown" -gt 0 ]; then dr_warn "vpnsh 以外で起動された (判定できない) work コンテナが ${unknown} 個あります"; dr_hint "docker compose を直接実行しなかったか確認してください"; fi
	[ "$orphan" -eq 0 ] && [ "$unknown" -eq 0 ] && dr_ok "持ち主のいないシェルはない"
	return 0
}

dr_ssh() {
	local hosts name host port user k m pub stale d pid denies n=0 before drift=1 cfg
	[ -f "$SSH_HOSTS_FILE" ] || return 0
	dr_section "SSH"
	if ! hosts="$(ssh_hosts 2>&1)"; then
		dr_ng "接続先の設定 (state/hosts) に問題があります:"
		printf '%s\n' "$hosts" | grep 'エラー' | sed 's/^vpnsh: エラー: /         /'
		return 0
	fi
	if [ -z "$hosts" ]; then dr_info "接続先はありません"; return 0; fi
	# ~/.ssh/config に Match exec があると、ssh -G で読むたびにそのコマンドが (素の IP で) 実行されるので、ずれの点検を省く
	cfg="${VPNSH_TEST_SSH_CONFIG:-$HOME/.ssh/config}"
	if grep -sqiE '^[[:space:]]*match[[:space:]].*exec' "$cfg" "$HOME"/.ssh/config.d/* 2>/dev/null; then
		drift=""
		dr_na "~/.ssh/config に Match exec があるので、~/.ssh/config と登録した内容のずれは確かめていません (確かめるとコマンドが実行されるため)"
	fi
	before=$((DR_NG + DR_WARN))
	while read -r name host port user k; do
		[ -n "$name" ] || continue
		n=$((n + 1))
		if [ ! -f "$k" ]; then
			dr_ng "$name: 秘密鍵がありません ($k)"
		else
			m="$(dr_mode "$k")"
			case "$m" in 600 | 400) ;; *) dr_warn "$name: 秘密鍵の権限が $m です ($k)"; dr_hint "chmod 600 $k" ;; esac
		fi
		[ -f "$k.pub" ] || dr_ng "$name: 公開鍵がありません ($k.pub)"
		if ! ssh_has_known_host "$host" "$port"; then
			dr_warn "$name: ホスト鍵が保存されていません"; dr_hint "vpnsh trust-host $name"
		fi
		# ~/.ssh/config を後で変えて、登録した内容とずれていないか
		if [ -n "$drift" ] && ssh_resolve "$name" 2>/dev/null; then
			if [ "$SR_INCONFIG" != "1" ]; then
				dr_warn "$name: ~/.ssh/config に Host $name がもうありません (登録した内容のまま使えます)"
			elif [ "$SR_HOST $SR_PORT $SR_USER" != "$host $port $user" ] || { [ "$SR_IDS_DEFAULT" = "0" ] && ! printf '%s\n' "$SR_IDS" | grep -qxF "$k"; }; then
				dr_warn "$name: ~/.ssh/config の内容と登録した内容が違います (config: $SR_USER@$SR_HOST:${SR_PORT}、登録: $user@$host:$port $k)"
				dr_hint "vpnsh ssh host add $name で登録し直す"
			fi
		fi
	done <<EOF
$hosts
EOF
	if [ $((DR_NG + DR_WARN)) -eq "$before" ]; then
		dr_ok "接続先 ${n} 件に問題はない"
	else
		dr_info "接続先 ${n} 件を確認 (問題 $((DR_NG + DR_WARN - before)) 件。上に表示)"
	fi
	# 指紋の対応表 (確認ダイアログの表示用) が接続先と合っているか (作り直した結果と比べる。元のファイルは書き換えない)
	d="$(mktemp -d "${TMPDIR:-/tmp}/vpnsh-doctor.XXXXXX")"
	pub="$(ssh_render_fingerprints "$d" >/dev/null 2>&1 && cat "$d/fingerprints")"
	rm -f "$d/fingerprints"; rmdir "$d" 2>/dev/null
	if [ "$pub" = "$(cat "$SSH_GEN_DIR/fingerprints" 2>/dev/null)" ]; then
		dr_ok "確認ダイアログ用の指紋の対応表は接続先と一致"
	else
		dr_warn "確認ダイアログ用の指紋の対応表が接続先と一致しません (登録した鍵のダイアログが出ずに拒否されることがあります)"
		dr_hint "vpnsh ssh add で作り直されます"
	fi
	# 専用 ssh-agent
	pid="$(cat "$SSH_AGENT_DIR/pid" 2>/dev/null)"
	ssh_agent_rc
	case $? in
		0 | 1)
			case "$(ps -o args= -p "${pid:-0}" 2>/dev/null)" in
				*ssh-agent*"-a $SSH_AGENT_SOCK"*) dr_ok "専用 ssh-agent は vpnsh が起動したもので、動いている (メモリの鍵 $(ssh_agent_loaded | grep -c .) 個)" ;;
				*) dr_warn "専用 ssh-agent のソケットに応答するプロセスが、vpnsh の記録 (PID ${pid:-なし}) と一致しません"; dr_hint "vpnsh ssh stop のあと vpnsh ssh add" ;;
			esac ;;
		124) dr_warn "専用 ssh-agent が応答しません (確認ダイアログの表示中の可能性)" ;;
		*) dr_info "専用 ssh-agent は止まっています (vpnsh ssh add で起動します)" ;;
	esac
	# 片付け忘れのシェル用の設定
	stale=0
	for d in "$SSH_GEN_DIR"/s.[0-9]*; do
		[ -d "$d" ] || continue
		kill -0 "${d##*/s.}" 2>/dev/null || stale=$((stale + 1))
	done
	if [ "$stale" -gt 0 ]; then dr_warn "終了したシェルの SSH の設定が ${stale} 個残っています (次の vpnsh --ssh で片付けます)"; fi
	# 最近 (24時間) 拒否した件数
	if [ -f "$VPNSH_STATE_DIR/ssh-audit.log" ]; then
		denies="$(perl -MPOSIX=strftime -ne 'BEGIN { $s = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 86400)) } my @f = split /\t/; $n++ if $f[0] ge $s && $f[1] =~ /^deny/; END { print $n + 0 }' "$VPNSH_STATE_DIR/ssh-audit.log")"
		if [ "$denies" -gt 0 ]; then
			dr_warn "直近24時間に拒否した SSH の要求が ${denies} 件あります (自分で拒否したもの以外に心当たりがなければ注意)"; dr_hint "vpnsh ssh list で内容を確認"
		else
			dr_ok "直近24時間に拒否した SSH の要求はない"
		fi
	fi
}

cmd_doctor() {
	[ "$#" -eq 0 ] || vpnsh_die "使い方: vpnsh doctor" 2
	echo "vpnsh $VPNSH_VERSION の点検 ($VPNSH_ROOT)"
	echo "(通信はせず、vpnsh の確認ダイアログも出しません。直すことはしないので、→ の案内に従ってください。"
	echo " 初めての実行では、macOS がダウンロードや書類のフォルダへのアクセスの許可を求めることがあります)"
	if dr_docker; then
		dr_config
		dr_keychain
		dr_gluetun
		dr_images
		dr_shells
	else
		dr_config
		dr_keychain
	fi
	dr_ssh
	echo
	if [ "$DR_NG" -gt 0 ]; then
		printf '結果: %s、警告 %d 件\n' "$(dr_c 31 "NG $DR_NG 件")" "$DR_WARN"
		return 1
	fi
	printf '結果: NG 0 件、警告 %d 件\n' "$DR_WARN"
	return 0
}
