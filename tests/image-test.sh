#!/bin/bash
# shellcheck disable=SC2015  # ok / ng は常に 0 を返すので A && B || C で問題ない
# shellcheck disable=SC2016  # コンテナの中で展開させる文字列なので、わざと単一引用符にしている
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
IMAGE="vpnshell-work:local"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$*"; }
ng() { FAIL=$((FAIL + 1)); printf '  \033[31mNG\033[0m   %s\n' "$*"; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "$IMAGE がありません (vpnsh build でビルドしてください)" >&2; exit 1; }

# compose.yaml の work と同じ制限で動かす
run() {
	docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
		--security-opt "seccomp=$ROOT/templates/seccomp-work.json" --read-only \
		--tmpfs /tmp:rw,nosuid,nodev,exec,size=64m --tmpfs /var/tmp:rw,nosuid,nodev,exec,size=16m \
		-v /home/vpnsh "$@"
}

echo "== work イメージの固さ"
out="$(run --entrypoint sh "$IMAGE" -c 'echo "suid=$(find / -xdev -perm /6000 -type f 2>/dev/null | wc -l) caps=$(getcap -r / 2>/dev/null | wc -l)"')"
[ "$out" = "suid=0 caps=0" ] && ok "setuid / setgid とファイル capability が無い" || ng "setuid / capability が残っている: $out"

probe='w=""; for d in / /etc /usr/bin /usr/local/lib/vpnsh /home/vpnsh /tmp /var/tmp; do touch "$d/.w" 2>/dev/null && { w="$w $d"; rm -f "$d/.w"; }; done; echo "${w# }"'
out="$(run --entrypoint sh "$IMAGE" -c "$probe")"
[ "$out" = "/home/vpnsh /tmp /var/tmp" ] && ok "一般ユーザーが書き込めるのはホームと /tmp・/var/tmp だけ" || ng "一般ユーザーが書き込める場所が想定外: $out"
out="$(run --user 0 --entrypoint sh "$IMAGE" -c "$probe")"
[ "$out" = "/tmp /var/tmp" ] && ok "root でも書き込めるのは /tmp・/var/tmp だけ" || ng "root が書き込める場所が想定外: $out"

out="$(run --entrypoint perl "$IMAGE" -e 'my $p = fork(); if (!$p) { sleep 10; exit } my %n = (aarch64 => 117, x86_64 => 101); chomp(my $m = `uname -m`); print syscall($n{$m}, 16, $p, 0, 0) == 0 ? "attached" : "denied"; kill 9, $p')"
[ "$out" = "denied" ] && ok "ptrace はできない (seccomp)" || ng "ptrace ができる: $out"

# 使わない・攻撃に使われやすいシステムコール (SysV IPC・POSIX メッセージキュー・Linux AIO・vmsplice・adjtimex・name_to_handle_at・modify_ldt) は EPERM
out="$(run --entrypoint perl "$IMAGE" -e 'my %nr = (x86_64 => [206, 240, 278, 159, 303, 154], aarch64 => [0, 180, 75, 171, 264]); chomp(my $m = `uname -m`);
	$nr{$m} or die "unknown arch: $m\n";
	my @r; push @r, defined(shmget(0, 4096, 0600)) ? "shm" : $!{EPERM} ? () : "shm:$!";
	push @r, defined(msgget(0, 0600)) ? "msg" : $!{EPERM} ? () : "msg:$!";
	push @r, defined(semget(0, 1, 0600)) ? "sem" : $!{EPERM} ? () : "sem:$!";
	my $buf = "\0" x 256; for my $n (@{ $nr{$m} }) { syscall($n, 1, $buf, 0, 0) == -1 && $!{EPERM} or push @r, "nr$n:$!" }
	print @r ? "@r" : "denied"' 2>&1)"
[ "$out" = "denied" ] && ok "SysV IPC・メッセージキュー・AIO・vmsplice などは使えない (seccomp)" || ng "使えてしまうシステムコールがある: $out"

# listmount / statmount は ENOSYS で拒否する (util-linux などは ENOSYS のときだけ /proc/self/mountinfo を読む方式に切り替える)
out="$(run --entrypoint perl "$IMAGE" -e 'my @r; for my $n (457, 458) { syscall($n, 0, 0, 0, 0) == -1 && $!{ENOSYS} or push @r, "nr$n:$!" } print @r ? "@r" : "enosys"' 2>&1)"
[ "$out" = "enosys" ] && ok "listmount / statmount は ENOSYS で拒否する (seccomp)" || ng "listmount / statmount の結果が想定外: $out"

# 32 ビット互換の入口 (x86 の int 0x80・x32・AArch32) はプロファイルに含めない (含めないアーキテクチャのシステムコールはプロセスごと止められる)
out="$(perl -MJSON::PP -e 'local $/; my $p = decode_json(<STDIN>); print join(" ", map { "$_->{architecture}=" . (defined $_->{subArchitectures} ? join(",", @{ $_->{subArchitectures} }) : "none") } @{ $p->{archMap} })' <"$ROOT/templates/seccomp-work.json" 2>&1)"
[ "$out" = "SCMP_ARCH_X86_64=none SCMP_ARCH_AARCH64=none" ] && ok "32 ビット互換の入口は使えない (seccomp のアーキテクチャは x86_64・aarch64 だけ)" || ng "seccomp のアーキテクチャが想定外: $out"

out="$(run --entrypoint bash "$IMAGE" -ic 'echo "$PATH"' 2>/dev/null | tail -n 1)"
# shellcheck disable=SC2088  # 表示の文字列
case "$out" in *":/home/vpnsh/.local/bin") ok "~/.local/bin は PATH の最後" ;; *) ng "PATH の順序が想定外: $out" ;; esac

out="$(run --entrypoint sh "$IMAGE" -c 'for f in /usr/local/lib/vpnsh/*.sh; do bash -n "$f" || echo "構文の誤り: $f"; done
	perl -c /usr/local/lib/vpnsh/ssh-relay 2>&1 | grep -v "syntax OK"
	for c in git ssh ssh-keyscan curl dig ping perl timeout; do command -v "$c" >/dev/null || echo "無い: $c"; done')"
[ -z "$out" ] && ok "イメージの中のスクリプトは構文が正しく、必要なツールがそろっている" || ng "$out"

echo
echo "結果: OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ]
