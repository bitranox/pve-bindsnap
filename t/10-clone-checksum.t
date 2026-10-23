#!/usr/bin/perl
# Clone guard: _clone_block extracts exactly the clone_vm register_method block, and
# _clone_checksum hashes it, reproducing the documented awk|sha256sum pipeline.
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
my $clone_block    = $pkg->can('_clone_block')    or BAIL_OUT('_clone_block missing');
my $clone_checksum = $pkg->can('_clone_checksum') or BAIL_OUT('_clone_checksum missing');

sub tmpfile {
    my ($content) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    binmode $fh;
    print $fh $content;
    close $fh;
    return $path;
}

my $head = <<'EOT';
package PVE::API2::LXC;

use strict;
use warnings;

EOT

my $before = <<'EOT';
__PACKAGE__->register_method({
    name => 'vmlist',
    path => '',
    code => sub {
        return [];
    }});

EOT

my $clone = <<'EOT';
__PACKAGE__->register_method({
    name => 'clone_vm',
    path => '{vmid}/clone',
    method => 'POST',
    code => sub {
        my ($param) = @_;
        die "mountpoint type not supported\n";
    },
});
EOT

my $after = <<'EOT';

__PACKAGE__->register_method({
    name => 'migrate_vm',
    path => '{vmid}/migrate',
    code => sub {
        return undef;
    },
});

1;
EOT

my $file = tmpfile($head . $before . $clone . $after);

# 1. the block is exactly the middle method
is($clone_block->($file), $clone, '_clone_block returns exactly the clone_vm block');

# 2. checksum == sha256 of the block == the documented pipeline
my $sum = $clone_checksum->($file);
is($sum, sha256_hex($clone), '_clone_checksum == sha256_hex of the block');

# The documented awk|sha256sum pipeline over PATH; only called when $can_pipe is true.
my $have = sub { system("command -v $_[0] >/dev/null 2>&1") == 0 };
my $can_pipe = $have->('awk') && $have->('sha256sum');
sub pipeline_sum {
    my ($path) = @_;
    my $cmd = q{awk '/^__PACKAGE__->register_method\(\{$/{hit=0; buf=""} {buf=buf $0 "\n"} }
            . q{/^    name => .clone_vm.,$/{hit=1} hit&&/^\}\);$/{printf "%s", buf; exit}' '}
            . $path . q{' | sha256sum | awk '{print $1}'};
    my $out = `$cmd`;
    chomp $out;
    return $out;
}

SKIP: {
    skip 'awk or sha256sum not available', 1 unless $can_pipe;
    is($sum, pipeline_sum($file),
        '_clone_checksum reproduces the documented awk|sha256sum pipeline');
}

# 2b. the name line matches any quote character, as the awk's `.clone_vm.` does
{
    (my $dq = $clone) =~ s/'clone_vm'/"clone_vm"/;
    my $f = tmpfile($head . $before . $dq . $after);
    is($clone_block->($f), $dq, 'a double-quoted name => "clone_vm" is still the clone_vm block');
  SKIP: {
        skip 'awk or sha256sum not available', 1 unless $can_pipe;
        is($clone_checksum->($f), pipeline_sum($f), 'double-quoted name: checksum == awk pipeline');
    }
}

# 2c. a final `});` with no trailing newline: awk still emits "\n" after it, so must we
{
    (my $bare = $clone) =~ s/\n\z//;
    my $f = tmpfile($head . $before . $bare);
    is($clone_block->($f), $clone, 'final }); without a newline: block ends in "\n" like awk');
  SKIP: {
        skip 'awk or sha256sum not available', 1 unless $can_pipe;
        is($clone_checksum->($f), pipeline_sum($f),
            'no trailing newline: checksum == awk pipeline');
    }
}

# 3. edits outside the block don't matter; edits inside do
{
    (my $other = $before) =~ s/return \[\];/return [1];/;
    my $f = tmpfile($head . "use POSIX;\n" . $other . $clone . $after . "# trailer\n");
    is($clone_checksum->($f), $sum, 'editing text outside the block leaves the checksum unchanged');
}
{
    (my $changed = $clone) =~ s/not supported/unsupported/;
    my $f = tmpfile($head . $before . $changed . $after);
    isnt($clone_checksum->($f), $sum, 'editing a line inside the block changes the checksum');
}

# 4. no block => undef
ok(!defined $clone_checksum->("$file.does-not-exist"), 'undef for a missing file');
ok(!defined $clone_block->(tmpfile($head . $before . $after)), 'undef for a file without clone_vm');
{
    (my $open = $clone) =~ s/^\}\);\n//m;
    ok(!defined $clone_checksum->(tmpfile($head . $before . $open)),
        'undef when the clone_vm block never reaches });');
}
{
    # clone_vm block closed by `}});` (not a bare `});`) must not run on into the next method
    (my $glued = $clone) =~ s/^    \},\n\}\);\n/    }});\n/m;
    isnt($glued, $clone, 'fixture: clone_vm block now ends in }});');
    ok(!defined $clone_block->(tmpfile($head . $before . $glued . $after)),
        'undef when clone_vm ends in }}); and another method follows');
}

done_testing();
