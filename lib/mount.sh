# shellcheck shell=bash
# カレントディレクトリを work コンテナにマウントするときの安全策
#
# 判定はパスの文字列ではなく inode (デバイス番号:inode 番号) で行う。
# macOS (APFS) は大文字小文字を区別しないので、文字列で比べると `cd ~/.SSH` のような
# 書き方ですり抜けられる。シンボリックリンクも実体で判定する。
#
# 許可するのは「マウントを許可するディレクトリ (mount-root。既定 ~/Projects) の配下」だけ。ただし次は拒否する。
#   - 許可するディレクトリそのもの
#   - VPNShell リポジトリそのもの、その配下、その祖先 (確認ダイアログのスクリプトなどを書き換えられないように)
#   - パスに : や , や制御文字を含むもの (docker の -v の書式が壊れるため)

# mnt_chain <ディレクトリ>  そのディレクトリから / までの inode を1行ずつ出す (".." を実体でたどる)
mnt_chain() {
	perl -e '
		my $p = shift @ARGV;
		my %seen;
		for (my $i = 0; $i < 256; $i++) {
			my @s = stat($p) or exit 1;
			my $id = "$s[0]:$s[1]";
			last if $seen{$id}++;
			print "$id\n";
			$p .= "/..";
		}
	' "$1"
}

# mnt_root_ok <ディレクトリ>  マウントを許可する場所 (mount-root) として使えるなら、実体の絶対パスを出す
# 使えるのは「ホームの中のディレクトリ」で、ホームそのもの・. で始まるディレクトリ (~/.ssh など) の中・
# ~/Library の中は不可 (秘密の情報を含む場所を、うっかりマウントできてしまわないように)。
# .env に書くので、使える文字は英数字と . _ - / だけ
mnt_root_ok() {
	local d="$1" real home rel
	# shellcheck disable=SC2088  # 入力の "~/" という文字を $HOME に置き換える
	case "$d" in "~/"*) d="$HOME/${d#\~/}" ;; esac
	case "$d" in /*) ;; *) vpnsh_err "mount-root は絶対パス (または ~/…) で指定してください: $1"; return 1 ;; esac
	[ -d "$d" ] || { vpnsh_err "ディレクトリがありません: $1"; return 1; }
	real="$(cd -P "$d" 2>/dev/null && pwd)" || { vpnsh_err "ディレクトリを開けません: $1"; return 1; }
	home="$(cd -P "$HOME" 2>/dev/null && pwd)"
	case "$real" in "$home"/*) ;; *) vpnsh_err "mount-root はホームの中のディレクトリにしてください (ホームそのものは不可): $real"; return 1 ;; esac
	rel="${real#"$home"/}"
	case "/$rel/" in */.*) vpnsh_err "mount-root に . で始まるディレクトリ (~/.ssh など) は使えません: $real"; return 1 ;; esac
	# APFS は既定で大文字・小文字を区別せず、cd -P / pwd も入力の綴りのまま返すので、小文字にそろえて比べる
	# (~/library や ~/LIBRARY でも ~/Library の中を指せてしまうため)
	case "$(vpnsh_lc "$rel")/" in library/*) vpnsh_err "mount-root に ~/Library の中は使えません: $real"; return 1 ;; esac
	printf '%s' "$real" | LC_ALL=C grep -Eq '^[A-Za-z0-9._/-]+$' ||
		{ vpnsh_err "mount-root のパスに使えない文字があります (英数字と . _ - / だけ): $real"; return 1; }
	printf '%s' "$real"
}

# mnt_id <パス>  inode を出す
mnt_id() { perl -e 'my @s = stat($ARGV[0]) or exit 1; print "$s[0]:$s[1]\n"' "$1"; }

# mnt_check <対象ディレクトリ> <許可するディレクトリ> <VPNShell リポジトリ>
# 問題なければ、マウントに使う実体のパスを stdout に出して 0。問題があれば理由を出して 1
mnt_check() {
	local target="$1" root="$2" repo="$3" phys t_id r_id p_id chain repo_chain
	if [ ! -d "$target" ]; then vpnsh_err "マウントするディレクトリがありません: $target"; return 1; fi
	if [ ! -d "$root" ]; then vpnsh_err "マウントを許可するディレクトリがありません: $root"; return 1; fi
	# 実体のパス (シンボリックリンクを解決する)
	phys="$(cd "$target" 2>/dev/null && /bin/pwd -P)" || { vpnsh_err "ディレクトリに入れません: $target"; return 1; }
	case "$phys" in
		*:* | *,*) vpnsh_err "パスに : や , を含むディレクトリはマウントできません: $phys"; return 1 ;;
	esac
	if printf '%s' "$phys" | LC_ALL=C grep -q '[[:cntrl:]]'; then
		vpnsh_err "パスに制御文字を含むディレクトリはマウントできません"; return 1
	fi
	t_id="$(mnt_id "$phys")" || { vpnsh_err "ディレクトリの情報を取得できません: $phys"; return 1; }
	p_id="$(mnt_id "$root")" || { vpnsh_err "ディレクトリの情報を取得できません: $root"; return 1; }
	r_id="$(mnt_id "$repo")" || { vpnsh_err "ディレクトリの情報を取得できません: $repo"; return 1; }
	chain="$(mnt_chain "$phys")" || { vpnsh_err "ディレクトリの祖先をたどれません: $phys"; return 1; }
	repo_chain="$(mnt_chain "$repo")" || { vpnsh_err "ディレクトリの祖先をたどれません: $repo"; return 1; }

	if [ "$t_id" = "$p_id" ]; then
		vpnsh_err "$root そのものはマウントできません。その中のプロジェクトのディレクトリで実行してください"
		return 1
	fi
	# 許可するディレクトリの配下であること (祖先に含まれること)
	if ! printf '%s\n' "$chain" | sed 1d | grep -qxF "$p_id"; then
		vpnsh_err "マウントできるのは $root の配下だけです (今のディレクトリ: $phys)"
		return 1
	fi
	# VPNShell リポジトリそのもの・その配下 (祖先にリポジトリがある) ではないこと
	if printf '%s\n' "$chain" | grep -qxF "$r_id"; then
		vpnsh_err "VPNShell のリポジトリとその配下はマウントできません"
		return 1
	fi
	# VPNShell リポジトリの祖先ではないこと
	if printf '%s\n' "$repo_chain" | grep -qxF "$t_id"; then
		vpnsh_err "VPNShell のリポジトリを含むディレクトリはマウントできません"
		return 1
	fi
	printf '%s' "$phys"
}

# mnt_display <実体のパス>  表示用に $HOME を ~ に置き換える (表示に使えない文字は ? にする)
mnt_display() {
	local p="$1" home
	home="$(cd "$HOME" 2>/dev/null && /bin/pwd -P)"
	case "$p" in "$home"/*) p="~${p#"$home"}" ;; esac
	printf '%s' "$p" | LC_ALL=C tr -c 'A-Za-z0-9._~/+@ -' '?' | cut -c1-120
}
