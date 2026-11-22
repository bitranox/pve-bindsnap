#!/usr/bin/perl
# Rollback keeps every managed volume of the LIVE config that the snapshot lacks as an unusedN
# entry (upstream __snapshot_rollback_get_unused), then replaces the config with the
# snapshot's. That comparison touches no storage, so BINDSNAP-EXCLUDE must not hide volumes
# from it: a live volume excluded by the Notes and missing from the snapshot would otherwise
# vanish from the config while staying on storage (an orphan). The volume rollback itself still
# honours the snapshot's exclusions. The stub's get_unused is upstream's body (pve-container
# 6.1.24), and its rollback calls it the way AbstractConfig::snapshot_rollback does.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

BEGIN {
    package PVE::LXC::Config;
    our (%CONF, %SEEN);
    sub foreach_volume_full {
        my ($c, $conf, $o, $f, @p) = @_;
        $f->($_->[0], $_->[1], @p) for @{ $conf->{_vols} // [] };
    }
    sub foreach_volume { my ($c, $conf, $f, @p) = @_; return $c->foreach_volume_full($conf, undef, $f, @p); }
    sub has_feature { 1 }
    sub load_config { $CONF{ $_[1] } }
    sub __snapshot_check_running { 0 }
    sub snapshot_create { 1 }
    sub snapshot_delete { 1 }

    sub __snapshot_rollback_get_unused {
        my ($class, $conf, $snap) = @_;

        my $unused = [];

        $class->foreach_volume(
            $conf,
            sub {
                my ($vs, $volume) = @_;

                return if $volume->{type} ne 'volume';

                my $found = 0;
                my $volid = $volume->{volume};

                $class->foreach_volume(
                    $snap,
                    sub {
                        my ($ms, $mountpoint) = @_;

                        return if $found;
                        return if ($mountpoint->{type} ne 'volume');

                        $found = 1
                            if ($mountpoint->{volume} && $mountpoint->{volume} eq $volid);
                    },
                );

                push @$unused, $volid if !$found;
            },
        );

        return $unused;
    }

    sub snapshot_rollback {
        my ($c, $vmid, $sn) = @_;
        my $conf = $c->load_config($vmid);
        my $snap = $conf->{snapshots}{$sn};
        my @rolled;
        $c->foreach_volume_full($snap, undef, sub { push @rolled, $_[0] });
        $SEEN{rolled} = [sort @rolled];
        $SEEN{unused} = [sort @{ $c->__snapshot_rollback_get_unused($conf, $snap) }];
    }
    $INC{'PVE/LXC/Config.pm'} = __FILE__;
}

BEGIN {
    open(my $o, '>&', \*STDERR);
    open(STDERR, '>', '/dev/null');
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $o);
}
is($PVE::LXC::BindSnap::APPLIED, 1, 'overlay wired against the stub');

sub vol  { return { type => 'volume', volume => $_[0] } }
my $BIND = { type => 'bind' };
my $X1   = '#### BINDSNAP-EXCLUDE: mp1';
my $X2   = '#### BINDSNAP-EXCLUDE: mp2';

# name => [live volumes, live Notes, snapshot volumes, snapshot description, rolled, unused]
my %cases = (
    orphan_excluded_by_notes => [
        [[rootfs => vol('r')], [mp0 => $BIND], [mp2 => vol('v2')]], $X2,
        [[rootfs => vol('r')], [mp0 => $BIND]],                     $X2,
        [qw(rootfs)], [qw(v2)],
    ],
    in_both_excluded_by_snapshot_only => [
        [[rootfs => vol('r')], [mp0 => $BIND], [mp1 => vol('v1')]], 'plain notes',
        [[rootfs => vol('r')], [mp0 => $BIND], [mp1 => vol('v1')]], $X1,
        [qw(rootfs)], [],
    ],
    in_both_excluded_by_both => [
        [[rootfs => vol('r')], [mp0 => $BIND], [mp1 => vol('v1')]], $X1,
        [[rootfs => vol('r')], [mp0 => $BIND], [mp1 => vol('v1')]], $X1,
        [qw(rootfs)], [],
    ],
    added_after_snapshot_not_excluded => [
        [[rootfs => vol('r')], [mp0 => $BIND], [mp3 => vol('v3')]], 'plain notes',
        [[rootfs => vol('r')], [mp0 => $BIND]],                     undef,
        [qw(rootfs)], [qw(v3)],
    ],
);
my $id = 200;
for my $name (sort keys %cases) {
    my ($lv, $ld, $sv, $sd, $rolled, $unused) = @{ $cases{$name} };
    $id++;
    $PVE::LXC::Config::CONF{$id} = {
        _vols => $lv, description => $ld, snapshots => { pre => { _vols => $sv, description => $sd } },
    };
    %PVE::LXC::Config::SEEN = ();
    {
        local *STDERR;
        my $err = '';
        open(STDERR, '>', \$err);
        PVE::LXC::Config->snapshot_rollback($id, 'pre');
    }
    is_deeply($PVE::LXC::Config::SEEN{rolled}, $rolled, "$name: rollback reaches @$rolled");
    is_deeply($PVE::LXC::Config::SEEN{unused}, $unused, "$name: unused volumes are (@$unused), as stock");
}

done_testing();
