# shellcheck shell=bash

IDLE_LABEL="local.vpnshell.idle-down"
IDLE_PLIST="$HOME/Library/LaunchAgents/$IDLE_LABEL.plist"
IDLE_INTERVAL=900                          # 確かめる間隔 (秒)
IDLE_LAST="$VPNSH_STATE_DIR/last-active"   # 最後にシェルが開いていた・閉じた時刻 (UNIX 時間)
IDLE_LOG="$VPNSH_STATE_DIR/idle-down.log"

# idle_seconds <値>  "4h" "90m" "1d" を秒に。範囲外や形が違えば失敗 (10分〜7日)
idle_seconds() {
	local v="$1" n u s
	case "$v" in
		*[!0-9mhd]* | "" | [mhd]*) return 1 ;;
	esac
	n="${v%[mhd]}"; u="${v#"$n"}"
	case "$n" in "" | *[!0-9]*) return 1 ;; esac
	case "$u" in m) s=$((n * 60)) ;; h) s=$((n * 3600)) ;; d) s=$((n * 86400)) ;; *) return 1 ;; esac
	[ "$s" -ge 600 ] && [ "$s" -le 604800 ] || return 1
	printf '%s' "$s"
}

# idle_mark_active  いまシェルが開いている・閉じたことを記録する
idle_mark_active() {
	[ -d "$VPNSH_STATE_DIR" ] && date +%s >"$IDLE_LAST" 2>/dev/null
	return 0
}

# idle_plist  LaunchAgent の定義 (vpnsh の場所と docker の場所は、登録したときのもの)
idle_plist() {
	local docker_dir path
	docker_dir="$(dirname "$(command -v docker)")"
	path="/usr/bin:/bin:/usr/sbin:/sbin"
	case ":$path:" in *":$docker_dir:"*) ;; *) path="$docker_dir:$path" ;; esac
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- vpnsh config set idle-down が作成。外すときは vpnsh config set idle-down off -->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$IDLE_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$VPNSH_ROOT/bin/vpnsh</string>
		<string>idle-check</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$path</string>
	</dict>
	<key>StartInterval</key>
	<integer>$IDLE_INTERVAL</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>/dev/null</string>
	<key>StandardErrorPath</key>
	<string>/dev/null</string>
</dict>
</plist>
EOF
}

# idle_loaded  登録されて動いているか
idle_loaded() { launchctl print "gui/$(id -u)/$IDLE_LABEL" >/dev/null 2>&1; }

idle_install() {
	local tmp
	command -v docker >/dev/null 2>&1 || vpnsh_die "docker コマンドが見つかりません"
	case "$VPNSH_ROOT" in *[!A-Za-z0-9._/~+-]*) vpnsh_die "vpnsh の場所に、登録に使えない文字が含まれています: $VPNSH_ROOT" ;; esac
	mkdir -p "$HOME/Library/LaunchAgents" || vpnsh_die "$HOME/Library/LaunchAgents を作れません"
	tmp="$(mktemp "${TMPDIR:-/tmp}/vpnsh-plist.XXXXXX")"
	idle_plist >"$tmp"
	plutil -lint "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; vpnsh_die "定期実行の定義を作れませんでした"; }
	# 登録し直すときは、いったん外してから入れ替える
	idle_loaded && launchctl bootout "gui/$(id -u)/$IDLE_LABEL" >/dev/null 2>&1
	if ! { chmod 0644 "$tmp" && mv -f "$tmp" "$IDLE_PLIST"; }; then rm -f "$tmp"; vpnsh_die "$IDLE_PLIST を書けません"; fi
	launchctl bootstrap "gui/$(id -u)" "$IDLE_PLIST" 2>/dev/null || vpnsh_die "定期実行を登録できませんでした ($IDLE_PLIST)"
	idle_mark_active
}

idle_uninstall() {
	idle_loaded && launchctl bootout "gui/$(id -u)/$IDLE_LABEL" >/dev/null 2>&1
	[ -f "$IDLE_PLIST" ] && rm -f "$IDLE_PLIST"
	return 0
}

# idle_log <メッセージ>  記録 (古くなりすぎないよう 200 行だけ残す)
idle_log() {
	[ -d "$VPNSH_STATE_DIR" ] || return 0
	printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$IDLE_LOG"
	if [ "$(wc -l <"$IDLE_LOG" 2>/dev/null)" -gt 200 ]; then
		tail -n 200 "$IDLE_LOG" >"$IDLE_LOG.tmp" && mv -f "$IDLE_LOG.tmp" "$IDLE_LOG"
	fi
}

# cmd_idle_check  LaunchAgent から呼ばれる (手で実行してもよい)。何も聞かず、端末にも出さない
cmd_idle_check() {
	local limit last started now n r
	limit="$(idle_seconds "$(vpnsh_env_get VPNSH_IDLE_DOWN)")" || return 0
	gl_inspect; r=$?
	[ "$r" -eq 0 ] || return 0                      # gluetun が無い、または Docker に届かない
	[ "$GL_STATUS" = "running" ] || return 0
	# 持ち主のいないシェルは片付ける。動いているシェル (と判定できないもの) があれば、使っているとみなす
	gc_orphans >/dev/null 2>&1
	n="$(work_list | grep -cv ' orphan$')"
	if [ "$n" -gt 0 ]; then
		idle_mark_active
		return 0
	fi
	now="$(date +%s)"
	last="$(cat "$IDLE_LAST" 2>/dev/null)"
	case "$last" in "" | *[!0-9]*) last=0 ;; esac
	# 一度もシェルを開いていなければ、gluetun が起動した時刻から数える
	started="$(vpnsh_docker inspect -f '{{.State.StartedAt}}' "$VPNSH_GLUETUN_NAME" 2>/dev/null |
		perl -MTime::Local -ne 'print timegm($6, $5, $4, $3, $2 - 1, $1) if /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/')"
	case "$started" in "" | *[!0-9]*) started=0 ;; esac
	[ "$started" -gt "$last" ] && last="$started"
	[ "$last" -gt 0 ] || return 0
	[ $((now - last)) -ge "$limit" ] || return 0
	idle_log "シェルを $(((now - last) / 60)) 分使っていないので、gluetun を破棄します (idle-down $(vpnsh_env_get VPNSH_IDLE_DOWN))"
	VPNSH_YES=1 cmd_down >>"$IDLE_LOG" 2>&1
	idle_log "破棄しました (終了コード $?)"
}
