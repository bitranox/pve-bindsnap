#!/usr/bin/perl
# Clone-override tests. Two layers:
#   * _clone_disposition -- the pure clone/carry/exclude/deny decision the patched
#     clone_vm makes for each config option (unit-testable off-node; the full closure
#     needs the live PVE stack, so its end-to-end behaviour is verified on a node instead).
#   * apply_clone wiring -- with a stubbed PVE::API2::LXC, prove apply_clone is
#     idempotent and, off-node (no upstream to hash => TEST mode), leaves the registered
#     clone_vm untouched (CLONE_LOADED=1, CLONE_APPLIED=0, $info->{code} unchanged). The
#     actual $info->{code} mutation on a validated build is covered on-node; here we also
#     prove the mutation MECHANISM (a fresh map_method_by_name lookup sees the new code).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# --- stub PVE::API2::LXC BEFORE the overlay loads, and mark it loaded in %INC so the
#     overlay's `require PVE::API2::LXC` is a no-op. map_method_by_name returns a single
#     shared $info hashref (as the real RESTHandler does), so a mutation is visible via a
#     later lookup. ---
BEGIN {
    package PVE::API2::LXC;    ## no critic
    our %REGISTRY = (
        clone_vm => { name => 'clone_vm', path => '{vmid}/clone', code => sub { 'STOCK' } },
    );
    sub map_method_by_name {
        my ($class, $name) = @_;
        return $PVE::API2::LXC::REGISTRY{$name};
    }
    $INC{'PVE/API2/LXC.pm'} = __FILE__;
}

BEGIN {
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null')   or die "redir STDERR: $!";
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $olderr)      or die "restore STDERR: $!";
}

my $B = 'PVE::LXC::BindSnap';

# === _clone_disposition: the pure clone/carry/exclude/deny rule ===
{
    my $d = $B->can('_clone_disposition');
    is($d->('rootfs', 'volume', {}), 'clone-volume', 'managed rootfs is cloned');
    is($d->('mp0', 'volume', {}),    'clone-volume', 'managed mpN is cloned');
    is($d->('mp0', 'bind', {}, root => 1),   'carry', 'bind mpN is carried for root@pam');
    is($d->('mp0', 'device', {}, root => 1), 'carry', 'device mpN is carried for root@pam');
    is($d->('mp0', 'bind', {}),   'deny', 'bind mpN is denied for a non-root caller');
    is($d->('mp0', 'device', {}), 'deny', 'device mpN is denied for a non-root caller');
    is($d->('mp1', 'bind', { mp1 => 1 }, root => 1), 'exclude', 'excluded bind mpN is dropped');
    is($d->('mp1', 'bind', { mp1 => 1 }), 'exclude', 'excluded bind mpN is dropped for a non-root caller too (not denied)');
    is($d->('mp1', 'bind', { mp1 => 1 }, snapshot => 1, root => 1), 'exclude',
        'excluded bind mpN in a snapshot clone is still dropped');
    is($d->('mp1', 'volume', { mp1 => 1 }), 'clone-volume',
        'live clone: exclude does NOT affect a managed volume (a live volume is always cloned)');
    is($d->('mp1', 'volume', { mp1 => 1 }, snapshot => 1), 'not-in-snapshot',
        'snapshot clone: a managed mpN excluded from the snapshot is left out');
    is($d->('rootfs', 'volume', {}, snapshot => 1), 'clone-volume', 'snapshot clone: managed rootfs is cloned');
    is($d->('rootfs', 'bind', {}, root => 1), 'carry', 'rootfs is never excluded (carried even if bind)');
    is($d->('rootfs', 'bind', {}), 'deny', 'bind rootfs is denied for a non-root caller');
    is($d->('net0', undef, {}),     'copy-other', 'netN is copied as-is');
    is($d->('hostname', undef, {}), 'copy-other', 'a non-mountpoint option is copied as-is');
}

# === _clone_code returns an installable coderef ===
is(ref($B->can('_clone_code')->()), 'CODE', '_clone_code() returns a CODE ref to install as clone_vm {code}');

# === _clone_summary: task-log report (parity with _snapshot_summary) ===
{
    # the "volumes" line is word-wrapped for the task viewer, so flatten whitespace before
    # matching its content (mirrors t/07's warn_text helper).
    my $raw = $B->can('_clone_summary')->(
        vmid => 9001, newid => 9002, vlabel => '6.1.10',
        cloned => ['rootfs', 'mp2'], carried => ['mp0'], excluded => ['mp1'],
    );
    (my $s = $raw) =~ s/\s+/ /g;
    like($raw, qr/clone of CT 9001 -> 9002 \(bind-mount container\)/, 'summary: bind-mount header with vmid->newid');
    like($s, qr/cloned rootfs, mp2/,                'summary: lists cloned managed volumes');
    like($s, qr/carried mp0 \(bind\/device/,        'summary: lists carried bind mounts');
    like($s, qr/excluded mp1 \(BINDSNAP-EXCLUDE\)/, 'summary: lists BINDSNAP-EXCLUDEd mounts');
    like($s, qr/validated -- pve-container 6\.1\.10/, 'summary: checksum line names the validated build');

    (my $n = $B->can('_clone_summary')->(
        vmid => 5, newid => 6, vlabel => '6.1.10', cloned => ['rootfs'],
    )) =~ s/\s+/ /g;
    like($n, qr/no bind\/device mounts -- stock clone, overlay made no change/, 'summary: normal CT clone reported as no-op');
    unlike($n, qr/carried|excluded|left out/, 'summary: normal CT clone names no carried/excluded/left-out mounts');

    (my $ns = $B->can('_clone_summary')->(
        vmid => 5, newid => 6, vlabel => '6.1.10', cloned => ['rootfs'],
        not_in_snapshot => ['mp1', 'mp2'], snapname => 'pre',
    )) =~ s/\s+/ /g;
    like($ns, qr/clone of CT 5 -> 6 \(from snapshot 'pre'; volumes excluded from it left out\)/,
        'summary: snapshot-excluded-only clone has its own header');
    like($ns, qr/left out mp1, mp2 \(excluded from snapshot 'pre', no snapshot data to clone\)/,
        'summary: lists the left-out volumes and the snapshot');
    unlike($ns, qr/stock clone|bind-mount container/, 'summary: left-out clone is not reported as stock or bind');

    (my $m = $B->can('_clone_summary')->(
        vmid => 7, newid => 8, vlabel => '6.1.10', cloned => ['rootfs'],
        carried => ['mp0'], not_in_snapshot => ['mp3'], snapname => 'pre',
    )) =~ s/\s+/ /g;
    like($m, qr/\(bind-mount container\)/, 'summary: mixed carried + left-out uses the bind-mount header');
    like($m, qr/carried mp0 .*left out mp3 \(excluded from snapshot 'pre'/, 'summary: mixed case lists both');
}

# === _clone_not_in_snapshot_warning: the left-out-volume nudge ===
{
    my $w = $B->can('_clone_not_in_snapshot_warning')->(['mp1', 'mp2'], 'pre');
    like($w, qr/clone from snapshot 'pre' left out mp1, mp2/, 'left-out warning: names the snapshot and volumes');
    like($w, qr/BINDSNAP-EXCLUDE/,                            'left-out warning: names the cause');
    is($B->can('_clone_not_in_snapshot_warning')->([], 'pre'), '', 'left-out warning: empty when nothing was left out');
}

# === _clone_carry_warning: the carried-bind nudge ===
{
    my $w = $B->can('_clone_carry_warning')->(['mp0', 'mp3']);
    like($w, qr/carried bind\/device mount\(s\) mp0, mp3/, 'warning: names the carried mounts');
    like($w, qr/SAME host path/,                          'warning: flags shared host paths');
    like($w, qr/#### BINDSNAP-EXCLUDE: mp0 mp3/,           'warning: suggests the exact exclude directive');
    is($B->can('_clone_carry_warning')->([]), '',         'warning: empty when nothing was carried');
}

# === apply_clone, off-node (TEST mode): does NOT override, stays stock ===
my $info = PVE::API2::LXC->map_method_by_name('clone_vm');
my $stock = $info->{code};
{
    open(my $save, '>&', \*STDERR) or die;
    open(STDERR, '>', '/dev/null') or die;
    PVE::LXC::BindSnap::apply_clone();
    open(STDERR, '>&', $save) or die;
}
is($PVE::LXC::BindSnap::CLONE_LOADED, 1, 'apply_clone ran to completion (CLONE_LOADED set)');
is($PVE::LXC::BindSnap::CLONE_APPLIED, 0, 'off-node TEST mode: override NOT installed (CLONE_APPLIED stays 0)');
is($info->{code}, $stock, 'TEST mode left the registered clone_vm {code} untouched');

# === idempotent: a second call is a no-op ===
{
    open(my $save, '>&', \*STDERR) or die;
    open(STDERR, '>', '/dev/null') or die;
    PVE::LXC::BindSnap::apply_clone();
    open(STDERR, '>&', $save) or die;
}
is($info->{code}, $stock, 'apply_clone is idempotent (CLONE_LOADED guard; still untouched)');

# === mechanism sanity: mutating $info->{code} is visible via a fresh lookup ===
# (this is exactly how apply_clone overrides on a validated build, verified on-node)
$info->{code} = sub { 'PATCHED' };
is(PVE::API2::LXC->map_method_by_name('clone_vm')->{code}->(), 'PATCHED',
    'a fresh map_method_by_name lookup sees the mutated code (shared $info ref)');

done_testing();
