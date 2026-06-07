#!/usr/bin/perl
# The verbose per-snapshot task-log summary: volumes kept/excluded/skipped, checksum
# status, and the BINDSNAP-FORCE-RUNNING/BINDSNAP-UNSUPPORTED status (with brief explanations,
# and a risk note when BINDSNAP-UNSUPPORTED is a STANDING Notes directive). Runs for every
# snapshot; normal CTs get an "n/a" note for the gates.
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

my $fn = PVE::LXC::BindSnap->can('_snapshot_summary')
    or BAIL_OUT('_snapshot_summary missing');

# Stub iterator: $conf is an arrayref of [key => {type=>...}], handed to $func in order.
my $fvf = sub { my ($cls, $conf, $opts, $func) = @_; $func->(@$_) for @$conf; };

# call with sensible defaults; override per case
sub summ {
    return $fn->(
        class => 'LXC', fvf => $fvf, vmid => 99, vlabel => '6.1.10',
        excl => {}, checksum_known => 1, is_bind => 1, running => 0,
        force => 0, force_standing => 0, unsupported => 0, unsupported_standing => 0,
        @_,
    );
}

# --- bind CT, stopped, validated, mp1 excluded, mp3 bind ---
{
    my $s = summ(
        conf => [['rootfs',{type=>'volume'}],['mp1',{type=>'volume'}],['mp2',{type=>'volume'}],['mp3',{type=>'bind'}]],
        excl => {mp1=>1},
    );
    like($s, qr/bind-mount container/,             'bind CT header');
    like($s, qr/kept rootfs, mp2/,                 'kept volumes listed');
    like($s, qr/excluded mp1 \(BINDSNAP-EXCLUDE\)/,    'exclusion listed');
    like($s, qr{skipped mp3 \(bind/device\)},      'bind skip listed');
    like($s, qr/checksum\s*: validated/,           'checksum validated line');
    like($s, qr/BINDSNAP-FORCE-RUNNING\s*: not used/,  'BINDSNAP-FORCE-RUNNING not used (stopped)');
    like($s, qr/BINDSNAP-UNSUPPORTED\s*: not needed/,  'BINDSNAP-UNSUPPORTED not needed (tested build)');
    like($s, qr/\n/,                               'summary is multi-line');
}

# --- bind CT, running with a per-snapshot BINDSNAP-FORCE-RUNNING keyword ---
{
    my $s = summ(conf => [['rootfs',{type=>'volume'}]], running => 1, force => 1);
    like($s, qr/BINDSNAP-FORCE-RUNNING\s*: used/,      'BINDSNAP-FORCE-RUNNING used (running CT)');
    unlike($s, qr/BINDSNAP-FORCE-RUNNING\s*: not used/,'not the "not used" wording');
    unlike($s, qr/BINDSNAP-FORCE-RUNNING\s*: standing/,'keyword path is not flagged standing');
}

# --- bind CT, running, allowed by a STANDING BINDSNAP-FORCE-RUNNING directive in the Notes ---
{
    my $s = summ(conf => [['rootfs',{type=>'volume'}]], running => 1, force => 1, force_standing => 1);
    like($s, qr/BINDSNAP-FORCE-RUNNING\s*: standing/,  'standing directive shown when it allowed a running CT');
    unlike($s, qr/BINDSNAP-FORCE-RUNNING\s*: used/,    'not the per-snapshot "used" wording');
}

# --- bind CT, TEST mode with a per-snapshot BINDSNAP-UNSUPPORTED ---
{
    my $s = summ(conf => [['rootfs',{type=>'volume'}]], checksum_known => 0, unsupported => 1);
    like($s, qr/checksum\s*: TEST mode/,             'TEST mode shown');
    like($s, qr/BINDSNAP-UNSUPPORTED\s*: used/,          'BINDSNAP-UNSUPPORTED used (per-snapshot)');
    unlike($s, qr/BINDSNAP-UNSUPPORTED\s*: STANDING/,    'per-snapshot is not flagged STANDING');
}

# --- bind CT, TEST mode, allowed by a STANDING BINDSNAP-UNSUPPORTED -> risky warning ---
{
    my $s = summ(conf => [['rootfs',{type=>'volume'}]], checksum_known => 0,
                 unsupported => 1, unsupported_standing => 1);
    like($s, qr/BINDSNAP-UNSUPPORTED\s*: STANDING \(risky\)/, 'standing BINDSNAP-UNSUPPORTED flagged risky');
    like($s, qr/FUTURE\s+untested\s+builds/,              'warns it covers future PVE updates (may wrap)');
}

# --- tested build but a standing BINDSNAP-UNSUPPORTED lingers -> latent-risk note ---
{
    my $s = summ(conf => [['rootfs',{type=>'volume'}]], checksum_known => 1, unsupported_standing => 1);
    like($s, qr/BINDSNAP-UNSUPPORTED\s*: not needed now/, 'dormant standing directive noted');
    like($s, qr/consider\s+removing\s+it/,            'suggests removing the lingering directive (may wrap)');
}

# --- normal CT: gates are n/a, overlay made no change ---
{
    my $s = summ(conf => [['rootfs',{type=>'volume'}],['mp0',{type=>'volume'}]], is_bind => 0);
    like($s, qr{no bind/device mounts},           'normal CT header');
    like($s, qr/kept rootfs, mp0/,                'all volumes kept');
    like($s, qr{BINDSNAP-FORCE-RUNNING\s*: n/a},      'BINDSNAP-FORCE-RUNNING n/a for normal CT');
    like($s, qr{BINDSNAP-UNSUPPORTED\s*: n/a},        'BINDSNAP-UNSUPPORTED n/a for normal CT');
}

# --- empty config degrades gracefully ---
like(summ(conf => []), qr/kept nothing/, 'empty config -> kept nothing');

# --- known-bad build: checksum line says known-BAD with the reason ---
{
    my $s = summ(conf => [['rootfs',{type=>'volume'}]], bad => 'snapshot_delete corrupts binds');
    like($s, qr/checksum\s*: known-BAD/,            'known-bad build shown in the summary');
    like($s, qr/snapshot_delete corrupts binds/,    'known-bad reason shown');
    unlike($s, qr/checksum\s*: validated/,          'not the validated wording');
}

# === rollback/delete summary (_op_summary) ===
my $op = PVE::LXC::BindSnap->can('_op_summary') or BAIL_OUT('_op_summary missing');
sub opsum {
    return $op->(class => 'LXC', fvf => $fvf, vmid => 99, snapname => 'snap1',
        op => 'rollback', did => 'reverted', conf => [], excl => {}, @_);
}

is( opsum(
        conf => [['rootfs',{type=>'volume'}],['mp1',{type=>'volume'}],['mp2',{type=>'volume'}],['mp3',{type=>'bind'}]],
        excl => {mp1=>1}),
    "rollback of CT 99 snapshot 'snap1': reverted rootfs, mp2; left mp1 as-is (excluded from this snapshot); bind/device mp3 untouched",
    'rollback summary: acted / left-excluded / skipped-bind');

is( opsum(conf => [['rootfs',{type=>'volume'}],['mp0',{type=>'volume'}]], op => 'delete', did => 'removed'),
    "delete of CT 99 snapshot 'snap1': removed rootfs, mp0",
    'delete summary, no exclusions');

is( opsum(conf => [], op => 'delete', did => 'removed'),
    "delete of CT 99 snapshot 'snap1': removed nothing",
    'empty snapshot config -> removed nothing');

# === shared volume categorization (_categorize_volumes) ===
my $cat = PVE::LXC::BindSnap->can('_categorize_volumes') or BAIL_OUT('_categorize_volumes missing');
{
    my ($kept, $excl, $skip) = $cat->('LXC',
        [['rootfs',{type=>'volume'}],['mp1',{type=>'volume'}],['mp2',{type=>'volume'}],
         ['mp3',{type=>'bind'}],['mp4',{type=>'device'}]],
        $fvf, {mp1=>1});
    is_deeply($kept, ['rootfs','mp2'], 'kept = managed volumes not excluded');
    is_deeply($excl, ['mp1'],          'excluded = volumes in the set');
    is_deeply($skip, ['mp3','mp4'],    'skipped = bind and device mounts');
}
is_deeply([$cat->('LXC', [], $fvf, {})], [[],[],[]], 'empty config -> three empty buckets');
{
    my ($kept, $excl, $skip) = $cat->('LXC', [['mp0',{type=>undef}]], $fvf, {});
    is_deeply($skip, ['mp0'], 'undef type counts as skipped (matches the filter)');
}

# SAFETY: excluding a bind/device mount must not break anything. The type check wins
# over the exclude set (a non-volume is dropped first, before $excl is consulted -- same
# ordering as _make_filter), so naming a bind/device in BINDSNAP-EXCLUDE is harmless: it's
# still just skipped, never acted on as a managed volume, and the real volumes are kept.
{
    my ($kept, $excl, $skip) = $cat->('LXC',
        [['rootfs',{type=>'volume'}],['mp1',{type=>'volume'}],['mp3',{type=>'bind'}],['mp4',{type=>'device'}]],
        $fvf, {mp3=>1, mp4=>1});   # try to exclude the bind AND the device
    is_deeply($kept, ['rootfs','mp1'], 'excluding a bind/device leaves the real volumes kept');
    is_deeply($excl, [],               'a bind/device in the exclude set is NOT treated as excluded');
    is_deeply($skip, ['mp3','mp4'],    'bind/device are simply skipped -- the type check wins over $excl');
}

# === the extracted status-line helpers (_force_line / _unsupported_line), every arm ===
my $fl = PVE::LXC::BindSnap->can('_force_line')       or BAIL_OUT('_force_line missing');
my $ul = PVE::LXC::BindSnap->can('_unsupported_line') or BAIL_OUT('_unsupported_line missing');
like($fl->(is_bind=>0),                                 qr{BINDSNAP-FORCE-RUNNING: n/a}, 'force line: normal CT -> n/a');
like($fl->(is_bind=>1, running=>0),                     qr{BINDSNAP-FORCE-RUNNING: not used}, 'force line: stopped -> not used');
like($fl->(is_bind=>1, running=>1, force_standing=>1),  qr{BINDSNAP-FORCE-RUNNING: standing}, 'force line: standing directive');
like($fl->(is_bind=>1, running=>1, force_standing=>0),  qr{BINDSNAP-FORCE-RUNNING: used}, 'force line: per-snapshot keyword');
like($ul->(is_bind=>0),                                              qr{BINDSNAP-UNSUPPORTED  : n/a}, 'unsupp line: normal CT -> n/a');
like($ul->(is_bind=>1, checksum_known=>0, unsupported_standing=>1),  qr{STANDING \(risky\)}, 'unsupp line: standing untested -> risky');
like($ul->(is_bind=>1, checksum_known=>0, unsupported=>1),           qr{BINDSNAP-UNSUPPORTED  : used}, 'unsupp line: per-snapshot untested -> used');
like($ul->(is_bind=>1, checksum_known=>1, unsupported_standing=>1),  qr{not needed now}, 'unsupp line: dormant standing on a tested build');
like($ul->(is_bind=>1, checksum_known=>1),                           qr{BINDSNAP-UNSUPPORTED  : not needed --}, 'unsupp line: tested, no directive');

done_testing();
