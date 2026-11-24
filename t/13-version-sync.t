#!/usr/bin/perl
# One version for everything shipped: the plugin manifest's "version", the version
# tools/build-deb.sh stamps into the .deb, and the release line at the top of README.md must
# all equal BindSnap.pm's $VERSION, and so must the module's banner line `# pve-bindsnap ... (X.Y.Z)`:
# the auto-vet's release bump rewrites that line and refuses a module whose banner names another
# version. tools/build-apt-repo.sh reads the version with a copy of build-deb.sh's
# module_version(), kept identical here.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Basename qw(dirname);
use JSON::PP qw(decode_json);

my $REPO = "$FindBin::Bin/..";
my $MOD  = 'lib/PVE/LXC/BindSnap.pm';
my $PLUG = '.claude-plugin/plugin.json';
my $DEB  = 'tools/build-deb.sh';
my $APT  = 'tools/build-apt-repo.sh';
my $RDME = 'README.md';

sub slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or die "read $p: $!";
    local $/;
    return scalar <$fh>;
}

# The three versions as tree $root states them: the module's $VERSION (as perl sees it),
# plugin.json's "version", and what build-deb.sh's own module_version() extracts.
sub versions_of {
    my ($root) = @_;
    my $mod = `'$^X' -I'$root/lib' -e 'open(STDERR, ">", "/dev/null"); require PVE::LXC::BindSnap; print \$PVE::LXC::BindSnap::VERSION'`;
    my $plug = decode_json(slurp("$root/$PLUG"))->{version};
    my $fn = join("\n", grep { /^module_version\(\) \{$/ .. /^\}$/ } split /\n/, slurp("$root/$DEB"));
    die "no module_version() in $DEB\n" if !length $fn;
    open(my $sh, '-|', 'bash', '-c', "$fn\nMODULE='$root/$MOD'\nmodule_version") or die "bash: $!";
    my $deb = do { local $/; <$sh> };
    close $sh;
    chomp($deb //= '');
    return ($mod, $plug, $deb);
}

# The X.Y.Z of every "> Release X.Y.Z." line in tree $root's README.
sub readme_releases {
    my ($root) = @_;
    return slurp("$root/$RDME") =~ /^> Release (\d+\.\d+\.\d+)\./mg;
}

# The X.Y.Z of every banner line `# pve-bindsnap   (X.Y.Z)` in tree $root's module.
sub banner_versions {
    my ($root) = @_;
    return slurp("$root/$MOD") =~ /^# pve-bindsnap\s+\((\d+\.\d+\.\d+)\)$/mg;
}

sub module_version_fn {
    my ($rel) = @_;
    return join("\n", grep { /^module_version\(\) \{$/ .. /^\}$/ } split /\n/, slurp("$REPO/$rel"));
}

my ($mod, $plug, $deb) = versions_of($REPO);
like($mod, qr/^\d+\.\d+\.\d+$/, "BindSnap.pm \$VERSION is X.Y.Z ($mod)");
is($plug, $mod, "$PLUG version equals \$VERSION");
is($deb,  $mod, "$DEB stamps the .deb with \$VERSION");
is_deeply([readme_releases($REPO)], [$mod], "$RDME has one release line, naming \$VERSION");
is_deeply([banner_versions($REPO)], [$mod], "$MOD has one banner line, naming \$VERSION");
ok(length module_version_fn($APT), "$APT has a module_version()");
is(module_version_fn($APT), module_version_fn($DEB), "$APT reads the version as $DEB does");

# Control: the check notices a manifest left behind on a bump.
{
    my $t = tempdir(CLEANUP => 1);
    for my $rel ($MOD, $PLUG, $DEB, $RDME) {
        make_path(dirname("$t/$rel"));
        copy("$REPO/$rel", "$t/$rel") or die "copy $rel: $!";
    }
    my $j = slurp("$t/$PLUG");
    $j =~ s/"version": "[^"]*"/"version": "0.0.1"/ or die 'no version in plugin.json';
    open(my $fh, '>:raw', "$t/$PLUG") or die $!;
    print {$fh} $j;
    close $fh;
    my ($m2, $p2) = versions_of($t);
    isnt($p2, $m2, 'control: a stale plugin.json version is told apart from $VERSION');

    my $r = slurp("$t/$RDME");
    $r =~ s/^> Release \d+\.\d+\.\d+\./> Release 0.0.1./m or die 'no release line in README.md';
    open($fh, '>:raw', "$t/$RDME") or die $!;
    print {$fh} $r;
    close $fh;
    isnt(join(',', readme_releases($t)), $m2, 'control: a stale README release line is told apart from $VERSION');

    my $b = slurp("$t/$MOD");
    $b =~ s/^(# pve-bindsnap\s+)\(\d+\.\d+\.\d+\)$/${1}(0.0.1)/m or die 'no banner line in BindSnap.pm';
    open($fh, '>:raw', "$t/$MOD") or die $!;
    print {$fh} $b;
    close $fh;
    isnt(join(',', banner_versions($t)), $m2, 'control: a stale banner line is told apart from $VERSION');
}

done_testing();
