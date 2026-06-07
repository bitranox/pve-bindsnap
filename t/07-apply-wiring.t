#!/usr/bin/perl
# Integration test for the WIRING that the pure-helper tests don't reach: _apply()
# redefining PVE::LXC::Config::{snapshot_create,delete,rollback,has_feature} via
# typeglobs, and the _make_filter closure dropping bind/device + BINDSNAP-EXCLUDEd volumes
# through the real call chain. We stub the PVE method surface the overlay captures
# (foreach_volume_full / has_feature / snapshot_* / load_config / __snapshot_check_running),
# load the overlay so _apply() wires against the stub, then exercise the redefined methods.
#
# No real upstream files exist off-node, so the combined checksum is unavailable =>
# the overlay runs in TEST mode (bind-mount CTs need BINDSNAP-UNSUPPORTED). That's fine: the
# validated-checksum branch is covered by t/01 + on-node; here we prove the wiring.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempfile);
use lib "$FindBin::Bin/../lib";

# --- stub PVE::LXC::Config BEFORE the overlay loads, and mark it loaded in %INC so the
#     overlay's `require PVE::LXC::Config` is a no-op. A conf is a hashref with _vols
#     (arrayref of [key => {type=>...}]), description (the CT Notes), and _running. ---
BEGIN {
    package PVE::LXC::Config;    ## no critic
    our @CREATE   = ();
    our @DELETE   = ();
    our @ROLLBACK = ();
    our %CONF     = ();

    sub foreach_volume_full {
        my ($class, $conf, $opts, $func, @param) = @_;
        for my $v (@{ $conf->{_vols} // [] }) { $func->($v->[0], $v->[1], @param); }
    }
    # stock-like: snapshot feature is false if ANY mountpoint is non-'volume'
    sub has_feature {
        my ($class, $feature, $conf, @rest) = @_;
        return 1 if !defined($feature) || $feature ne 'snapshot';
        my $ok = 1;
        $class->foreach_volume_full($conf, undef,
            sub { my (undef, $v) = @_; $ok = 0 if (($v->{type} // '') ne 'volume'); });
        return $ok;
    }
    sub load_config { return $PVE::LXC::Config::CONF{ $_[1] }; }
    sub __snapshot_check_running { return $PVE::LXC::Config::CONF{ $_[1] }{_running} ? 1 : 0; }

    # the three "upstream" snapshot ops: record the volumes that reach them by iterating
    # via foreach_volume_full -- which the overlay localises to its filter for the call.
    sub _seen { my ($class, $vmid) = @_; my @s;
        $class->foreach_volume_full($class->load_config($vmid), {}, sub { push @s, $_[0]; });
        return \@s; }
    sub snapshot_create {
        my ($class, $vmid, $snapname, $svm, $comment) = @_;
        push @PVE::LXC::Config::CREATE,
            { vmid => $vmid, snapname => $snapname, comment => $comment, vols => $class->_seen($vmid) };
        return 'created';
    }
    sub snapshot_delete {
        my ($class, $vmid, $snapname, @rest) = @_;
        push @PVE::LXC::Config::DELETE, { vmid => $vmid, snapname => $snapname, vols => $class->_seen($vmid) };
        return 'deleted';
    }
    sub snapshot_rollback {
        my ($class, $vmid, $snapname, @rest) = @_;
        push @PVE::LXC::Config::ROLLBACK, { vmid => $vmid, snapname => $snapname, vols => $class->_seen($vmid) };
        return 'rolledback';
    }
    $INC{'PVE/LXC/Config.pm'} = __FILE__;
}

BEGIN {
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null')   or die "redir STDERR: $!";
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $olderr)      or die "restore STDERR: $!";
}

# run a call with the overlay's STDERR chatter (banner / refusal block / summary)
# suppressed; return (ok, err) so dying gates can be asserted.
sub run_quiet {
    my ($code) = @_;
    open(my $save, '>&', \*STDERR) or die;
    open(STDERR, '>', '/dev/null') or die;
    my $ok  = eval { $code->(); 1 };
    my $err = $@;
    open(STDERR, '>&', $save) or die;
    return ($ok, $err);
}

# run a call capturing STDERR (to assert the WARN nudge); returns the text. Uses a real temp
# file because STDERR (fd 2) can't be reopened onto an in-memory scalar.
sub capture_stderr {
    my ($code) = @_;
    my (undef, $tmp) = tempfile(UNLINK => 1, OPEN => 0);
    open(my $save, '>&', \*STDERR) or die;
    open(STDERR, '>', $tmp) or die;
    eval { $code->() };
    open(STDERR, '>&', $save) or die;    # restore, flushing the temp file
    open(my $rd, '<', $tmp) or die;
    local $/;
    my $buf = <$rd> // '';
    close($rd);
    return $buf;
}

# isolate the WARN block (everything before the summary, which starts "...snapshot of CT")
# and flatten whitespace, so phrase checks work even though the WARN is wrapped across lines.
sub warn_text {
    my ($err) = @_;
    $err =~ s/pve-bindsnap: snapshot of CT.*//s;   # drop the summary block onward
    $err =~ s/\s+/ /g;
    return $err;
}

my $C = 'PVE::LXC::Config';
sub reset_log { @PVE::LXC::Config::CREATE = (); @PVE::LXC::Config::DELETE = (); @PVE::LXC::Config::ROLLBACK = (); }

# --- the overlay actually wired itself against the stub -------------------------------
is($PVE::LXC::BindSnap::APPLIED, 1, '_apply() ran and wired the overlay against the stub');
isnt($C->can('snapshot_create'), PVE::LXC::Config->can('_seen'), 'snapshot_create was redefined (typeglob install)');

# canned configs
my $normal = { description => '', _running => 0,
    _vols => [['rootfs',{type=>'volume'}], ['mp0',{type=>'volume'}]] };
my $bind = sub { my ($running, $notes) = @_; return { description => ($notes//''), _running => $running,
    _vols => [['rootfs',{type=>'volume'}], ['mp1',{type=>'volume'}], ['mp2',{type=>'volume'}], ['mp3',{type=>'bind'}]] }; };

# === 1) NORMAL CT (no binds): passes through untouched, no gating ===
{
    reset_log();
    $PVE::LXC::Config::CONF{1} = $normal;
    my ($ok, $err) = run_quiet(sub { $C->snapshot_create(1, 'n1', 0, undef) });
    ok($ok, 'normal CT: snapshot_create proceeds (no BINDSNAP-UNSUPPORTED needed)') or diag $err;
    is_deeply($PVE::LXC::Config::CREATE[0]{vols}, ['rootfs','mp0'], 'normal CT: all volumes pass to upstream');
    is($PVE::LXC::Config::CREATE[0]{comment}, undef, 'normal CT: comment untouched');
}

# === 2) BIND CT, TEST mode, NO marker -> gated (untested) ===
{
    reset_log();
    $PVE::LXC::Config::CONF{2} = $bind->(0, '');
    my ($ok, $err) = run_quiet(sub { $C->snapshot_create(2, 'b1', 0, undef) });
    ok(!$ok, 'bind CT, untested, no marker: REFUSED');
    like($err, qr/untested/, 'gate cites the untested build');
    is(scalar(@PVE::LXC::Config::CREATE), 0, 'upstream snapshot_create was NOT called');
}

# === 3) BIND CT + BINDSNAP-UNSUPPORTED, stopped -> proceeds; filter drops the bind ===
{
    reset_log();
    $PVE::LXC::Config::CONF{2} = $bind->(0, '');
    my ($ok, $err) = run_quiet(sub { $C->snapshot_create(2, 'b2', 0, 'BINDSNAP-UNSUPPORTED') });
    ok($ok, 'bind CT + BINDSNAP-UNSUPPORTED (stopped): proceeds') or diag $err;
    is_deeply($PVE::LXC::Config::CREATE[0]{vols}, ['rootfs','mp1','mp2'], 'filter dropped the bind mp3');
    is($PVE::LXC::Config::CREATE[0]{comment}, 'BINDSNAP-UNSUPPORTED', 'marker kept in the comment');
}

# === 3b) the untested-build snapshot emits a WARN nudge (-> yellow TASK WARNINGS on a node) ===
{
    reset_log();
    $PVE::LXC::Config::CONF{2} = $bind->(0, '');
    my $w = warn_text(capture_stderr(sub { $C->snapshot_create(2, 'b2w', 0, 'BINDSNAP-UNSUPPORTED') }));
    like($w, qr/WARN:/,                     'per-snapshot untested snapshot emits a WARN line');
    like($w, qr/UNTESTED pve-container build/, 'WARN names it an untested build');
    like($w, qr{/issues},                   'WARN points at the issues URL to report it');
    unlike($w, qr/standing/,                'per-snapshot WARN does not claim a standing directive');
}

# === 3c) standing BINDSNAP-UNSUPPORTED on an untested build -> WARN also flags the standing risk ===
{
    reset_log();
    $PVE::LXC::Config::CONF{2} = $bind->(0, "#### BINDSNAP-UNSUPPORTED");
    my $w = warn_text(capture_stderr(sub { $C->snapshot_create(2, 'b2s', 0, undef) }));
    like($w, qr/WARN:/,                     'standing untested snapshot emits a WARN line');
    like($w, qr/standing BINDSNAP-UNSUPPORTED/, 'WARN flags the standing directive');
    like($w, qr/future\s+untested\s+builds/, 'WARN warns it covers future builds');
    like($w, qr/CT 2\b/,                    'WARN names the CT (no $vmid apostrophe gotcha)');
}

# The fourth branch (tested build + a dormant standing BINDSNAP-UNSUPPORTED -> WARN nudges
# removal) needs checksum_known=true, which is impossible off-node (no real upstream to hash),
# so it is verified on a node instead; t/06 covers its summary wording ("not needed now").

# === 4) BIND CT, running, no BINDSNAP-FORCE-RUNNING -> gated (running) ===
{
    reset_log();
    $PVE::LXC::Config::CONF{3} = $bind->(1, '');
    my ($ok, $err) = run_quiet(sub { $C->snapshot_create(3, 'b3', 0, 'BINDSNAP-UNSUPPORTED') });
    ok(!$ok, 'bind CT running, no BINDSNAP-FORCE-RUNNING: REFUSED');
    like($err, qr/running/, 'gate cites the running CT');
}

# === 5) BIND CT, running + BINDSNAP-FORCE-RUNNING -> proceeds ===
{
    reset_log();
    $PVE::LXC::Config::CONF{3} = $bind->(1, '');
    my ($ok, $err) = run_quiet(sub { $C->snapshot_create(3, 'b4', 0, 'BINDSNAP-UNSUPPORTED BINDSNAP-FORCE-RUNNING') });
    ok($ok, 'bind CT running + BINDSNAP-FORCE-RUNNING: proceeds') or diag $err;
    is_deeply($PVE::LXC::Config::CREATE[0]{vols}, ['rootfs','mp1','mp2'], 'still drops the bind');
}

# === 5b) STANDING BINDSNAP-FORCE-RUNNING in the Notes (no per-snapshot marker) -> proceeds ===
{
    reset_log();
    $PVE::LXC::Config::CONF{3} = $bind->(1, "#### BINDSNAP-FORCE-RUNNING");
    my ($ok, $err) = run_quiet(sub { $C->snapshot_create(3, 'b5', 0, 'BINDSNAP-UNSUPPORTED') });
    ok($ok, 'running bind CT allowed by a STANDING BINDSNAP-FORCE-RUNNING in the Notes') or diag $err;
}

# === 6) BINDSNAP-EXCLUDE in the Notes: excluded volume dropped AND frozen into the comment ===
{
    reset_log();
    $PVE::LXC::Config::CONF{4} = $bind->(0, "notes\n#### BINDSNAP-EXCLUDE: mp1");
    my ($ok, $err) = run_quiet(sub { $C->snapshot_create(4, 'b6', 0, 'BINDSNAP-UNSUPPORTED') });
    ok($ok, 'bind CT with a CT-default BINDSNAP-EXCLUDE: proceeds') or diag $err;
    is_deeply($PVE::LXC::Config::CREATE[0]{vols}, ['rootfs','mp2'], 'filter dropped excluded mp1 AND bind mp3');
    like($PVE::LXC::Config::CREATE[0]{comment}, qr/#### BINDSNAP-EXCLUDE: mp1/, 'CT-default exclude frozen into the snapshot comment');
}

# === 7) has_feature('snapshot') -> overlay hides binds so a bind CT reports capable ===
{
    $PVE::LXC::Config::CONF{2} = $bind->(0, '');
    # sanity: the raw (unfiltered) iterator really does carry a bind that stock would reject
    my $raw_has_bind = 0;
    $C->foreach_volume_full($bind->(0,''), undef, sub { $raw_has_bind = 1 if (($_[1]{type}//'') ne 'volume'); });
    ok($raw_has_bind, 'precondition: the bind conf really contains a non-volume mount');
    my ($ok, $feat) = (undef, undef);
    (my $r, my $e) = run_quiet(sub { $feat = $C->has_feature('snapshot', $bind->(0,'')); });
    ok($feat, 'has_feature(snapshot) is TRUE for a bind CT (overlay hid the bind during the check)');
    (run_quiet(sub { $feat = $C->has_feature('snapshot', $normal) }));
    ok($feat, 'has_feature(snapshot) is TRUE for a normal CT too');
}

# === 8) delete / rollback route through the filter (excludes read from the conf desc) ===
{
    reset_log();
    $PVE::LXC::Config::CONF{5} = $bind->(0, "#### BINDSNAP-EXCLUDE: mp1");
    my ($okd) = run_quiet(sub { $C->snapshot_delete(5, 'b6') });
    ok($okd, 'snapshot_delete proceeds');
    is_deeply($PVE::LXC::Config::DELETE[0]{vols}, ['rootfs','mp2'], 'delete drops bind mp3 + excluded mp1 (from the conf description)');
    my ($okr) = run_quiet(sub { $C->snapshot_rollback(5, 'b6') });
    ok($okr, 'snapshot_rollback proceeds');
    is_deeply($PVE::LXC::Config::ROLLBACK[0]{vols}, ['rootfs','mp2'], 'rollback drops bind mp3 + excluded mp1');
}

# === 9) vzdump snapname bypasses the overlay entirely (straight to upstream) ===
{
    reset_log();
    $PVE::LXC::Config::CONF{2} = $bind->(0, '');
    my ($ok) = run_quiet(sub { $C->snapshot_create(2, 'vzdump', 0, undef) });
    ok($ok, "snapname 'vzdump' bypasses gating (backup path is stock)");
    is_deeply($PVE::LXC::Config::CREATE[0]{vols}, ['rootfs','mp1','mp2','mp3'],
        'vzdump path is unfiltered -- binds NOT dropped (stock handles backup exclusion)');
}

done_testing();
