#!/usr/bin/perl
# A --snapname clone of a bind-mount CT whose snapshot excluded a MANAGED volume (frozen
# "BINDSNAP-EXCLUDE: mp1" in the snapshot's description) must leave that volume out: it has
# no snapshot data, so cloning it from the snapshot fails. Each shipped variant's own loop
# (from the BINDSNAP excludes hunk to the end of "for my $opt") runs against stubs, and the
# test asks what the worker is told to clone. Controls: a live clone of the same CT, and a
# snapshot of a CT without bind mounts (taken stock, every volume), clone every managed
# volume. Reported in PR #2 by sasha-id.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

BEGIN {
    package PVE::API2::LXC;
    sub map_method_by_name { undef }
    sub get_standard_option { {} }
    $INC{'PVE/API2/LXC.pm'} = __FILE__;
    package PVE::LXC::Config;
    sub parse_volume {
        my ($c, $opt, $v) = @_;
        return $v =~ m{^/} ? { type => 'bind', mp => '/x' } : { type => 'volume', volume => (split /,/, $v)[0] };
    }
    $INC{'PVE/LXC/Config.pm'} = __FILE__;
    package PVE::Storage;
    sub parse_volume_id { my ($v) = @_; return split /:/, $v, 2; }
    sub storage_config { return { shared => 0 } }
    sub volume_has_feature { return 1 }
    package RPC;
    sub check { 1 }
}
BEGIN {
    open(my $o, '>&', \*STDERR);
    open(STDERR, '>', '/dev/null');
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $o);
}

sub loop_code {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "$file: $!";
    my @l = <$fh>;
    my ($s) = grep { $l[$_] =~ /^# <<< BINDSNAP excludes/ } 0 .. $#l;
    my ($f) = grep { $_ > $s && $l[$_] =~ /for my \$opt \(sort keys %\$src_conf\)/ } 0 .. $#l;
    my ($e) = grep { $_ > $f && $l[$_] =~ /^            }$/ } 0 .. $#l;
    return join '', @l[$s .. $e];
}

my %snap_bind = (
    rootfs      => 'local-zfs:subvol-100-disk-0,size=8G',
    mp0         => '/opt/data,mp=/data',
    mp1         => 'local-zfs:subvol-100-disk-1,mp=/cache,size=4G',
    description => '#### BINDSNAP-EXCLUDE: mp1',
);
my %snap_plain = %snap_bind;
delete $snap_plain{mp0};

my @files = sort glob("$FindBin::Bin/../lib/PVE/LXC/BindSnap/Clone/*.pm");
ok(scalar(@files) >= 6, 'found the shipped variants');
for my $file (@files) {
    my ($v) = $file =~ m{/(v\w+)\.pm$};
    my $code = 'sub { my ($src_conf, $snapname, $authuser) = @_;'
      . ' my ($storage, $full, $running, $target) = (undef, 1, 0, undef);'
      . ' my $rpcenv = bless {}, "RPC"; my $storecfg = {};'
      . ' my ($newconf, $mountpoints, $fullclone, $vollist) = ({}, {}, {}, []);'
      . ' my (@clone_carried, @clone_excluded, @clone_left_out);' . "\n"
      . loop_code($file) . "\n"
      . ' return ($mountpoints, \@clone_carried, \@clone_left_out); }';
    my $sub = eval "package PVE::LXC::BindSnap; $code" or die "$v: $@";

    my ($mps, $car, $left) = $sub->({%snap_bind}, 'pre', 'root@pam');
    is_deeply([sort @$car], ['mp0'], "$v: bind mp0 carried for root\@pam");
    ok(!exists $mps->{mp1}, "$v: --snapname clone does not queue mp1, excluded from snapshot 'pre'");
    is_deeply($left, ['mp1'], "$v: mp1 reported as left out");

    ($mps, undef, $left) = $sub->({%snap_bind}, undef, 'root@pam');
    ok(exists $mps->{mp1}, "$v: live clone still clones the managed mp1");
    is_deeply($left, [], "$v: live clone leaves nothing out");

    ($mps, undef, $left) = $sub->({%snap_plain}, 'pre', 'root@pam');
    ok(exists $mps->{mp1}, "$v: snapshot of a CT without bind mounts clones mp1 (taken stock)");
    is_deeply($left, [], "$v: ... and leaves nothing out");
}

my $B = 'PVE::LXC::BindSnap';
my $sum = $B->can('_clone_summary')->(
    vmid => 100, newid => 200, vlabel => '6.1.26', cloned => ['rootfs'],
    carried => ['mp0'], excluded => [], left_out => ['mp1'],
);
(my $flat = $sum) =~ s/\s+/ /g;    # the summary wraps long lines
like($flat, qr/left out mp1 \(excluded from the snapshot, no snapshot data\)/, 'summary names the left-out volume');
my $w = $B->can('_clone_left_out_warning')->(['mp1']);
like($w, qr/left out mp1/, 'warning names the left-out volume');
like($w, qr/empty|without/i, 'warning says the clone lacks that data');
is($B->can('_clone_left_out_warning')->([]), '', 'no warning when nothing was left out');

done_testing();
