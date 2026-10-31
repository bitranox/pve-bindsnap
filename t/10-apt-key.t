#!/usr/bin/perl
# The apt trust anchor: install-apt.sh embeds the archive public key, and that key must
# be the committed apt/pve-bindsnap-archive-keyring.asc (the one tools/build-apt-repo.sh
# verifies every signature against), with the fingerprint the script states.
use strict;
use warnings;
use Test::More;
use FindBin;

my $ROOT = "$FindBin::Bin/..";

sub slurp {
    my ($p) = @_;
    open(my $fh, '<', $p) or die "read $p: $!";
    local $/;
    return scalar <$fh>;
}

my $script = slurp("$ROOT/install-apt.sh");
my $asc    = slurp("$ROOT/apt/pve-bindsnap-archive-keyring.asc");

my ($embedded) = $script =~ /^    cat <<'KEY'\n(.*?)^KEY\n/ms;
ok(defined $embedded, 'install-apt.sh embeds a key block');
is($embedded, $asc, 'the embedded key is apt/pve-bindsnap-archive-keyring.asc byte for byte');

my ($stated) = $script =~ /^#   ([0-9A-F]{4}(?: {1,2}[0-9A-F]{4}){9})$/m;
ok(defined $stated, 'install-apt.sh states the key fingerprint');
(my $stated_hex = $stated // '') =~ s/\s+//g;

SKIP: {
    my $out = `gpg --batch --with-colons --show-keys "$ROOT/apt/pve-bindsnap-archive-keyring.asc" 2>/dev/null`;
    skip 'gpg not available', 1 if $? != 0 || !length $out;
    my ($fpr) = $out =~ /^fpr:(?:[^:]*:){8}([0-9A-F]{40}):/m;
    is($stated_hex, $fpr, 'the stated fingerprint is the key\'s real fingerprint');
}

done_testing();
