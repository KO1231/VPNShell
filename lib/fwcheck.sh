# shellcheck shell=bash
# gluetun のファイアウォールとルーティングの生成と検査
#
# - post-rules をテンプレートから生成する
# - gluetun 内の iptables (filter / nat / mangle / raw)、ip6tables、legacy、ip rule / ip route を
#   1回の docker exec で取得し、毎回変わる値だけを正規化して、templates/firewall-expected.txt と比べる
#   (先頭に挿入した VPNShell のルールは順序どおり、それ以外は集合として)

FW_IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

fw_is_ipv4() { printf '%s' "$1" | grep -Eq "$FW_IPV4_RE"; }
fw_is_port() { case "$1" in "" | *[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# fw_render <テンプレート> <エンドポイントIP> <ポート>  (stdout に出す。値は検証してから埋め込む)
fw_render() {
	if ! fw_is_ipv4 "$2"; then vpnsh_err "WIREGUARD_ENDPOINT_IP が IPv4 アドレスではありません: '$2'"; return 1; fi
	if ! fw_is_port "$3"; then vpnsh_err "WIREGUARD_ENDPOINT_PORT がポート番号ではありません: '$3'"; return 1; fi
	sed -e "s/@@ENDPOINT_IP@@/$2/g" -e "s/@@ENDPOINT_PORT@@/$3/g" "$1"
}

# fw_render_post_rules <テンプレート> <出力> <エンドポイントIP> <ポート>
fw_render_post_rules() {
	local tmp="$2.tmp.$$"
	fw_render "$1" "$3" "$4" >"$tmp" || { rm -f "$tmp"; return 1; }
	chmod 0644 "$tmp" && mv -f "$tmp" "$2"
}

# fw_dump <コンテナ名>
# gluetun 内で各表を出力する。先頭行に gluetun の PID 1 のネットワーク名前空間を出す
fw_dump() {
	vpnsh_timeout 10 docker --context "$VPNSH_CONTEXT" exec "$1" sh -c '
		echo "## netns $(readlink /proc/1/ns/net)"
		# stderr は捨てる ("legacy tables present" の警告が混ざるため)。失敗は終了コードで検出する
		echo "## filter"; iptables -S 2>/dev/null || echo "!! iptables failed"
		echo "## nat"; iptables -t nat -S 2>/dev/null || echo "!! iptables nat failed"
		echo "## mangle"; iptables -t mangle -S 2>/dev/null || echo "!! iptables mangle failed"
		echo "## raw"; iptables -t raw -S 2>/dev/null || echo "!! iptables raw failed"
		echo "## filter6"; ip6tables -S 2>/dev/null || echo "!! ip6tables failed"
		echo "## legacy"; iptables-legacy -S 2>/dev/null || echo "!! iptables-legacy failed"
		echo "## legacy-nat"; iptables-legacy -t nat -S 2>/dev/null || echo "!! iptables-legacy nat failed"
		echo "## legacy6"; ip6tables-legacy -S 2>/dev/null || echo "!! ip6tables-legacy failed"
		echo "## rule4"; ip -4 rule show 2>/dev/null || echo "!! ip rule failed"
		echo "## route4"; { ip -4 route show table all 2>/dev/null || echo "!! ip route failed"; } | sed "s/[[:space:]]*$//"
		echo "## rule6"; ip -6 rule show 2>/dev/null || echo "!! ip -6 rule failed"
		echo "## route6"; { ip -6 route show table all 2>/dev/null || echo "!! ip -6 route failed"; } | sed "s/[[:space:]]*$//"
	'
}

# fw_normalize  (stdin → stdout)
# 環境変数 FW_ETH_IP / FW_SUBNET / FW_BCAST / FW_GW / FW_EP_IP / FW_EP_PORT / FW_WG_ADDR の値を
# @@...@@ に置き換える。IP は前後が数字やドットでない位置だけを置き換える (部分一致を防ぐ)
fw_normalize() {
	perl -ne '
		next if /^## netns /;
		my @subs = (
			[$ENV{FW_SUBNET}, "\@\@ETH0_SUBNET\@\@"],
			[$ENV{FW_BCAST}, "\@\@ETH0_BCAST\@\@"],
			[$ENV{FW_GW}, "\@\@ETH0_GW\@\@"],
			[$ENV{FW_ETH_IP}, "\@\@ETH0_IP\@\@"],
			[$ENV{FW_EP_IP}, "\@\@ENDPOINT_IP\@\@"],
			[$ENV{FW_WG_ADDR}, "\@\@WG_ADDR\@\@"],
		);
		for my $p (@subs) {
			my ($v, $r) = @$p;
			next unless defined $v && length $v;
			s/(?<![\d.])\Q$v\E(?![\d.])/$r/g;
		}
		s/--dport \Q$ENV{FW_EP_PORT}\E(?!\d)/--dport \@\@ENDPOINT_PORT\@\@/g if length($ENV{FW_EP_PORT} // "");
		s/--to-destination 127\.0\.0\.11:\d+/--to-destination 127.0.0.11:\@\@PORT\@\@/g;
		s/--sport \d+ -j SNAT/--sport \@\@PORT\@\@ -j SNAT/g;
		print;
	'
}

# fw_netns_from_dump  (stdin: fw_dump の出力) → "net:[...]"
fw_netns_from_dump() { sed -n 's/^## netns //p' | head -n 1; }

# fw_canonical (stdin → stdout)
# 比べ方: 先頭に挿入した VPNShell のルール (期待値ファイルで '= ' 付き) は順序どおり、
# それ以外の行は集合として比べる (gluetun が再接続で末尾の許可を付け外ししても、順序の揺れで誤判定しない)
fw_canonical() {
	perl -e '
		my ($sec, %rows, @order);
		while (my $l = <STDIN>) {
			chomp $l;
			next if $l =~ /^\s*$/ || $l =~ /^#(?!#)/;
			if ($l =~ /^## (\S+)/) { $sec = $1; push @order, $sec; $rows{$sec} = { fixed => [], set => [] }; next; }
			die "section missing\n" unless defined $sec;
			if ($l =~ s/^= //) { push @{$rows{$sec}{fixed}}, $l; }
			else { push @{$rows{$sec}{set}}, $l; }
		}
		for my $s (@order) {
			print "## $s\n";
			print "= $_\n" for @{$rows{$s}{fixed}};
			print "$_\n" for sort @{$rows{$s}{set}};
		}
	'
}

# fw_mark_fixed <期待値ファイル>  (stdin: 正規化済みの dump)
# 期待値ファイルで、あるセクションのあるチェーンに '= -A <CHAIN> ...' が N 本あれば、
# 実際のそのチェーンの -A 行の先頭 N 本に '= ' を付ける
fw_mark_fixed() {
	FW_EXPECTED="$1" perl -e '
		my (%n, $sec);
		open my $fh, "<", $ENV{FW_EXPECTED} or die "open: $!";
		while (<$fh>) {
			if (/^## (\S+)/) { $sec = $1; next; }
			$n{"$sec $1"}++ if defined $sec && /^= -A (\S+) /;
		}
		close $fh;
		my %left;
		while (my $l = <STDIN>) {
			if ($l =~ /^## (\S+)/) { $sec = $1; print $l; next; }
			if (defined $sec && $l =~ /^-A (\S+) /) {
				my $k = "$sec $1";
				$left{$k} = $n{$k} // 0 unless exists $left{$k};
				if ($left{$k} > 0) { print "= $l"; $left{$k}--; next; }
			}
			print $l;
		}
	'
}

# fw_check <コンテナ名> <期待値ファイル>
# 呼ぶ前に FW_ETH_IP / FW_SUBNET / FW_BCAST / FW_GW / FW_EP_IP / FW_EP_PORT / FW_WG_ADDR を設定すること
# 一致すれば 0。不一致なら差分を stderr に出して 1。成功時は FW_NETNS に gluetun の名前空間を入れる
fw_check() {
	local name="$1" expected="$2" dump v
	for v in "$FW_ETH_IP" "$FW_GW" "$FW_BCAST" "$FW_EP_IP" "$FW_WG_ADDR"; do
		if ! fw_is_ipv4 "$v"; then vpnsh_err "ファイアウォールの検査に使う値が IPv4 アドレスではありません: '$v'"; return 1; fi
	done
	fw_is_port "$FW_EP_PORT" || { vpnsh_err "ファイアウォールの検査に使うポートが正しくありません: '$FW_EP_PORT'"; return 1; }
	dump="$(fw_dump "$name")" || { vpnsh_err "gluetun 内で iptables を取得できません"; return 1; }
	# shellcheck disable=SC2034  # 呼び出し側が参照する
	FW_NETNS="$(printf '%s\n' "$dump" | fw_netns_from_dump)"
	if printf '%s\n' "$dump" | grep -q '^!! '; then
		vpnsh_err "gluetun 内の iptables / ip の実行に失敗しました:"
		printf '%s\n' "$dump" | grep '^!! ' | vpnsh_sanitize >&2
		return 1
	fi
	local actual want
	actual="$(printf '%s\n' "$dump" | FW_ETH_IP="$FW_ETH_IP" FW_SUBNET="$FW_SUBNET" FW_BCAST="$FW_BCAST" FW_GW="$FW_GW" \
		FW_EP_IP="$FW_EP_IP" FW_EP_PORT="$FW_EP_PORT" FW_WG_ADDR="$FW_WG_ADDR" fw_normalize | fw_mark_fixed "$expected" | fw_canonical)"
	want="$(fw_canonical <"$expected")"
	if [ "$actual" != "$want" ]; then
		vpnsh_err "gluetun のファイアウォール / ルーティングが期待値と一致しません (- 期待値 / + 実際)"
		# 制御文字は見える形にする (ルールのコメントなどにエスケープシーケンスを入れて、行を隠せないように)
		diff <(printf '%s\n' "$want") <(printf '%s\n' "$actual") | sed -n -e 's/^< /  - /p' -e 's/^> /  + /p' | vpnsh_visible >&2
		return 1
	fi
	return 0
}

# fw_net_values <IP> <プレフィックス長>  → "サブネット ブロードキャスト" (docker を呼ばずに計算する)
fw_net_values() {
	local a b c d n mask bc p="$2"
	fw_is_ipv4 "$1" || return 1
	case "$p" in "" | *[!0-9]*) return 1 ;; esac
	[ "$p" -ge 1 ] && [ "$p" -le 32 ] || return 1
	IFS=. read -r a b c d <<EOF
$1
EOF
	n=$(((a << 24) | (b << 16) | (c << 8) | d))
	mask=$(((0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF))
	n=$((n & mask))
	bc=$((n | (~mask & 0xFFFFFFFF)))
	printf '%d.%d.%d.%d/%d %d.%d.%d.%d' \
		$(((n >> 24) & 255)) $(((n >> 16) & 255)) $(((n >> 8) & 255)) $((n & 255)) "$p" \
		$(((bc >> 24) & 255)) $(((bc >> 16) & 255)) $(((bc >> 8) & 255)) $((bc & 255))
}
