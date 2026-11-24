#!/bin/bash
# VPNShell: work コンテナの入口
#
#   entrypoint.sh shell              起動前チェック → 対話 bash
#   entrypoint.sh run <cmd> [args]   起動前チェック → コマンドを実行 (終了コードをそのまま返す)
#   entrypoint.sh check              起動前チェックだけ
#   entrypoint.sh full               起動前チェック → 漏れの実地検査 (vpnsh check --full)
#   entrypoint.sh mtu                起動前チェック → MTU の診断 (vpnsh check --mtu)
#   entrypoint.sh observe            setup 用: 照合せず、観測した外部IPを出力
#
# 起動前チェックに失敗したら 125 で終了する (チェックを飛ばす手段は用意しない)
set -u

EXIT_PREFLIGHT=125
BUDGET="${VPNSH_PREFLIGHT_BUDGET:-8}"

# --timing: Mac 側から渡された時刻 (ミリ秒) を起点に、段階ごとの所要時間を出す
# (コンテナの時計は Mac と数ミリ秒ずれることがある)
now_ms() { local t="${EPOCHREALTIME/./}"; printf '%s' "$((t / 1000))"; }
tmark() {
	[ -n "${VPNSH_TIMING:-}" ] && [ -n "${VPNSH_TIMING_T0:-}" ] || return 0
	local now last
	now="$(now_ms)"; last="${VPNSH_TIMING_LAST:-$VPNSH_TIMING_T0}"
	printf 'vpnsh: [時間] %+6d ms (累計 %5d ms)  %s\n' "$((now - last))" "$((now - VPNSH_TIMING_T0))" "$1" >&2
	VPNSH_TIMING_LAST="$now"
	export VPNSH_TIMING_LAST
}
tmark "コンテナの起動 (compose run から入口まで)"

preflight() {
	VPNSH_PREFLIGHT_MODE="$1" timeout --kill-after=1 "$BUDGET" /usr/local/lib/vpnsh/preflight.sh
	local rc=$?
	VPNSH_TIMING_LAST="$(now_ms)"
	if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
		printf 'vpnsh: \033[31m[NG]\033[0m 起動前チェックが %s 秒以内に終わりませんでした\n' "$BUDGET" >&2
	fi
	return "$rc"
}

# --ssh のとき: 中継 (Mac 側から docker exec で起動される) のソケットができるまで少し待つ
ssh_ready() {
	[ "${VPNSH_SSH:-}" = "1" ] || return 0
	mkdir -p /tmp/vpnsh-cm && chmod 0700 /tmp/vpnsh-cm
	local i=0
	while [ ! -S /tmp/vpnsh-agent/agent.sock ] && [ "$i" -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	if [ ! -S /tmp/vpnsh-agent/agent.sock ]; then
		printf 'vpnsh: \033[33m警告:\033[0m SSH エージェントの中継につながりませんでした (ssh は鍵を使えません)\n' >&2
	fi
	return 0
}

cmd="${1:-shell}"
[ "$#" -gt 0 ] && shift

case "$cmd" in
	shell)
		preflight check || exit "$EXIT_PREFLIGHT"
		ssh_ready
		[ "${VPNSH_SSH:-}" = "1" ] && tmark "SSH の中継の待ち合わせ"
		tmark "ここまでの合計 (このあとシェルを起動します)"
		# 設定は /etc/bash.bashrc (ホームには設定ファイルを置かない)
		exec bash -i
		;;
	run)
		preflight check || exit "$EXIT_PREFLIGHT"
		ssh_ready
		[ "${VPNSH_SSH:-}" = "1" ] && tmark "SSH の中継の待ち合わせ"
		[ "$#" -gt 0 ] || { echo "vpnsh: run にコマンドがありません" >&2; exit 2; }
		exec "$@"
		;;
	check)
		preflight check || exit "$EXIT_PREFLIGHT"
		printf 'vpnsh: \033[32m[OK]\033[0m 起動前チェックはすべて成功しました\n' >&2
		exit 0
		;;
	full | mtu)
		preflight check || exit "$EXIT_PREFLIGHT"
		printf 'vpnsh: \033[32m[OK]\033[0m 起動前チェックはすべて成功しました\n' >&2
		/usr/local/lib/vpnsh/diag.sh "$cmd"
		exit $?
		;;
	observe)
		preflight observe || exit "$EXIT_PREFLIGHT"
		exit 0
		;;
	*)
		echo "vpnsh: 不明なモード: $cmd" >&2
		exit 2
		;;
esac
