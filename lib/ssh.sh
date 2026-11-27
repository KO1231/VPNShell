# shellcheck shell=bash
# shellcheck disable=SC2119,SC2120  # ssh_render_fingerprints の出力先は省略できる (doctor だけが指定する)

SSH_HOSTS_FILE="$VPNSH_STATE_DIR/hosts"
SSH_KNOWN_HOSTS="$VPNSH_STATE_DIR/known_hosts"
SSH_GEN_DIR="$VPNSH_STATE_DIR/ssh"
SSH_AGENT_DIR="$VPNSH_STATE_DIR/agent"
SSH_AGENT_SOCK="$SSH_AGENT_DIR/agent.sock"
SSH_KEY_LIFETIME="8h"
SSH_KEY_LIFETIME_SECS=28800
# shellcheck disable=SC2034  # bin/vpnsh が参照する (コンテナ内の中継のソケット)
SSH_IN_SOCK="/tmp/vpnsh-agent/agent.sock"

# ---- state/hosts ----
# 書式: <名前> <HostName> <ポート> <ユーザー> <秘密鍵のパス> (1行に1台。vpnsh ssh host add が書く)

# ssh_key_path_ok <絶対パス>  鍵のパスとして使えるか (空白・#・制御文字を含まない絶対パス)
ssh_key_path_ok() {
	case "$1" in /*) ;; *) return 1 ;; esac
	printf '%s' "$1" | LC_ALL=C grep -q '[[:space:]#[:cntrl:]]' && return 1
	return 0
}

# ssh_hosts  検証済みの行を「名前 HostName ポート ユーザー 鍵の絶対パス」で出す。不正な行があれば 1
ssh_hosts() {
	[ -f "$SSH_HOSTS_FILE" ] || return 0
	VPNSH_HOME="$HOME" perl -ne '
		BEGIN { $bad = 0 }
		chomp; next if /^\s*(#|$)/;
		my @f = split /\s+/, $_; shift @f if @f && $f[0] eq "";
		my $n = $.;
		sub e { print STDERR "vpnsh: エラー: 接続先の設定 ($_[0] 行目): $_[1]\n"; $bad = 1 }
		if (@f != 5) { e($n, "項目は5つ (名前 HostName ポート ユーザー 秘密鍵) です"); next }
		my ($name, $host, $port, $user, $key) = @f;
		if ($name !~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/) { e($n, "名前が不正です: $name"); next }
		if ($host !~ /\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\z/) { e($n, "HostName が不正です: $host"); next }
		if ($port !~ /\A[0-9]{1,5}\z/ || $port < 1 || $port > 65535) { e($n, "ポートが不正です: $port"); next }
		if ($user !~ /\A[A-Za-z_][A-Za-z0-9_.-]{0,31}\z/) { e($n, "ユーザーが不正です: $user"); next }
		$key =~ s{\A~/}{$ENV{VPNSH_HOME}/};
		if ($key !~ m{\A/} || $key =~ /[#[:cntrl:]]/) { e($n, "秘密鍵のパスが不正です: $key"); next }
		print "$name $host $port $user $key\n";
		END { exit $bad }
	' "$SSH_HOSTS_FILE"
}

# ssh_host_line <名前>  その名前の行を出す (無ければ 1)
ssh_host_line() {
	local all
	all="$(ssh_hosts)" || return 1
	printf '%s\n' "$all" | awk -v n="$1" '$1 == n { print; found = 1; exit } END { exit !found }'
}

# ssh_kh_name <HostName> <ポート>  known_hosts での書き方 (22 以外は [host]:port)
ssh_kh_name() { if [ "$2" = "22" ]; then printf '%s' "$1"; else printf '[%s]:%s' "$1" "$2"; fi; }

# ssh_has_known_host <HostName> <ポート>
ssh_has_known_host() {
	[ -f "$SSH_KNOWN_HOSTS" ] || return 1
	ssh-keygen -F "$(ssh_kh_name "$1" "$2")" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1
}

# ssh_fp <鍵のパス>  公開鍵 (.pub) の指紋
ssh_fp() { ssh-keygen -lf "$1.pub" 2>/dev/null | awk '{print $2}'; }

# ---- 専用 ssh-agent ----
# ssh_agent_rc  0=鍵あり / 1=鍵なし / 2=動いていない / 124=応答なし
ssh_agent_rc() {
	[ -S "$SSH_AGENT_SOCK" ] || return 2
	SSH_AUTH_SOCK="$SSH_AGENT_SOCK" vpnsh_timeout 3 /usr/bin/ssh-add -l >/dev/null 2>&1
}

# ssh_agent_loaded  メモリにある鍵の指紋を1行ずつ出す
ssh_agent_loaded() {
	[ -S "$SSH_AGENT_SOCK" ] || return 0
	SSH_AUTH_SOCK="$SSH_AGENT_SOCK" vpnsh_timeout 3 /usr/bin/ssh-add -l 2>/dev/null | awk '$2 ~ /^SHA256:/ {print $2}'
}

ssh_agent_start() {
	local rc out pid lk i=0
	ssh_agent_rc; rc=$?
	[ "$rc" -eq 2 ] || return 0
	mkdir -p "$SSH_AGENT_DIR" && chmod 0700 "$SSH_AGENT_DIR"
	# 起動の部分だけロックする (30秒より古いロックは残骸とみなす)
	lk="$SSH_AGENT_DIR/start.lock"
	while ! mkdir "$lk" 2>/dev/null; do
		if [ $(($(date +%s) - $(stat -f %m "$lk" 2>/dev/null || date +%s))) -ge 30 ]; then rmdir "$lk" 2>/dev/null; continue; fi
		i=$((i + 1)); [ "$i" -gt 40 ] && { vpnsh_err "専用 ssh-agent の起動を待ちきれません ($lk)"; return 1; }
		sleep 0.25
	done
	# 待っている間に別の vpnsh が起動していれば、それを使う
	ssh_agent_rc; rc=$?
	if [ "$rc" -ne 2 ]; then rmdir "$lk"; return 0; fi
	rm -f "$SSH_AGENT_SOCK"
	# 確認ダイアログ用の環境変数は、この ssh-agent にだけ与える (env -i で他の値も持ち込まない)
	out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
		SSH_ASKPASS="$VPNSH_ROOT/scripts/ssh-askpass" SSH_ASKPASS_REQUIRE=force \
		VPNSH_STATE_DIR="$VPNSH_STATE_DIR" \
		/usr/bin/ssh-agent -s -a "$SSH_AGENT_SOCK" -P none 2>&1)" || { rmdir "$lk"; vpnsh_err "専用 ssh-agent を起動できません: $out"; return 1; }
	pid="$(printf '%s\n' "$out" | sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p')"
	[ -n "$pid" ] && printf '%s\n' "$pid" >"$SSH_AGENT_DIR/pid"
	: >"$SSH_AGENT_DIR/added"
	rmdir "$lk"
	vpnsh_verbose "専用 ssh-agent を起動しました (PID ${pid:-?})"
	return 0
}

# ssh_agent_stop  専用 ssh-agent を止める (コマンドラインに自分のソケットのパスがあるものだけ)
ssh_agent_stop() {
	local pid args
	pid="$(cat "$SSH_AGENT_DIR/pid" 2>/dev/null)"
	if [ -n "$pid" ]; then
		args="$(ps -o args= -p "$pid" 2>/dev/null)"
		case "$args" in
			*ssh-agent*"-a $SSH_AGENT_SOCK"*) kill "$pid" 2>/dev/null ;;
		esac
	fi
	rm -f "$SSH_AGENT_SOCK" "$SSH_AGENT_DIR/pid" "$SSH_AGENT_DIR/added"
	return 0
}

# ssh_added_names <指紋>  その鍵を登録したときに縛った接続先の名前 (カンマ区切り)
ssh_added_names() { awk -F '\t' -v f="$1" '$1 == f { n = $3 } END { print n }' "$SSH_AGENT_DIR/added" 2>/dev/null; }
# ssh_added_time <指紋>
ssh_added_time() { awk -F '\t' -v f="$1" '$1 == f { t = $2 } END { print t }' "$SSH_AGENT_DIR/added" 2>/dev/null; }

# ssh_add [名前...]  鍵を専用 ssh-agent に登録する (その鍵を使うすべての接続先をまとめて縛る)
ssh_add() {
	local all lines key dests names line name host port user k kh fp missing=0 nk=0
	all="$(ssh_hosts)" || return 1
	[ -n "$all" ] || { vpnsh_err "SSH の接続先がありません。vpnsh ssh host add <~/.ssh/config の Host> で追加してください"; return 1; }
	if [ "$#" -gt 0 ]; then
		lines=""
		for name in "$@"; do
			line="$(printf '%s\n' "$all" | awk -v n="$name" '$1 == n')"
			[ -n "$line" ] || { vpnsh_err "接続先 $name はありません (一覧は vpnsh ssh list -a、追加は vpnsh ssh host add $name)"; return 1; }
			lines="$lines$line
"
		done
	else
		lines="$all"
	fi
	# 指定した接続先のホスト鍵と公開鍵を確かめる (-h はホスト鍵が無いと登録できない)
	while read -r name host port user k; do
		[ -n "$name" ] || continue
		if ! ssh_has_known_host "$host" "$port"; then
			vpnsh_err "$name ($host:$port) のホスト鍵がまだ保存されていません。先に \`vpnsh trust-host $name\` を実行してください"
			missing=1
		fi
		[ -f "$k" ] || { vpnsh_err "$name の秘密鍵がありません: $k"; missing=1; }
		[ -f "$k.pub" ] || { vpnsh_err "$name の公開鍵がありません: $k.pub"; missing=1; }
	done <<EOF
$lines
EOF
	[ "$missing" -eq 0 ] || return 1
	ssh_agent_start || return 1
	mkdir -p "$SSH_GEN_DIR" && chmod 0700 "$SSH_GEN_DIR"
	ssh_render_fingerprints
	# 鍵ごとに、その鍵を使うすべての接続先 (ホスト鍵が保存済みのもの) を並べて登録する
	for key in $(printf '%s\n' "$lines" | awk 'NF { print $5 }' | sort -u); do
		dests=(); names=""
		while read -r name host port user k; do
			[ "$k" = "$key" ] || continue
			if ! ssh_has_known_host "$host" "$port"; then
				vpnsh_warn "$name は同じ鍵を使いますが、ホスト鍵が未保存なので今回は縛りに含めません (vpnsh trust-host $name の後に ssh add し直してください)"
				continue
			fi
			kh="$(ssh_kh_name "$host" "$port")"
			dests+=(-h "$user@$kh")
			names="$names${names:+,}$name"
		done <<EOF
$all
EOF
		vpnsh_info "読み込み: $(mnt_display "$key" 2>/dev/null || printf '%s' "$key") (使える接続先: ${names//,/, })"
		if ! SSH_AUTH_SOCK="$SSH_AGENT_SOCK" /usr/bin/ssh-add -c -t "$SSH_KEY_LIFETIME" -H "$SSH_KNOWN_HOSTS" "${dests[@]}" "$key"; then
			vpnsh_err "$key を登録できませんでした"
			return 1
		fi
		fp="$(ssh_fp "$key")"
		[ -n "$fp" ] && printf '%s\t%s\t%s\n' "$fp" "$(date +%s)" "$names" >>"$SSH_AGENT_DIR/added"
		nk=$((nk + 1))
	done
	vpnsh_info "${nk} 個の鍵をメモリに読み込みました。${SSH_KEY_LIFETIME} で期限切れになります。使うたびに Mac に確認ダイアログが出ます"
	vpnsh_info "次は: vpnsh --ssh でシェルに入り、ssh <名前> や git clone <名前>:<パス> を実行してください"
}

# ssh_render_fingerprints [出力先のディレクトリ]  確認ダイアログ用の「指紋 → 名前 (ユーザー@接続先)」の対応表を作る
ssh_render_fingerprints() {
	local all name host port user k fp tmp out="${1:-$SSH_GEN_DIR}"
	all="$(ssh_hosts)" || return 1
	mkdir -p "$out" && chmod 0700 "$out"
	tmp="$out/fingerprints.tmp.$$"
	: >"$tmp"
	while read -r name host port user k; do
		[ -n "$name" ] || continue
		fp="$(ssh_fp "$k")"
		[ -n "$fp" ] && printf '%s %s (%s@%s:%s)\n' "$fp" "$name" "$user" "$host" "$port" >>"$tmp"
	done <<EOF
$all
EOF
	mv -f "$tmp" "$out/fingerprints"
}

# ssh_list [-a|--all]  メモリにある鍵 (-a: 登録したすべての接続先) と、直近の確認ダイアログの結果を出す
ssh_list() {
	local all="" rc loaded="" now fp t names hosts name host port user k known state shown
	case "${1:-}" in -a | --all) all=1 ;; "") ;; *) vpnsh_die "使い方: vpnsh ssh list [-a|--all]" 2 ;; esac
	now="$(date +%s)"
	[ -f "$SSH_GEN_DIR/fingerprints" ] || ssh_render_fingerprints >/dev/null 2>&1
	ssh_agent_rc; rc=$?
	case "$rc" in
		2) echo "専用 ssh-agent: 動いていません (vpnsh ssh add で起動します)" ;;
		124) echo "専用 ssh-agent: 応答がありません (確認ダイアログの表示中かもしれません)" ;;
		1) echo "専用 ssh-agent: 動いています (メモリにある鍵はありません。期限切れの可能性があります)" ;;
		0) echo "専用 ssh-agent: 動いています"; loaded="$(ssh_agent_loaded)" ;;
	esac
	# 期限までの残り (登録した時刻から計算する)
	remaining() {
		t="$(ssh_added_time "$1")"
		if [ -n "$t" ]; then echo "残り約 $(( (t + SSH_KEY_LIFETIME_SECS - now) / 60 )) 分"; else echo "残り不明"; fi
	}
	if [ -z "$all" ]; then
		if [ -z "$loaded" ]; then
			echo "メモリにある鍵はありません (vpnsh ssh add で読み込みます。登録した接続先は vpnsh ssh list -a で表示)"
		else
			echo "メモリにある鍵:"
			{
				printf '%s\t%s\t%s\n' "使える接続先" "期限" "指紋"
				while IFS= read -r fp; do
					[ -n "$fp" ] || continue
					names="$(ssh_added_names "$fp")"
					printf '%s\t%s\t%s\n' "${names:-(なし)}" "$(remaining "$fp")" "$fp"
				done <<EOF
$loaded
EOF
			} | vpnsh_table "  "
		fi
	else
		hosts="$(ssh_hosts)" || return 1
		if [ -z "$hosts" ]; then
			echo "登録した接続先はありません (vpnsh ssh host add <~/.ssh/config の Host> で追加します)"
		else
			echo "登録した接続先:"
			shown=""
			{
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' "名前" "接続先" "ユーザー" "ホスト鍵" "鍵 (メモリ)" "鍵ファイル"
			while read -r name host port user k; do
				[ -n "$name" ] || continue
				known="未保存"; ssh_has_known_host "$host" "$port" && known="保存済み"
				fp="$(ssh_fp "$k")"
				state="なし"
				# メモリにあり、かつ登録したときにこの接続先に縛ったものだけ「あり」
				if [ -n "$fp" ] && printf '%s\n' "$loaded" | grep -qxF "$fp"; then
					case ",$(ssh_added_names "$fp")," in
						*",$name,"*) state="あり ($(remaining "$fp"))" ;;
						*) state="なし (この接続先に未対応。ssh add し直す)" ;;
					esac
					shown="$shown$fp
"
				fi
				# shellcheck disable=SC2088  # 表示用に "~/" で書く
				case "$k" in "$HOME"/*) k="~/${k#"$HOME"/}" ;; esac
				printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$host:$port" "$user" "$known" "$state" "$k"
			done <<EOF
$hosts
EOF
			# メモリにあるが、どの接続先でも使っていない鍵 (接続先を取り除いた後など)
			while IFS= read -r fp; do
				[ -n "$fp" ] || continue
				printf '%s' "$shown" | grep -qxF "$fp" && continue
				printf '%s\t%s\t%s\t%s\t%s\t%s\n' "(なし)" "-" "-" "-" "あり ($(remaining "$fp"))" "$fp"
			done <<EOF
$loaded
EOF
			} | vpnsh_table "  "
		fi
	fi
	if [ -s "$VPNSH_STATE_DIR/ssh-audit.log" ]; then
		echo "直近の確認ダイアログの結果:"
		tail -n 5 "$VPNSH_STATE_DIR/ssh-audit.log" | vpnsh_sanitize | sed 's/^/  /'
	fi
}

# ---- シェルごとの設定 (コンテナにマウントする) ----
# 生成物はシェルごとのディレクトリ (state/ssh/s.<PID>) に作り、終了時に消す

# ssh_session_dir <PID>
ssh_session_dir() { printf '%s' "$SSH_GEN_DIR/s.$1"; }

# ssh_render_session <ディレクトリ> [接続先の一覧]  ssh_config・公開鍵 (.pub だけ)・known_hosts を作る
ssh_render_session() {
	local dir="$1" all="${2:-}" name host port user k cm
	[ -n "$all" ] || all="$(ssh_hosts)" || return 1
	mkdir -p "$SSH_GEN_DIR" && chmod 0700 "$SSH_GEN_DIR"
	mkdir -p "$dir/keys" || return 1
	cm="auto"
	case "$(vpnsh_env_get VPNSH_SSH_CONTROL_MASTER)" in no | off | false | 0) cm="no" ;; esac
	{
		echo "# vpnsh が登録した接続先から生成した設定 (このシェル専用。シェルの終了時に消えます)"
		echo "# ここにある値は既定値です。シェルの中のコードは ~/.ssh/config や ssh -o で変えられます"
		echo "Host *"
		echo "    ForwardAgent no"
		echo "    IdentityAgent SSH_AUTH_SOCK"
		echo "    IdentitiesOnly yes"
		echo "    GlobalKnownHostsFile /dev/null"
		echo "    UserKnownHostsFile ~/.ssh/known_hosts /etc/vpnsh/ssh/known_hosts"
		echo "    ControlMaster $cm"
		echo "    ControlPath /tmp/vpnsh-cm/%C"
		echo "    ControlPersist 10m"
		echo "    ServerAliveInterval 30"
		echo "    ServerAliveCountMax 3"
		while read -r name host port user k; do
			[ -n "$name" ] || continue
			cp "$k.pub" "$dir/keys/$name.pub" 2>/dev/null || { vpnsh_err "$name の公開鍵がありません: $k.pub"; return 1; }
			chmod 0644 "$dir/keys/$name.pub"
			echo ""
			echo "Host $name $host"
			echo "    HostName $host"
			echo "    Port $port"
			echo "    User $user"
			echo "    IdentityFile /etc/vpnsh/ssh/keys/$name"
		done <<EOF
$all
EOF
	} >"$dir/config" || return 1
	if [ -f "$SSH_KNOWN_HOSTS" ]; then cp "$SSH_KNOWN_HOSTS" "$dir/known_hosts"; else : >"$dir/known_hosts"; fi
	chmod 0644 "$dir/config" "$dir/known_hosts"
	chmod 0755 "$dir" "$dir/keys"
	return 0
}

# ssh_session_remove <ディレクトリ>  (名前を指定して消す)
ssh_session_remove() {
	local dir="$1" f
	case "$dir" in "$SSH_GEN_DIR"/s.[0-9]*) ;; *) return 0 ;; esac
	[ -d "$dir" ] || return 0
	for f in "$dir"/keys/*.pub; do [ -f "$f" ] && rm -f "$f"; done
	rmdir "$dir/keys" 2>/dev/null
	rm -f "$dir/config" "$dir/known_hosts"
	rmdir "$dir" 2>/dev/null
	return 0
}

# ssh_session_gc  持ち主の vpnsh がもういないシェルの設定を消す
ssh_session_gc() {
	local d pid
	for d in "$SSH_GEN_DIR"/s.[0-9]*; do
		[ -d "$d" ] || continue
		pid="${d##*/s.}"
		kill -0 "$pid" 2>/dev/null && continue
		ssh_session_remove "$d"
	done
	return 0
}

# ssh_kh_saved <known_hosts の名前>  保存済みのホスト鍵 (種類と鍵) を1行ずつ出す
ssh_kh_saved() {
	[ -f "$SSH_KNOWN_HOSTS" ] || return 0
	grep -v '^#' "$SSH_KNOWN_HOSTS" | awk -v h="$1" '$1 == h { $1 = ""; sub(/^ /, ""); print }'
}

# ssh_kh_compare <ホスト> <ポート> <取得した行>  保存済みのホスト鍵と比べて new / same / partial / different を出す
ssh_kh_compare() {
	local saved
	ssh_has_known_host "$1" "$2" || { echo new; return 0; }
	saved="$(ssh_kh_saved "$(ssh_kh_name "$1" "$2")")"
	if printf '%s\n' "$3" | cut -d' ' -f2- | sort | cmp -s - <(printf '%s\n' "$saved" | sort); then
		echo same
	elif printf '%s\n' "$3" | cut -d' ' -f2- | grep -qxF -f <(printf '%s\n' "$saved"); then
		echo partial
	else
		echo different
	fi
}

# ssh_kh_replace <ホスト> <ポート> <取得した行>  その接続先の保存済みのホスト鍵を、取得した行で置き換える
ssh_kh_replace() {
	local kh
	kh="$(ssh_kh_name "$1" "$2")"
	if [ -f "$SSH_KNOWN_HOSTS" ]; then
		ssh-keygen -R "$kh" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1
		rm -f "$SSH_KNOWN_HOSTS.old"
	fi
	printf '%s\n' "$3" >>"$SSH_KNOWN_HOSTS"
	chmod 0600 "$SSH_KNOWN_HOSTS"
}

# ssh_valid_keyscan_line <行> <known_hosts での名前>  ssh-keyscan の出力として正しい、接続先の行か
ssh_valid_keyscan_line() {
	local first="${1%% *}"
	[ "$first" = "$2" ] || return 1
	printf '%s' "$1" | grep -Eq '^(\[[A-Za-z0-9.-]+\]:[0-9]+|[A-Za-z0-9.-]+) (ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}$'
}

# ---- ~/.ssh/config からの登録 (vpnsh ssh host add) ----
# ssh -G で、その Host に適用される設定を Mac 側で読む (Match exec があるとそのコマンドが実行される)
# shellcheck disable=SC2088  # ssh -G が出力するそのままの文字列と比べる
SSH_DEFAULT_IDS="~/.ssh/id_rsa ~/.ssh/id_ecdsa ~/.ssh/id_ecdsa_sk ~/.ssh/id_ed25519 ~/.ssh/id_ed25519_sk ~/.ssh/id_mldsa44_ed25519 ~/.ssh/id_xmss ~/.ssh/id_dsa"

# ssh_cfg_args  テストのときだけ別の設定ファイルを使う (bin/vpnsh はこの変数を消してから読み込む)
ssh_cfg_args() { [ -n "${VPNSH_TEST_SSH_CONFIG:-}" ] && printf '%s\n' -F "$VPNSH_TEST_SSH_CONFIG"; return 0; }

# shellcheck disable=SC2034  # SR_* は呼び出し側 (bin/vpnsh) が使う
# ssh_resolve <Host名>  SR_HOST / SR_PORT / SR_USER / SR_IDS / SR_IDS_DEFAULT / SR_PROXY / SR_INCONFIG を設定する
ssh_resolve() {
	local alias="$1" out probe_out probe args=() line k v ids="" raw_ids=""
	while IFS= read -r line; do [ -n "$line" ] && args+=("$line"); done <<EOT
$(ssh_cfg_args)
EOT
	out="$(/usr/bin/ssh -G ${args[@]+"${args[@]}"} -- "$alias" </dev/null 2>/dev/null)" || { vpnsh_err "ssh -G $alias を実行できません (~/.ssh/config の書き方を確認してください)"; return 1; }
	# Host があるかは、存在しない名前を読んだ結果と比べて判定する
	probe="vpnsh-probe-$$-$RANDOM"
	probe_out="$(/usr/bin/ssh -G ${args[@]+"${args[@]}"} -- "$probe" </dev/null 2>/dev/null)"
	SR_INCONFIG=1
	if [ "$(printf '%s\n' "$out" | grep -v -e '^host ' -e '^hostname ')" = "$(printf '%s\n' "$probe_out" | grep -v -e '^host ' -e '^hostname ')" ] &&
		[ "$(printf '%s\n' "$out" | sed -n 's/^hostname //p')" = "$(printf '%s' "$alias" | tr '[:upper:]' '[:lower:]')" ]; then
		SR_INCONFIG=0
	fi
	SR_HOST=""; SR_PORT=""; SR_USER=""; SR_PROXY=""
	while IFS= read -r line; do
		k="${line%% *}"; v="${line#* }"
		case "$k" in
			hostname) SR_HOST="$v" ;;
			port) SR_PORT="$v" ;;
			user) SR_USER="$v" ;;
			identityfile)
				raw_ids="$raw_ids${raw_ids:+ }$v"
				# shellcheck disable=SC2088  # ssh -G の出力の "~/" を $HOME に置き換える
				case "$v" in "~/"*) v="$HOME/${v#\~/}" ;; esac
				ids="$ids$v
" ;;
			proxyjump | proxycommand) [ "$v" != "none" ] && SR_PROXY="$SR_PROXY$k $v; " ;;
		esac
	done <<EOT
$out
EOT
	SR_IDS="${ids%
}"
	# IdentityFile が2つ以上あり、すべて既定の名前なら「書いていない」とみなす
	SR_IDS_DEFAULT=0
	local cnt=0 all_default=1 f
	for f in $raw_ids; do
		cnt=$((cnt + 1))
		case " $SSH_DEFAULT_IDS " in *" $f "*) ;; *) all_default=0 ;; esac
	done
	[ "$cnt" -ge 2 ] && [ "$all_default" = "1" ] && SR_IDS_DEFAULT=1
	return 0
}

# ssh_hosts_put <名前> <HostName> <ポート> <ユーザー> <鍵>  検証してから state/hosts に書く (同じ名前の行は置き換える)
ssh_hosts_put() {
	local tmp="$SSH_HOSTS_FILE.tmp.$$" keyshow="$5"
	ssh_key_path_ok "$5" || { vpnsh_err "秘密鍵のパスに空白・#・制御文字は使えません: $5"; return 1; }
	# shellcheck disable=SC2088  # 表示用 (state/hosts) に "~/" のまま書く
	case "$keyshow" in "$HOME"/*) keyshow="~/${keyshow#"$HOME"/}" ;; esac
	{
		if [ -f "$SSH_HOSTS_FILE" ]; then
			awk -v n="$1" '{ split($0, f, /[ \t]+/); if (f[1] != n) print }' "$SSH_HOSTS_FILE"
		else
			echo "# vpnsh ssh host add が書きます (名前 HostName ポート ユーザー 秘密鍵)。手で編集しないでください"
		fi
		printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$keyshow"
	} >"$tmp" || { rm -f "$tmp"; return 1; }
	chmod 0600 "$tmp"
	if ! SSH_HOSTS_FILE="$tmp" ssh_hosts >/dev/null; then
		rm -f "$tmp"
		vpnsh_err "接続先の設定を書けませんでした (値が不正です)"
		return 1
	fi
	mv -f "$tmp" "$SSH_HOSTS_FILE"
}

# ssh_hosts_del <名前>
ssh_hosts_del() {
	local tmp="$SSH_HOSTS_FILE.tmp.$$"
	[ -f "$SSH_HOSTS_FILE" ] || return 0
	awk -v n="$1" '{ split($0, f, /[ \t]+/); if (f[1] != n) print }' "$SSH_HOSTS_FILE" >"$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$SSH_HOSTS_FILE"
}
