#!/usr/bin/perl
# One version for everything shipped: the plugin manifest's "version" and the version
# tools/build-deb.sh stamps into the .deb must both equal BindSnap.pm's $VERSION.
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

my ($mod, $plug, $deb) = versions_of($REPO);
like($mod, qr/^\d+\.\d+\.\d+$/, "BindSnap.pm \$VERSION is X.Y.Z ($mod)");
is($plug, $mod, "$PLUG version equals \$VERSION");
is($deb,  $mod, "$DEB stamps the .deb with \$VERSION");

# Control: the check notices a manifest left behind on a bump.
{
    my $t = tempdir(CLEANUP => 1);
    for my $rel ($MOD, $PLUG, $DEB) {
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
}

done_testing();
