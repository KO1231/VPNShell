# shellcheck shell=bash

# ロックのディレクトリに「PID 開始時刻」を書き、持ち主がもう無ければ mv で別名にしてから消して奪う
LOCK_DIR=""
LOCK_HELD=""
lock_acquire() {
	ensure_state_dir
	LOCK_DIR="$VPNSH_STATE_DIR/lock"
	local i=0 owner pid start me
	me="$$ $(vpnsh_proc_start $$)"
	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		owner="$(cat "$LOCK_DIR/owner" 2>/dev/null)"
		pid="${owner%% *}"; start="${owner#* }"
		# 持ち主が書かれていないロックは、作られてから 10 秒たっていれば残骸とみなす
		local empty_stale=""
		if [ -z "$owner" ] && [ -d "$LOCK_DIR" ] && [ $(($(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || date +%s))) -ge 10 ]; then
			empty_stale=1
		fi
		if [ -n "$empty_stale" ] || { [ -n "$owner" ] && { ! kill -0 "$pid" 2>/dev/null || [ "$(vpnsh_proc_start "$pid")" != "$start" ]; }; }; then
			local stale="$VPNSH_STATE_DIR/lock.stale.$$"
			if mv "$LOCK_DIR" "$stale" 2>/dev/null; then
				if [ "$(cat "$stale/owner" 2>/dev/null)" = "$owner" ]; then
					vpnsh_warn "前回の vpnsh (PID ${pid:-不明}) が残したロックを解除しました"
					rm -f "$stale/owner"; rmdir "$stale" 2>/dev/null
				elif [ ! -e "$LOCK_DIR" ]; then
					# 別の vpnsh が先に取り直していた → 元に戻す (その間に3つ目が取っていれば、入れ子にしないよう戻さない)
					mv "$stale" "$LOCK_DIR" 2>/dev/null
				fi
			fi
			continue
		fi
		i=$((i + 1))
		[ "$i" -eq 1 ] && vpnsh_info "別の vpnsh (PID ${pid:-?}) が gluetun を操作中です。終わるのを待っています…"
		[ "$i" -gt 240 ] && vpnsh_die "ロックを取得できません。ほかの vpnsh が動いていないことを確かめてから、$LOCK_DIR を削除してください"
		sleep 0.5
	done
	if ! echo "$me" >"$LOCK_DIR/owner" 2>/dev/null; then
		rmdir "$LOCK_DIR" 2>/dev/null
		vpnsh_die "ロックを作れません (${LOCK_DIR}。ディスクの空きを確かめてください)"
	fi
	LOCK_HELD=1
}
lock_release() {
	if [ -n "$LOCK_HELD" ] && [ -n "$LOCK_DIR" ] && [ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$$ $(vpnsh_proc_start $$)" ]; then
		rm -f "$LOCK_DIR/owner"; rmdir "$LOCK_DIR" 2>/dev/null
	fi
	LOCK_HELD=""
}
