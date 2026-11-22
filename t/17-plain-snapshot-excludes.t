#!/usr/bin/perl
# A BINDSNAP-EXCLUDE line only takes effect on a snapshot of a bind-mount CT: a CT without
# bind/device mounts is snapshotted stock, every managed volume included. So delete and
# rollback of such a snapshot must reach every volume even when the snapshot's description
# happens to carry a directive (copied from another CT, written by hand), or rollback leaves a
# volume unrewound and delete leaves its storage snapshot behind. The stub's delete/rollback
# walk the SNAPSHOT config, as upstream AbstractConfig::snapshot_delete/rollback do.
# Reported in PR #2 by sasha-id.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

BEGIN {
    package PVE::LXC::Config;
    our (%CONF, @SEEN);
    sub foreach_volume_full {
        my ($c, $conf, $o, $f, @p) = @_;
        $f->($_->[0], $_->[1], @p) for @{ $conf->{_vols} // [] };
    }
    sub has_feature { 1 }
    sub load_config { $CONF{ $_[1] } }
    sub __snapshot_check_running { 0 }
    sub snapshot_create { 1 }
    sub _snap_iter {
        my ($c, $vmid, $sn) = @_;
        my @s;
        $c->foreach_volume_full($c->load_config($vmid)->{snapshots}{$sn}, undef, sub { push @s, $_[0] });
        return \@s;
    }
    sub snapshot_delete   { my ($c, $vmid, $sn) = @_; push @SEEN, [delete   => $c->_snap_iter($vmid, $sn)]; }
    sub snapshot_rollback { my ($c, $vmid, $sn) = @_; push @SEEN, [rollback => $c->_snap_iter($vmid, $sn)]; }
    $INC{'PVE/LXC/Config.pm'} = __FILE__;
}

my $journal = '';
BEGIN {
    open(my $o, '>&', \*STDERR);
    open(STDERR, '>', '/dev/null');
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $o);
}
is($PVE::LXC::BindSnap::APPLIED, 1, 'overlay wired against the stub');

my $V = { type => 'volume' };
my $B = { type => 'bind' };
my %cases = (
    plain_directive => [[[rootfs => $V], [mp1 => $V]], '#### BINDSNAP-EXCLUDE: mp1', [qw(mp1 rootfs)]],
    plain_none      => [[[rootfs => $V], [mp1 => $V]], undef, [qw(mp1 rootfs)]],
    bind_empty      => [[[rootfs => $V], [mp0 => $B], [mp1 => $V]], '#### BINDSNAP-EXCLUDE:', [qw(mp1 rootfs)]],
    bind_directive  => [[[rootfs => $V], [mp0 => $B], [mp1 => $V]], '#### BINDSNAP-EXCLUDE: mp1', [qw(rootfs)]],
);
my $id = 100;
for my $name (sort keys %cases) {
    my ($vols, $desc, $want) = @{ $cases{$name} };
    $id++;
    $PVE::LXC::Config::CONF{$id} = { _vols => $vols, snapshots => { pre => { _vols => $vols, description => $desc } } };
    for my $op (qw(snapshot_delete snapshot_rollback)) {
        @PVE::LXC::Config::SEEN = ();
        my $err = '';
        {
            local *STDERR;
            open(STDERR, '>', \$err);
            PVE::LXC::Config->$op($id, 'pre');
        }
        is_deeply([sort @{ $PVE::LXC::Config::SEEN[0][1] }], $want, "$name: $op reaches @$want");
        if ($name =~ /^plain/) {
            unlike($err, qr/as-is \(excluded/, "$name: $op summary claims no excluded volume");
        }
    }
}

done_testing();
