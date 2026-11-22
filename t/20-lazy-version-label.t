#!/usr/bin/perl
# Every pct call and every PVE daemon start loads the overlay. The pve-container version is
# only a label in messages, so loading must not fork dpkg-query: the label is read on first
# use and at most once per process. A daemon reads it once for both activation lines.
use strict;
use warnings;
use FindBin;
use Test::More;
use File::Temp qw(tempdir);

my $LIB = "$FindBin::Bin/../lib";

# Load the overlay against a stub PVE::LXC::Config in a fresh perl named $name, with STDERR
# going to a file (not a tty, as in a daemon), and print the query count after loading and
# after two reads of the label.
sub counts {
    my ($name) = @_;
    my $script = <<'PL';
BEGIN {
    package PVE::LXC::Config;
    sub foreach_volume_full { 1 } sub has_feature { 1 } sub load_config { {} }
    sub __snapshot_check_running { 0 } sub snapshot_create { 1 } sub snapshot_delete { 1 }
    sub snapshot_rollback { 1 }
    $INC{'PVE/LXC/Config.pm'} = 1;
}
$0 = shift @ARGV;
open(STDERR, '>', '/dev/null');
require PVE::LXC::BindSnap;
my $loaded = $PVE::LXC::BindSnap::PKG_VERSION_QUERIES;
PVE::LXC::BindSnap::_vlabel() for 1 .. 2;
print "$PVE::LXC::BindSnap::APPLIED $loaded $PVE::LXC::BindSnap::PKG_VERSION_QUERIES\n";
PL
    my $file = tempdir(CLEANUP => 1) . '/load.pl';
    open(my $fh, '>', $file) or die "write $file: $!";
    print {$fh} $script;
    close $fh or die "write $file: $!";
    my $out = `'$^X' -I'$LIB' '$file' '$name' 2>/dev/null </dev/null`;
    chomp $out;
    return split / /, $out;
}

my ($applied, $loaded, $after) = counts('pct');
is($applied, 1, 'pct: overlay applied against the stub');
is($loaded,  0, 'pct: loading the overlay reads no version');
is($after,   1, 'pct: two reads of the label query dpkg once');

($applied, $loaded, $after) = counts('pvedaemon');
is($applied, 1, 'pvedaemon: overlay applied against the stub');
is($loaded,  1, 'pvedaemon: the activation line reads the version once');
is($after,   1, 'pvedaemon: later reads reuse it');

done_testing();
