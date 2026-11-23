#!/usr/bin/perl
# tools/build-apt-repo.sh with no arguments indexes only the deb of the checkout's own $VERSION.
# dist/ keeps the debs of earlier builds, and a release carries only the new one, so an index
# that also named an old deb would point apt at a file the release does not have. Explicit
# arguments are indexed as given (the e2e harness builds a two-version repository that way).
# Runs the real script in a temp tree with a throwaway signing key and minimal debs.
use strict;
use warnings;
use FindBin;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);

my $REPO = "$FindBin::Bin/..";

# A developer box may lack these tools and skips; CI installs them, so there a missing tool is
# a failure, never a silent skip of the check the release depends on.
for my $tool (qw(gpg gpgv dpkg-deb dpkg-scanpackages apt-ftparchive)) {
    next if system("command -v $tool >/dev/null 2>&1") == 0;
    BAIL_OUT("$tool not installed (CI must provide it)") if $ENV{CI};
    plan skip_all => "$tool not installed";
}

sub slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or die "read $p: $!";
    local $/;
    return scalar <$fh>;
}

sub spit {
    my ($p, $text) = @_;
    open(my $fh, '>:raw', $p) or die "write $p: $!";
    print {$fh} $text;
    close $fh or die "close $p: $!";
}

sub sh {
    my ($cmd) = @_;
    system('bash', '-c', $cmd) == 0 or die "failed: $cmd\n";
}

my ($VERSION) = slurp("$REPO/lib/PVE/LXC/BindSnap.pm") =~ /^our \$VERSION = '([^']+)';$/m;
ok(defined $VERSION, "the module states its \$VERSION ($VERSION)");

# One throwaway key for every case: secret part for signing, public part as the tree's
# published keyring, which the script verifies its signatures against.
my $keys = tempdir(CLEANUP => 1);
my $gh   = "$keys/gnupg";
mkdir $gh, 0700 or die $!;
sh("gpg --homedir '$gh' --batch --quiet --passphrase '' --quick-gen-key 'test <test\@example.invalid>' ed25519 sign never 2>/dev/null");
sh("gpg --homedir '$gh' --batch --quiet --armor --export-secret-keys > '$keys/secret.asc'");
sh("gpg --homedir '$gh' --batch --quiet --armor --export > '$keys/public.asc'");
sh("gpgconf --homedir '$gh' --kill all 2>/dev/null || true");

sub make_deb {
    my ($dir, $version) = @_;
    my $stage = tempdir(CLEANUP => 1);
    make_path("$stage/DEBIAN");
    spit("$stage/DEBIAN/control", join("\n",
        'Package: pve-bindsnap', "Version: $version", 'Architecture: all',
        'Maintainer: test <test@example.invalid>', 'Description: test package', ''));
    my $deb = "$dir/pve-bindsnap_${version}_all.deb";
    sh("dpkg-deb --root-owner-group --build '$stage' '$deb' >/dev/null");
    return $deb;
}

# A tree holding the script, the module it reads the version from, and the test keyring.
sub tree {
    my $t = tempdir(CLEANUP => 1);
    make_path("$t/tools", "$t/lib/PVE/LXC", "$t/apt", "$t/dist");
    copy("$REPO/tools/build-apt-repo.sh", "$t/tools/build-apt-repo.sh") or die $!;
    copy("$REPO/lib/PVE/LXC/BindSnap.pm", "$t/lib/PVE/LXC/BindSnap.pm") or die $!;
    copy("$keys/public.asc", "$t/apt/pve-bindsnap-archive-keyring.asc") or die $!;
    return $t;
}

# Run the script in tree $t with @args; returns (exit code, stderr, Packages text or undef).
sub run_repo {
    my ($t, @args) = @_;
    my $out = "$t/out";
    my $argv = join(' ', map {"'$_'"} @args);
    my $err = `BINDSNAP_APT_KEY_FILE='$keys/secret.asc' APT_DIR='$out' bash '$t/tools/build-apt-repo.sh' $argv 2>&1 >/dev/null`;
    my $rc = $? >> 8;
    my $pk = -e "$out/Packages" ? slurp("$out/Packages") : undef;
    return ($rc, $err, $pk);
}

sub versions {
    my ($pk) = @_;
    my @v = ($pk // '') =~ /^Version: (\S+)$/mg;
    return [sort @v];
}

subtest 'no arguments: only the deb of $VERSION is indexed' => sub {
    my $t = tree();
    make_deb("$t/dist", '0.0.1');
    make_deb("$t/dist", $VERSION);
    my ($rc, $err, $pk) = run_repo($t);
    is($rc, 0, 'exits 0') or diag($err);
    is_deeply(versions($pk), [$VERSION], "Packages lists $VERSION only");
    ok(!-e "$t/out/pve-bindsnap_0.0.1_all.deb", 'the old deb is not copied into the repository');
    like($err, qr/pve-bindsnap_0\.0\.1_all\.deb/, 'stderr names the ignored deb');
};

subtest 'no arguments and no deb of $VERSION: refused' => sub {
    my $t = tree();
    make_deb("$t/dist", '0.0.1');
    my ($rc, $err, $pk) = run_repo($t);
    isnt($rc, 0, 'exits non-zero');
    like($err, qr/pve-bindsnap_\Q$VERSION\E_all\.deb/, 'stderr names the missing deb');
    like($err, qr{tools/build-deb\.sh}, 'stderr says how to build it');
    ok(!defined $pk, 'no Packages file is written');
};

subtest 'explicit arguments are indexed as given' => sub {
    my $t = tree();
    my $old = make_deb("$t/dist", '0.0.1');
    my $new = make_deb("$t/dist", $VERSION);
    my ($rc, $err, $pk) = run_repo($t, $old, $new);
    is($rc, 0, 'exits 0') or diag($err);
    is_deeply(versions($pk), [sort '0.0.1', $VERSION], 'Packages lists both');
};

done_testing();
