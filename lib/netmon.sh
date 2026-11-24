# shellcheck shell=bash
# VPN の通信の監視 (Mac 側)
#
# 対話シェル (vpnsh / vpnsh shell) を開いている間、Mac 上の vpnsh のプロセスが一定の間隔で
# gluetun の中から ping を送り (トンネル越しに 1.1.1.1、だめなら 8.8.8.8)、通信できなくなったら・戻ったら、
# そのターミナルに直接メッセージを出す (Enter を押さなくても表示される)。
#
# - Mac 上のプロセスなので、コンテナの中のコードからは止めたり書き換えたりできない
#   (ただし、コンテナの中のコードは端末に偽のメッセージを出せる。これは防げない)
# - 表示のための補助であり、遮断は gluetun のファイアウォールが行う
# - gluetun 自身のヘルスチェックは、1分ごとの確認と約2分のやり直しのあとでないと不調にならないので、
#   それを待たずに自分で確かめる

NETMON_INTERVAL=10     # 確かめる間隔 (秒)
NETMON_FAILS=2         # 続けて何回失敗したら「通信できません」を出すか
NETMON_PID=""

# netmon_probe <gluetun の ID>  0=通信できる / 1=できない / 2=gluetun が無い (作り直された・破棄された)
netmon_probe() {
	local err rc
	err="$(vpnsh_timeout 8 docker --context "$VPNSH_CONTEXT" exec "$1" \
		sh -c 'ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1' 2>&1 >/dev/null)"
	rc=$?
	[ "$rc" -eq 0 ] && return 0
	case "$err" in *"No such container"*) return 2 ;; esac
	return 1
}

# netmon_say <色> <メッセージ> <出力先>  端末に1行出す (docker の端末は生のモードなので \r\n で改行する)
netmon_say() {
	printf '\r\n\033[%sm vpnsh: %s \033[0m\r\n' "$1" "$2" >>"$3" 2>/dev/null
}

# netmon_loop <gluetun の ID> <持ち主の PID> [出力先]  状態が変わったときだけメッセージを出す
netmon_loop() {
	local id="$1" owner="$2" out="${3:-/dev/tty}" state=ok fails=0 r sp=""
	trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM HUP INT
	while :; do
		sleep "$NETMON_INTERVAL" &
		sp=$!
		wait "$sp"
		sp=""
		# 持ち主の vpnsh が終わっていたら、監視も終わる
		kill -0 "$owner" 2>/dev/null || exit 0
		netmon_probe "$id"; r=$?
		case "$r" in
			0)
				fails=0
				if [ "$state" = "down" ]; then
					netmon_say '42;30' "VPN の通信が戻りました" "$out"
					state=ok
				fi
				;;
			2)
				netmon_say '41;97' "gluetun が作り直されたか破棄されました。このシェルは通信できません (exit して vpnsh を再実行してください)" "$out"
				exit 0
				;;
			*)
				fails=$((fails + 1))
				if [ "$state" = "ok" ] && [ "$fails" -ge "$NETMON_FAILS" ]; then
					netmon_say '43;30' "VPN で通信できません (遮断は有効)。Mac のネットワーク (Wi-Fi など) を確認してください。戻ったらお知らせします" "$out"
					state=down
				fi
				;;
		esac
	done
}

# netmon_start <gluetun の ID>  バックグラウンドで監視を始める (端末があるときだけ)
netmon_start() {
	[ -n "$1" ] || return 0
	[ -t 1 ] && [ -w /dev/tty ] || return 0
	netmon_loop "$1" "$$" </dev/null >/dev/null 2>&1 &
	NETMON_PID=$!
	# bash のジョブの一覧から外す (止めたときに「Terminated」と出さない。止めるのを待つこともしない)
	disown "$NETMON_PID" 2>/dev/null
}
netmon_stop() {
	[ -n "$NETMON_PID" ] && kill "$NETMON_PID" 2>/dev/null
	NETMON_PID=""
	return 0
}
