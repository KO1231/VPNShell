# shellcheck shell=bash

# pins_index_digest  (stdin: imagetools inspect の Manifest の JSON) arm64 と amd64 を含むインデックスなら、そのダイジェストを出す
pins_index_digest() {
	perl -MJSON::PP -e '
		local $/; my $m = eval { decode_json(<STDIN>) } or exit 1;
		my %arch = map { ($_->{platform}{architecture} // "") => 1 } @{ $m->{manifests} // [] };
		exit 2 unless $arch{arm64} && $arch{amd64};
		print $m->{digest} if ($m->{digest} // "") =~ /\Asha256:[0-9a-f]{64}\z/;
	'
}
