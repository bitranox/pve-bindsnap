#!/usr/bin/perl
# The clone banner is what install.sh and the Debian postinst print as the activation line,
# so it must state the 1.10.0 carry rule: binds are carried for root@pam only, any other
# caller needs BINDSNAP-EXCLUDE, and a bind/device rootfs is never cloned.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

require PVE::LXC::BindSnap;

my $text = PVE::LXC::BindSnap::_clone_banner('6.1.26', 'abc123', 'v6_1_25') // '';
like($text, qr/^clone overlay active \(pve-container 6\.1\.26, checksum-validated; /,
    'banner keeps the prefix the docs and install.sh legend quote');
like($text, qr/combined sha256 abc123; clone_vm variant v6_1_25\)/, 'names checksum and variant');
like($text, qr/carried to the clone for root\@pam only/, 'states the root\@pam rule');
like($text, qr/BINDSNAP-EXCLUDE/, 'names the exclude route');
like($text, qr/rootfs is never cloned/, 'states the bind-rootfs refusal');
unlike($text, qr/\n/, 'one line (a journal banner)');

done_testing();
