#!/usr/bin/perl
# The overlay only engages for CTs with bind/device mounts. Test the detection
# predicate _conf_needs_overlay (pure; the engagement check in snapshot_create loads
# the config itself and applies this to it).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null')   or die "redir STDERR: $!";
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $olderr)      or die "restore STDERR: $!";
}

my $needs = PVE::LXC::BindSnap->can('_conf_needs_overlay') or BAIL_OUT('_conf_needs_overlay missing');

# Stub foreach_volume_full: here $conf is an arrayref of [key => {type=>...}] and we
# just hand each entry to $func, exactly as the real iterator hands ($key, $volume).
my $fvf = sub { my ($cls, $conf, $opts, $func) = @_; $func->(@$_) for @$conf; };

# _conf_needs_overlay: true iff some mountpoint's type isn't 'volume'
is($needs->('LXC', [['rootfs', {type => 'volume'}]], $fvf), 0, 'rootfs only -> no overlay');
is($needs->('LXC', [['rootfs', {type => 'volume'}], ['mp8', {type => 'volume'}]], $fvf), 0, 'all volume mps -> no overlay');
is($needs->('LXC', [['rootfs', {type => 'volume'}], ['mp0', {type => 'bind'}]], $fvf), 1, 'a bind mount -> needs overlay');
is($needs->('LXC', [['rootfs', {type => 'volume'}], ['mp0', {type => 'device'}]], $fvf), 1, 'a device mount -> needs overlay');
is($needs->('LXC', [], $fvf), 0, 'no mountpoints -> no overlay');
is($needs->('LXC', [['mp0', {type => undef}]], $fvf), 1, 'undef type -> needs overlay (matches the filter)');

done_testing();
