#!/usr/bin/perl
# Clone-override tests. Two layers:
#   * _clone_disposition -- the pure carry/exclude decision the patched clone_vm makes
#     for each config option (unit-testable off-node; the full closure needs the live
#     PVE stack, so its end-to-end behaviour is verified on a node instead).
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

# === _clone_disposition: the pure carry/exclude rule ===
is($B->can('_clone_disposition')->('rootfs', 'volume', {}), 'clone-volume', 'managed rootfs is cloned');
is($B->can('_clone_disposition')->('mp0', 'volume', {}),    'clone-volume', 'managed mpN is cloned');
is($B->can('_clone_disposition')->('mp0', 'bind', {}),      'carry',        'bind mpN is carried');
is($B->can('_clone_disposition')->('mp0', 'device', {}),    'carry',        'device mpN is carried');
is($B->can('_clone_disposition')->('mp1', 'bind', { mp1 => 1 }), 'exclude',  'excluded bind mpN is dropped');
is($B->can('_clone_disposition')->('mp1', 'volume', { mp1 => 1 }), 'clone-volume',
    'exclude does NOT affect a managed volume in clone (type wins; a volume is always cloned)');
is($B->can('_clone_disposition')->('rootfs', 'bind', {}), 'carry', 'rootfs is never excluded (carried even if bind)');
is($B->can('_clone_disposition')->('net0', undef, {}),    'copy-other', 'netN is copied as-is');
is($B->can('_clone_disposition')->('hostname', undef, {}), 'copy-other', 'a non-mountpoint option is copied as-is');

# === _clone_code returns an installable coderef ===
is(ref($B->can('_clone_code')->('6.1.10')), 'CODE', '_clone_code() returns a CODE ref to install as clone_vm {code}');

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
    unlike($n, qr/carried|excluded/, 'summary: normal CT clone names no carried/excluded mounts');
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
