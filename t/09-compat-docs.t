#!/usr/bin/perl
# docs/compatible-versions.md mirrors the module's checksum tables for humans: the good tables
# must agree hash => version label, the bad tables on their hash sets, and every key must be a
# well-formed sha256. A new build added to one place but not the other fails here.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# Load the overlay quietly: its load-time _apply() tries to require
# PVE::LXC::Config (absent off-node) and logs one harmless line to STDERR.
BEGIN {
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null')   or die "redir STDERR: $!";
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $olderr)      or die "restore STDERR: $!";
}

our (%KNOWN_GOOD_CHECKSUMS, %KNOWN_BAD_CHECKSUMS,
    %KNOWN_GOOD_CLONE_CHECKSUMS, %KNOWN_BAD_CLONE_CHECKSUMS);
*KNOWN_GOOD_CHECKSUMS       = \%PVE::LXC::BindSnap::KNOWN_GOOD_CHECKSUMS;
*KNOWN_BAD_CHECKSUMS        = \%PVE::LXC::BindSnap::KNOWN_BAD_CHECKSUMS;
*KNOWN_GOOD_CLONE_CHECKSUMS = \%PVE::LXC::BindSnap::KNOWN_GOOD_CLONE_CHECKSUMS;
*KNOWN_BAD_CLONE_CHECKSUMS  = \%PVE::LXC::BindSnap::KNOWN_BAD_CLONE_CHECKSUMS;

my $doc = "$FindBin::Bin/../docs/compatible-versions.md";
open(my $fh, '<', $doc) or BAIL_OUT("cannot read $doc: $!");
my @lines = <$fh>;
close $fh;
chomp @lines;

# Rows of the table under the first heading line equal to $heading at or after line $from.
# A data row is `| <version> | `<64-hex>` | <notes> |`; `(none yet)` rows yield nothing.
# Returns (\%hash_to_version, next_line_index).
sub table_after {
    my ($heading, $from) = @_;
    my $i = $from;
    $i++ while $i < @lines && $lines[$i] ne $heading;
    BAIL_OUT("heading '$heading' not found in $doc") if $i >= @lines;
    my %rows;
    for ($i++; $i < @lines && $lines[$i] !~ /^#/; $i++) {
        next unless $lines[$i] =~ /^\|\s*(\S+)\s*\|\s*`([0-9a-f]{64})`\s*\|/;
        BAIL_OUT("duplicate hash $2 under '$heading'") if exists $rows{$2};
        $rows{$2} = $1;
    }
    return (\%rows, $i);
}

my ($snap_good, $i) = table_after('## Supported (tested-good)', 0);
my ($snap_bad)      = table_after('## Hard-blocked (known-bad)', $i);
my ($clone_start)   = grep { $lines[$_] eq '## Clone support (separate guard)' } 0 .. $#lines;
BAIL_OUT("clone section not found in $doc") unless defined $clone_start;
my ($clone_good, $j) = table_after('### Supported (tested-good)', $clone_start);
my ($clone_bad)      = table_after('### Hard-blocked (known-bad)', $j);

ok(scalar(keys %$snap_good), 'doc snapshot good table is not empty');
ok(scalar(keys %$clone_good), 'doc clone good table is not empty');

is_deeply($snap_good, {%KNOWN_GOOD_CHECKSUMS},
    'snapshot known-good: doc matches module (hash => version)');
is_deeply([sort keys %$snap_bad], [sort keys %KNOWN_BAD_CHECKSUMS],
    'snapshot known-bad: doc matches module');
is_deeply($clone_good, {%KNOWN_GOOD_CLONE_CHECKSUMS},
    'clone known-good: doc matches module (hash => version)');
is_deeply([sort keys %$clone_bad], [sort keys %KNOWN_BAD_CLONE_CHECKSUMS],
    'clone known-bad: doc matches module');

my %tables = (
    KNOWN_GOOD_CHECKSUMS       => \%KNOWN_GOOD_CHECKSUMS,
    KNOWN_BAD_CHECKSUMS        => \%KNOWN_BAD_CHECKSUMS,
    KNOWN_GOOD_CLONE_CHECKSUMS => \%KNOWN_GOOD_CLONE_CHECKSUMS,
    KNOWN_BAD_CLONE_CHECKSUMS  => \%KNOWN_BAD_CLONE_CHECKSUMS,
);
for my $name (sort keys %tables) {
    my @bad = grep { !/^[0-9a-f]{64}$/ } keys %{$tables{$name}};
    is(scalar(@bad), 0, "$name: every key is 64 lowercase hex") or diag("bad keys: @bad");
}

done_testing;
