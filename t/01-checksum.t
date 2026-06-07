#!/usr/bin/perl
# Checksum helpers: _sha256_file matches coreutils, and the combined digest
# reproduces both the internal formula and the documented shell pipeline.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);

# Load the overlay quietly: its load-time _apply() tries to require
# PVE::LXC::Config (absent off-node) and logs one harmless line to STDERR.
BEGIN {
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null')   or die "redir STDERR: $!";
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $olderr)      or die "restore STDERR: $!";
}

my $pkg = 'PVE::LXC::BindSnap';
my $sha256_file    = $pkg->can('_sha256_file')    or BAIL_OUT('_sha256_file missing');
my $config_checksum = $pkg->can('_config_checksum') or BAIL_OUT('_config_checksum missing');

# two temp files with known content (UNLINK removes them at program exit)
sub tmpfile {
    my ($content) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    binmode $fh;
    print $fh $content;
    close $fh;
    return $path;
}

my $c1 = "alpha content\n";
my $c2 = "beta content\nsecond line\n";
my $f1 = tmpfile($c1);
my $f2 = tmpfile($c2);

# 1. _sha256_file == `sha256sum`
{
    my $got  = $sha256_file->($f1);
    my $want = (split ' ', `sha256sum '$f1'`)[0];
    is($got, $want, '_sha256_file equals coreutils sha256sum');
}

# 2. combined reproduces the internal formula and the documented pipeline
{
    my $h1 = sha256_hex($c1);
    my $h2 = sha256_hex($c2);
    my $expect_internal = sha256_hex("$h1\n$h2\n");

    my ($combined, $per) = $config_checksum->($f1, $f2);
    is($combined, $expect_internal,
        'combined == sha256_hex of per-file hexes joined by newlines');
    is($per->{$f1}, $h1, 'per-file hex for file 1');
    is($per->{$f2}, $h2, 'per-file hex for file 2');

    # the README's manual command must produce the same value, byte-for-byte
    my $cmd = q{printf '%s\n' "$(sha256sum '} . $f1
            . q{' | awk '{print $1}')" "$(sha256sum '} . $f2
            . q{' | awk '{print $1}')" | sha256sum};
    my $pipeline = (split ' ', `$cmd`)[0];
    is($combined, $pipeline, 'combined reproduces the documented printf|sha256sum pipeline');
}

# 3. fail-safe: any unreadable file => combined undef
{
    my $missing = "$f1.does-not-exist";
    my ($combined, $per) = $config_checksum->($f1, $missing);
    ok(!defined $combined, 'combined is undef when a file cannot be hashed');
    ok(!defined $per->{$missing}, "missing file's per-file hex is undef");
}

# 4. order matters (it is part of the contract)
{
    my ($ab) = $config_checksum->($f1, $f2);
    my ($ba) = $config_checksum->($f2, $f1);
    isnt($ab, $ba, 'file order changes the combined digest (load-bearing order)');
}

done_testing();
