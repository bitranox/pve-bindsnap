#!/usr/bin/perl
# Every apt path reloads the PVE daemons exactly once. pve-manager's file trigger on
# /usr/share/perl5/PVE reloads them after any dpkg run that changes a file there, this
# package's own install, upgrade and removal included; a second reload of ours a moment
# later can catch pveproxy mid-restart, and systemd then loses it and leaves it stopped.
# So the maintainer scripts reload only when that trigger will not.
#
# Each case runs the real debian/postinst or debian/postrm under sh against a scratch
# root (DPKG_ROOT) and admin dir (DPKG_ADMINDIR, read by the real dpkg-query), with
# systemctl, dpkg-divert and the preflight perl replaced by recorders on PATH.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $REPO = "$FindBin::Bin/..";
my $TREE = '/usr/share/perl5/PVE';

plan skip_all => 'dpkg-query not available' if system('command -v dpkg-query >/dev/null 2>&1') != 0;

sub spew {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "write $path: $!";
    print {$fh} $text;
    close($fh) or die "close $path: $!";
}

sub slurp {
    my ($p) = @_;
    open(my $fh, '<', $p) or return '';
    local $/;
    return scalar <$fh>;
}

# One scratch node. Options: manager (installed pve-manager), pending (its file trigger
# is pending in this dpkg run), watches (its interest is registered), pem (cluster cert
# present), install_mode, systemd (a running systemd), preflight_fails (the overlay does not
# load, so configure exits 1).
sub node {
    my (%o) = (manager => 1, pending => 1, watches => 1, pem => 1, install_mode => 0, systemd => 1,
               preflight_fails => 0, @_);
    my $dir   = tempdir(CLEANUP => 1);
    my $root  = "$dir/root";
    my $admin = "$dir/admin";
    my $bin   = "$dir/bin";
    make_path("$root/etc/pve/local", "$admin/info", "$admin/updates", "$admin/triggers", $bin);
    make_path("$root/run/systemd/system") if $o{systemd};
    spew("$root/etc/pve/local/pve-ssl.pem", "cert\n") if $o{pem};
    spew("$root/proxmox_install_mode", "")            if $o{install_mode};
    my $status = '';
    if ($o{manager}) {
        $status = "Package: pve-manager\n"
          . 'Status: install ok ' . ($o{pending} ? 'triggers-pending' : 'installed') . "\n"
          . "Maintainer: x <x\@example.org>\nArchitecture: amd64\nVersion: 9.2.2\n"
          . ($o{pending} ? "Triggers-Pending: $TREE\n" : '')
          . "Description: x\n\n";
    }
    spew("$admin/status",    $status);
    spew("$admin/available", '');
    spew("$admin/triggers/File", ($o{manager} && $o{watches} ? "$TREE pve-manager/noawait\n" : '')
          . "$TREE/LXC pve-bindsnap/noawait\n");
    for my $tool (qw(systemctl dpkg-divert)) {
        spew("$bin/$tool", "#!/bin/sh\necho \"$tool \$*\" >> \"$dir/calls\"\n");
        chmod 0755, "$bin/$tool";
    }
    # The overlay preflight: records its arguments, and on failure prints a line to stderr as
    # the wrapper's eval guard does when the overlay does not load.
    my $loads = $o{preflight_fails} ? 1 : 0;
    my $fail  = $loads ? "echo 'pve-bindsnap: overlay not loaded (Insecure dependency, stub)' >&2\n" : '';
    spew("$bin/perl", "#!/bin/sh\necho \"perl \$*\" >> \"$dir/calls\"\n${fail}exit $loads\n");
    chmod 0755, "$bin/perl";
    return {dir => $dir, root => $root, admin => $admin, bin => $bin, rc => $loads};
}

# Run a maintainer script on a node: (calls it made, its output).
sub run_script {
    my ($n, $script, @args) = @_;
    local $ENV{PATH}          = "$n->{bin}:$ENV{PATH}";
    local $ENV{DPKG_ROOT}     = $n->{root};
    local $ENV{DPKG_ADMINDIR} = $n->{admin};
    local $ENV{LC_ALL}        = 'C';
    my $out = `sh '$REPO/debian/$script' @args 2>&1`;
    is($? >> 8, $n->{rc}, "$script @args exits $n->{rc}");
    return (slurp("$n->{dir}/calls"), $out);
}

sub reloads {
    my ($calls) = @_;
    my @r = $calls =~ /^systemctl reload-or-try-restart pvedaemon pveproxy pvestatd$/mg;
    return scalar @r;
}

subtest 'configure: pve-manager trigger pending in this run, no reload of ours' => sub {
    my ($calls, $out) = run_script(node(), 'postinst', 'configure');
    is(reloads($calls), 0, 'no systemctl reload');
    like($out, qr/reloaded by pve-manager/, 'the apt log says who reloads');
};

# A failed preflight leaves the wrappers loading the overlay eval-guarded, so the daemons
# run stock code even when pve-manager's trigger reloads them; the message must not claim
# that nothing reloads them.
subtest 'configure with a failed preflight: exits 1, reloads nothing itself, says stock' => sub {
    my ($calls, $out) = run_script(node(preflight_fails => 1), 'postinst', 'configure');
    is(reloads($calls), 0, 'no systemctl reload');
    unlike($out, qr/NOT reloaded/, 'does not claim the daemons stay unreloaded');
    like($out, qr/overlay is not active/, 'says the overlay is not active');
    like($out, qr/stock behaviour/, 'says Proxmox keeps stock behaviour');
    like($out, qr/reload/, 'says a daemon reload keeps it stock');
    like($out, qr/Insecure dependency, stub/, "prints perl's own error, which names the cause");
};

# The daemons and pct load PVE::LXC::Config under perl -T (taint mode), where a module can
# fail that loads fine without it, so the preflight must load it the same way.
subtest 'the preflight loads the overlay under perl -T' => sub {
    my ($calls) = run_script(node(), 'postinst', 'configure');
    my @pre = grep { /^perl / && /APPLIED|CLONE_LOADED/ } split /\n/, $calls;
    is(scalar @pre, 2, 'two preflight loads (snapshot and clone)');
    ok(!grep({ !/^perl -T / } @pre), 'both run under -T') or diag(join "\n", @pre);
};

subtest 'configure without the pending trigger (dpkg-reconfigure) reloads' => sub {
    my ($calls) = run_script(node(pending => 0), 'postinst', 'configure');
    is(reloads($calls), 1, 'one reload');
};

subtest 'configure reloads where pve-manager trigger exits early' => sub {
    is(reloads((run_script(node(pem => 0),          'postinst', 'configure'))[0]), 1, 'no cluster cert');
    is(reloads((run_script(node(install_mode => 1), 'postinst', 'configure'))[0]), 1, 'install mode');
};

subtest 'configure without pve-manager reloads' => sub {
    is(reloads((run_script(node(manager => 0), 'postinst', 'configure'))[0]), 1, 'one reload');
};

subtest 'configure outside a running systemd reloads nothing' => sub {
    is(reloads((run_script(node(systemd => 0, pending => 0), 'postinst', 'configure'))[0]), 0, 'no reload');
};

# pve-bindsnap's own interest (PVE/LXC, AbstractConfig.pm) lies under pve-manager's, so
# pve-manager's trigger fires in the same run, before or after this one; its pending
# state cannot tell which, the registered interest can.
subtest 'triggered: pve-manager watches the tree, no reload of ours' => sub {
    my ($calls) = run_script(node(pending => 0), 'postinst', 'triggered', "$TREE/LXC");
    is(reloads($calls), 0, 'no reload');
};

subtest 'triggered without pve-manager interest reloads' => sub {
    is(reloads((run_script(node(watches => 0, pending => 0), 'postinst', 'triggered', "$TREE/LXC"))[0]),
        1, 'one reload');
    is(reloads((run_script(node(pem => 0), 'postinst', 'triggered', "$TREE/LXC"))[0]), 1, 'no cluster cert');
};

subtest 'remove: trigger pending, undivert both, no reload of ours' => sub {
    my ($calls, $out) = run_script(node(), 'postrm', 'remove');
    is(reloads($calls), 0, 'no reload');
    is(() = $calls =~ /^dpkg-divert .*--remove/mg, 2, 'both modules undiverted');
    like($out, qr/reloaded by pve-manager/, 'the apt log says who reloads');
};

subtest 'remove without the pending trigger reloads' => sub {
    is(reloads((run_script(node(pending => 0), 'postrm', 'remove'))[0]), 1, 'one reload');
};

subtest 'abort-install keeps its own reload' => sub {
    is(reloads((run_script(node(), 'postrm', 'abort-install'))[0]), 1, 'one reload');
};

done_testing();
