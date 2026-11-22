#!/usr/bin/perl
# The clone carry gate, run as shipped. Each per-build variant (lib/PVE/LXC/BindSnap/Clone/
# *.pm) replaces upstream's "unable to clone mountpoint" die with a fenced BINDSNAP carry
# hunk. This test cuts that hunk out of every variant file and runs it in a minimal loop,
# so the code under test is the generated code a node runs, not a copy of its rule.
#
# Proxmox lets only root@pam set a non-volume (bind/device) mountpoint, so a clone may
# carry one only for root@pam; a bind/device rootfs is never carried, since the clone would
# share the source's root directory. BINDSNAP-EXCLUDE still drops a mount for any caller.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    package PVE::API2::LXC;    ## no critic
    sub map_method_by_name { return undef }
    sub get_standard_option { my ($name, $extra) = @_; return { %{ $extra // {} } }; }
    $INC{'PVE/API2/LXC.pm'} = __FILE__;
}

BEGIN {
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null')   or die "redir STDERR: $!";
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $olderr)      or die "restore STDERR: $!";
}

# The carry hunk's new lines (the "#|" lines are the upstream text it replaces).
sub carry_hunk {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "$file: $!";
    my $text = do { local $/; <$fh> };
    my ($hunk) = $text =~ /^# <<< BINDSNAP carry\n(.*?)^# >>> BINDSNAP\n/ms
        or return undef;
    return join('', grep { !/^#\|/ } split(/^/, $hunk));
}

# Run the hunk for one mountpoint as the clone loop would. Returns the error (or ''), the
# new config, and the carried/excluded lists.
sub run_carry {
    my ($hunk, %a) = @_;
    my $code = 'sub { my ($opt, $value, $mp, $clone_excl, $authuser, $newconf) = @_;'
        . ' my (@clone_carried, @clone_excluded);'
        . ' for my $once (1) {' . "\n" . $hunk . "\n" . '}'
        . ' return ([@clone_carried], [@clone_excluded]); }';
    my $sub = eval $code or die "hunk does not compile: $@";    ## no critic
    my $newconf = {};
    my ($carried, $excluded) = ([], []);
    my $ok = eval {
        ($carried, $excluded) = $sub->($a{opt}, $a{value}, { type => $a{type} },
            $a{excl} // {}, $a{user}, $newconf);
        1;
    };
    return ($ok ? '' : $@, $newconf, $carried, $excluded);
}

my @variants = sort glob("$FindBin::Bin/../lib/PVE/LXC/BindSnap/Clone/*.pm");
ok(scalar(@variants), 'there are clone variants to test');

for my $file (@variants) {
    my ($v) = $file =~ m{/(v[\w]+)\.pm$};
    my $hunk = carry_hunk($file);
    ok(defined $hunk, "$v: has a BINDSNAP carry hunk") or next;
    my $bind = '/opt/data,mp=/var/lib/data';

    my ($err, $conf, $carried) = run_carry($hunk, opt => 'mp0', value => $bind, type => 'bind',
        user => 'alice@pve');
    like($err, qr/^unable to clone mountpoint 'mp0' \(type bind\) .*only allowed for root\@pam/,
        "$v: a non-root caller's clone of a bind mpN is refused, naming the root rule");
    ok(!exists $conf->{mp0}, "$v: the refused bind mpN is not in the new config");

    ($err) = run_carry($hunk, opt => 'mp0', value => '/dev/ttyUSB0,mp=/dev/ttyUSB0',
        type => 'device', user => 'alice@pve');
    like($err, qr/only allowed for root\@pam/, "$v: a non-root caller's device mpN is refused");

    ($err) = run_carry($hunk, opt => 'mp0', value => $bind, type => 'bind', user => 'root@pve');
    like($err, qr/only allowed for root\@pam/, "$v: root in another realm is not root\@pam");

    ($err, $conf, $carried) = run_carry($hunk, opt => 'mp0', value => $bind, type => 'bind',
        user => 'root@pam');
    is($err, '', "$v: root\@pam's clone of a bind mpN goes on");
    is($conf->{mp0}, $bind, "$v: root\@pam's bind mpN is carried unchanged");
    is_deeply($carried, ['mp0'], "$v: and reported as carried");

    my $excluded;
    ($err, $conf, $carried, $excluded) = run_carry($hunk, opt => 'mp0', value => $bind,
        type => 'bind', user => 'alice@pve', excl => { mp0 => 1 });
    is($err, '', "$v: a bind mpN in BINDSNAP-EXCLUDE does not refuse a non-root clone");
    ok(!exists $conf->{mp0}, "$v: the excluded bind mpN is dropped from the clone");
    is_deeply($excluded, ['mp0'], "$v: and reported as excluded");

    ($err, $conf) = run_carry($hunk, opt => 'rootfs', value => '/opt/ctroot', type => 'bind',
        user => 'root@pam');
    is($err, "unable to clone mountpoint 'rootfs' (type bind)\n",
        "$v: a bind rootfs is refused even for root\@pam, with upstream's own message");
    ok(!exists $conf->{rootfs}, "$v: the bind rootfs is not in the new config");
}

done_testing();
