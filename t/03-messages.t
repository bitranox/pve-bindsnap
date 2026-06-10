#!/usr/bin/perl
# Load-time status line: validated vs TEST-mode wording and the fields each must carry.
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

my $load_message = PVE::LXC::BindSnap->can('_load_message')
    or BAIL_OUT('_load_message missing');

# validated: tested checksum is in the table
my $valid = $load_message->(1, 'abc123def', '6.1.10');
like(  $valid, qr/checksum-validated/, 'validated line says checksum-validated');
like(  $valid, qr/\b6\.1\.10\b/,       'validated line carries the version label');
like(  $valid, qr/abc123def/,          'validated line carries the combined sha256');
unlike($valid, qr/TEST mode/,          'validated line is NOT TEST mode');

# unvetted: checksum not in the table
my $test = $load_message->(0, 'deadbeefcafe', '6.9.9');
like($test, qr/TEST mode/,        'unvetted line says TEST mode');
like($test, qr/BINDSNAP-UNSUPPORTED/, 'unvetted line names the BINDSNAP-UNSUPPORTED opt-in');
like($test, qr/\b6\.9\.9\b/,      'unvetted line carries the version label');
like($test, qr/deadbeefcafe/,     'unvetted line carries the combined sha256');
like($test, qr{github\.com},      'unvetted line points at the issues URL');

# graceful when the checksum could not be computed
my $nohash = $load_message->(0, undef, 'unknown');
like($nohash, qr/unavailable/, 'undef combined renders as "unavailable"');

# TEST mode lists the per-file hashes (keyed by the resolved module paths)
my $mp = PVE::LXC::BindSnap->can('_module_path') or BAIL_OUT('_module_path missing');
my %per = (
    $mp->('PVE/LXC/Config.pm')     => 'cfgHEXcfg',
    $mp->('PVE/AbstractConfig.pm') => 'absHEXabs',
);
my $detailed = $load_message->(0, 'combHEX', '6.9.9', \%per);
like($detailed, qr/Config\.pm cfgHEXcfg/,         'TEST mode shows the Config.pm per-file hash');
like($detailed, qr/AbstractConfig\.pm absHEXabs/, 'TEST mode shows the AbstractConfig.pm per-file hash');

# known-BAD: a reason is supplied -> BLOCKED line, overrides validated/TEST wording
my $blocked = $load_message->(0, 'badc0ffee', '6.9.9', undef, 'snapshot_delete corrupts binds');
like(  $blocked, qr/BLOCKED/,                       'known-bad line says BLOCKED');
like(  $blocked, qr/known-BAD/,                     'known-bad line names the known-bad list');
like(  $blocked, qr/snapshot_delete corrupts binds/,'known-bad line carries the reason');
like(  $blocked, qr/will NOT override/,             'known-bad line says BINDSNAP-UNSUPPORTED cannot override');
unlike($blocked, qr/TEST mode/,                     'known-bad line is NOT TEST mode');

# _known_good_list: one indented "pve-container <ver>  <checksum>" line per known-good
# entry (multi-line, for the task-log refusal explanations)
my $kgl = PVE::LXC::BindSnap->can('_known_good_list') or BAIL_OUT('_known_good_list missing');
like($kgl->(), qr/pve-container 6\.1\.10/, 'lists the supported version');
like($kgl->(), qr/1ebb1a44483bfdabed59f421c88003673a283cd83cd4009407ce39219faa6106/, 'lists its checksum');

# --- refusal messages (pure, so unit-testable). They are the FULL multi-line explanation
#     printed to the task log (which preserves newlines); snapshot_create dies with a
#     separate short one-line status that PVE puts in TASK ERROR. ---
my $good = "    pve-container 6.1.10  abc123def456";

my $msg_blocked = PVE::LXC::BindSnap->can('_msg_blocked') or BAIL_OUT('_msg_blocked missing');
{
    my $m = $msg_blocked->('6.9.9', 'deadbeef', 'snapshot_delete corrupts binds', $good);
    like($m, qr/known-BAD/,                'blocked: names the known-bad list');
    like($m, qr/will\s+NOT\s+override/,    'blocked: says BINDSNAP-UNSUPPORTED cannot override');
    like($m, qr/BINDSNAP-UNSUPPORTED/,         'blocked: names BINDSNAP-UNSUPPORTED');
    like($m, qr/\b6\.9\.9\b/,              'blocked: carries the version');
    like($m, qr/deadbeef/,                 'blocked: carries the checksum');
    like($m, qr/snapshot_delete corrupts/, 'blocked: carries the reason');
    like($m, qr/\Q$good\E/,                'blocked: shows the known-good list');
    like($m, qr{compatible-versions\.md},  'blocked: links the compatible-versions page');
    like($m, qr{/issues},                  'blocked: links the issues URL');
    like($m, qr/\n/,                        'blocked: multi-line (for the task log)');
}

my $msg_untested = PVE::LXC::BindSnap->can('_msg_untested') or BAIL_OUT('_msg_untested missing');
{
    my $m = $msg_untested->('6.9.9', 'deadbeef', $good);
    like($m, qr/not in the overlay's tested set/, 'untested: gated wording');
    like($m, qr/BINDSNAP-UNSUPPORTED/,                 'untested: names the BINDSNAP-UNSUPPORTED opt-in');
    like($m, qr/\Q$good\E/,                        'untested: shows the known-good list');
    like($m, qr{compatible-versions\.md},          'untested: links the compatible-versions page');
    like($m, qr/works or/,                         'untested: asks to report works or not');
    like($m, qr{/issues},                          'untested: links the issues URL');
    like($m, qr/\n/,                               'untested: multi-line (for the task log)');
}

my $msg_running = PVE::LXC::BindSnap->can('_msg_running') or BAIL_OUT('_msg_running missing');
{
    my $m = $msg_running->(123);
    like($m, qr/CT 123 is running/,      'running: names the CT');
    like($m, qr/BINDSNAP-FORCE-RUNNING/,     'running: names BINDSNAP-FORCE-RUNNING');
    like($m, qr/#### BINDSNAP-FORCE-RUNNING/, 'running: shows the standing Notes directive form');
}

# --- _is_pve_daemon: the routine "overlay active" load banner is gated to the PVE daemons
#     install.sh manages (pvedaemon/pveproxy/pvestatd), so a non-PVE loader (a hookscript,
#     the openvmm VM helper, an interactive pct) does NOT print it. Decided from $0. ---
my $is_daemon = PVE::LXC::BindSnap->can('_is_pve_daemon') or BAIL_OUT('_is_pve_daemon missing');
{
    for my $name ('/usr/bin/pvedaemon', '/usr/bin/pveproxy', '/usr/bin/pvestatd',
                  'pvedaemon worker', 'pveproxy') {
        local $0 = $name;
        ok($is_daemon->(), "_is_pve_daemon TRUE for '$name'");
    }
    for my $name ('/usr/local/bin/ovm', '/usr/sbin/pct', 'pct', '-e', 'perl',
                  'pvedaemonX', 'mypvedaemon-helper') {
        local $0 = $name;
        ok(!$is_daemon->(), "_is_pve_daemon FALSE for '$name'");
    }
}

done_testing();
