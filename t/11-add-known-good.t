#!/usr/bin/perl
# tools/add-known-good.pl: adds a vetted build to both guard tables of BindSnap.pm and to
# docs/compatible-versions.md. Every case runs the tool on a COPY of the real files in a
# temp dir, so the tables it edits are the real ones, never the repo's own.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Basename qw(dirname);

my $REPO = "$FindBin::Bin/..";
my $MOD  = 'lib/PVE/LXC/BindSnap.pm';
my $DOC  = 'docs/compatible-versions.md';
my $TSV  = 't/fixtures/clone_vm/builds.tsv';
my $TOOL = 'tools/add-known-good.pl';
my @COPY = ($MOD, $DOC, $TSV, $TOOL, map { "lib/PVE/LXC/BindSnap/Clone/$_.pm" } qw(v6_0_17 v6_0_19 v6_1_3 v6_1_7));

sub slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or die "read $p: $!";
    local $/;
    return scalar <$fh>;
}

sub spew {
    my ($p, $d) = @_;
    open(my $fh, '>:raw', $p) or die "write $p: $!";
    print {$fh} $d;
    close $fh or die "write $p: $!";
}

sub fresh_tree {
    my $dir = tempdir(CLEANUP => 1);
    for my $rel (@COPY) {
        make_path(dirname("$dir/$rel"));
        copy("$REPO/$rel", "$dir/$rel") or die "copy $rel: $!";
    }
    return $dir;
}

# Run the tool inside tree $dir; returns (exit code, stdout, stderr).
sub run_tool {
    my ($dir, @args) = @_;
    my $out = "$dir/.out";
    my $err = "$dir/.err";
    system("'$^X' '$dir/$TOOL' " . join(' ', map { "'$_'" } @args) . " >'$out' 2>'$err'");
    return ($? >> 8, slurp($out), slurp($err));
}

sub snapshot_files {
    my ($dir) = @_;
    return { map { $_ => slurp("$dir/$_") } ($MOD, $DOC) };
}

sub add_tsv_row {
    my ($dir, $ver, $clone, $var) = @_;
    my $tsv = slurp("$dir/$TSV");
    $tsv .= join("\t", $ver, 'f' x 64, $clone, 'e' x 64, $var) . "\n";
    spew("$dir/$TSV", $tsv);
}

# Cells of every row of the markdown table that follows the line $heading, padding trimmed.
sub doc_rows {
    my ($doc, $heading) = @_;
    my @lines = split /\n/, $doc;
    my ($i) = grep { $lines[$_] eq $heading } 0 .. $#lines;
    return [] if !defined $i;
    $i++ while $i <= $#lines && $lines[$i] !~ /^\|/;
    my @rows;
    for (my $j = $i + 2; $j <= $#lines && $lines[$j] =~ /^\|/; $j++) {
        my @c = map { s/^\s+|\s+$//gr } split /\|/, $lines[$j];
        shift @c;
        push @rows, \@c;
    }
    return \@rows;
}

# Load the tree's module in a child perl and return its two good tables.
sub module_tables {
    my ($dir) = @_;
    my $script = tempdir(CLEANUP => 1) . '/tables.pl';
    spew($script, <<'PL');
open(STDERR, '>', '/dev/null');
require PVE::LXC::BindSnap;
my %c = %{ PVE::LXC::BindSnap::_clone_variant_table() };
print "C\t$_\t$c{$_}{label}\t$c{$_}{variant}\n" for sort keys %c;
print "S\t$_\n" for split /\n/, PVE::LXC::BindSnap::_known_good_list();
PL
    my $got = `'$^X' -I'$dir/lib' '$script'`;
    my (%snap, %clone);
    for (split /\n/, $got) {
        if (/^C\t(\S+)\t([^\t]+)\t(\S+)$/) { $clone{$1} = { label => $2, variant => $3 }; }
        elsif (/^S\t\s+pve-container (.+?)  ([0-9a-f]{64})$/) { $snap{$2} = $1; }
    }
    return (\%snap, \%clone);
}

my $SNAP_H  = '## Supported (tested-good)';
my $CLONE_H = '### Supported (tested-good)';
my $NEW_SNAP = 'a' x 64;

# --- the real tables agree with their human mirror (the tool relies on this) ----------
{
    my $doc = slurp("$REPO/$DOC");
    my ($snap, $clone) = module_tables($REPO);
    my %ds = map { ($_->[1] =~ s/`//gr) => $_->[0] } @{ doc_rows($doc, $SNAP_H) };
    my %dc = map { ($_->[1] =~ s/`//gr) => $_->[0] } @{ doc_rows($doc, $CLONE_H) };
    is_deeply(\%ds, $snap, 'docs snapshot table mirrors %KNOWN_GOOD_CHECKSUMS (checksums and labels)');
    is_deeply(\%dc, { map { $_ => $clone->{$_}{label} } keys %$clone },
              'docs clone table mirrors %KNOWN_GOOD_CLONE_CHECKSUMS (checksums and labels)');
}

# --- a new snapshot row + a label merged into an existing clone row -------------------
my $dir = fresh_tree();
my %before = %{ snapshot_files($dir) };
my @args_618 = (qw(--container 6.1.8 --guest-common 6.0.3 --pve 9.9.1),
                '--snap', $NEW_SNAP,
                '--clone', '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198',
                '--variant', 'v6_1_7');
{
    my ($rc, $out, $err) = run_tool($dir, @args_618);
    is($rc, 0, 'add 6.1.8: exit 0') or diag $err;
    is($out, qq({"snap":"added","clone":"merged"}\n), 'add 6.1.8: one-line JSON summary');

    my ($snap, $clone) = module_tables($dir);
    is($snap->{$NEW_SNAP}, '6.1.8', 'module: new snapshot row carries the version label');
    is($clone->{'8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198'}{label},
       '6.1.7, 6.1.8, 6.1.9, 6.1.10, 6.1.11', 'module: clone label merged in version order');
    is($clone->{'8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198'}{variant},
       'v6_1_7', 'module: clone variant kept');

    my $mod = slurp("$dir/$MOD");
    like($mod, qr/'e963f8e465ca4314691a5695316878b36ba3284242f98abe6b48f54953bb0365' => '6\.1\.7',\n    '$NEW_SNAP' => '6\.1\.8',\n    '9edba4fe/,
         'module: new snapshot row inserted in version order (after 6.1.7, before 6.1.9)');
    is(system("'$^X' -I'$dir/lib' -c '$dir/$MOD' >/dev/null 2>&1"), 0, 'module still compiles');

    my $doc  = slurp("$dir/$DOC");
    my @srow = grep { $_->[1] eq "`$NEW_SNAP`" } @{ doc_rows($doc, $SNAP_H) };
    is_deeply(\@srow, [['6.1.8', "`$NEW_SNAP`", 'E2E-tested on PVE 9.9.1, libpve-guest-common-perl 6.0.3']],
              'docs: new snapshot row with backticked checksum, PVE and guest-common in the notes');
    my @order = map { $_->[0] } @{ doc_rows($doc, $SNAP_H) };
    my ($at) = grep { $order[$_] eq '6.1.8' } 0 .. $#order;
    is_deeply([@order[$at - 1, $at + 1]], ['6.1.7', '6.1.9'], 'docs: snapshot row in version order');
    my @crow = grep { $_->[1] eq '`8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198`' }
        @{ doc_rows($doc, $CLONE_H) };
    is($crow[0][0], '6.1.7, 6.1.8, 6.1.9, 6.1.10, 6.1.11', 'docs: clone label merged');
    like($crow[0][2], qr/^E2E-tested on PVE 9\.1\.1 and 9\.2\.2; 6\.1\.8 E2E-tested on PVE 9\.9\.1$/,
         'docs: merged clone row keeps its notes and names where the new build was tested');

    # every other row is unchanged apart from column padding
    my %old = map { $_->[1] => join('|', @$_) } @{ doc_rows($before{$DOC}, $SNAP_H) }, @{ doc_rows($before{$DOC}, $CLONE_H) };
    my %new = map { $_->[1] => join('|', @$_) } @{ doc_rows($doc, $SNAP_H) }, @{ doc_rows($doc, $CLONE_H) };
    delete @new{ "`$NEW_SNAP`", '`8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198`' };
    delete $old{'`8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198`'};
    is_deeply(\%new, \%old, 'docs: every other row is unchanged');

    # the tables stay aligned: every row of a table is as wide as its header
    for my $h ($SNAP_H, $CLONE_H) {
        my @l = split /\n/, $doc;
        my ($i) = grep { $l[$_] eq $h } 0 .. $#l;
        $i++ while $l[$i] !~ /^\|/;
        my @t;
        push @t, $l[$i++] while $i <= $#l && $l[$i] =~ /^\|/;
        my %w = map { length($_) => 1 } @t;
        is(scalar keys %w, 1, "docs: '$h' table rows share one width");
    }
}

# --- idempotent ---------------------------------------------------------------------
{
    my %mid = %{ snapshot_files($dir) };
    my ($rc, $out) = run_tool($dir, @args_618);
    is($rc, 0, 'second run: exit 0');
    is($out, qq({"snap":"unchanged","clone":"unchanged"}\n), 'second run: nothing to do');
    is_deeply(snapshot_files($dir), \%mid, 'second run: files byte-identical');
}

# --- both merged, then a new clone row ------------------------------------------------
{
    my $d = fresh_tree();
    add_tsv_row($d, '6.1.18', 'ed915d4f9d205a460379a0f0746434eba6cbaf331759eeb76202e47a5caf1947', 'v6_1_7');
    my ($rc, $out, $err) = run_tool($d, qw(--container 6.1.18 --guest-common 6.0.5 --pve 9.9.2),
        '--snap', '3c7e8deb78600666b7462529721d00054b7a41b3b506c798c21a17351ff48998',
        '--clone', 'ed915d4f9d205a460379a0f0746434eba6cbaf331759eeb76202e47a5caf1947', '--variant', 'v6_1_7');
    is($rc, 0, 'add 6.1.18: exit 0') or diag $err;
    is($out, qq({"snap":"merged","clone":"merged"}\n), 'add 6.1.18: both merged');
    my ($snap, $clone) = module_tables($d);
    is($snap->{'3c7e8deb78600666b7462529721d00054b7a41b3b506c798c21a17351ff48998'}, '6.1.15, 6.1.16, 6.1.18',
       'module: snapshot label merged');
    my $doc = slurp("$d/$DOC");
    my @srow = grep { $_->[0] =~ /6\.1\.18/ } @{ doc_rows($doc, $SNAP_H) };
    like($srow[0][2], qr/; 6\.1\.18 E2E-tested on PVE 9\.9\.2, libpve-guest-common-perl 6\.0\.5$/,
         'docs: merged snapshot row names PVE and guest-common of the new build');

    my $c19 = 'c' x 64;
    add_tsv_row($d, '6.1.19', $c19, 'v6_1_7');
    ($rc, $out, $err) = run_tool($d, qw(--container 6.1.19 --guest-common 6.0.5 --pve 9.9.3),
        '--snap', 'b' x 64, '--clone', $c19, '--variant', 'v6_1_7');
    is($rc, 0, 'add 6.1.19: exit 0') or diag $err;
    is($out, qq({"snap":"added","clone":"added"}\n), 'add 6.1.19: two new rows');
    ($snap, $clone) = module_tables($d);
    is_deeply($clone->{$c19}, { label => '6.1.19', variant => 'v6_1_7' }, 'module: new clone row with its variant');
    my @c = @{ doc_rows(slurp("$d/$DOC"), $CLONE_H) };
    is_deeply($c[-1], ['6.1.19', "`$c19`", 'E2E-tested on PVE 9.9.3'], 'docs: new clone row last, in version order');
}

# --- refusals: exit 1, a clear message, nothing written ---------------------------------
sub refused {
    my ($name, $prep, $want, @args) = @_;
    my $d = fresh_tree();
    $prep->($d) if $prep;
    my %pre = %{ snapshot_files($d) };
    my ($rc, $out, $err) = run_tool($d, @args);
    is($rc, 1, "$name: exit 1");
    like($err, $want, "$name: says why");
    is($out, '', "$name: no summary");
    is_deeply(snapshot_files($d), \%pre, "$name: nothing written");
}

my @base = (qw(--container 6.1.8 --guest-common 6.0.3 --pve 9.9.1 --variant v6_1_7),
            '--clone', '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198');

refused('snapshot checksum on the bad list',
    sub { my $p = "$_[0]/$MOD"; spew($p, slurp($p) =~ s{^    # 'sha256\.\.\.' => 'pve-container X\.Y\.Z: snapshot_delete.*$}{    '$NEW_SNAP' => 'broken',}mr) },
    qr/known-BAD.*$NEW_SNAP/, @base, '--snap', $NEW_SNAP);
refused('clone checksum on the bad list',
    sub { my $p = "$_[0]/$MOD"; spew($p, slurp($p) =~ s{^    # 'sha256\.\.\.' => 'pve-container X\.Y\.Z: clone_vm.*$}{    '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198' => 'broken',}mr) },
    qr/known-BAD.*8408885e/, @base, '--snap', $NEW_SNAP);
refused('malformed snapshot checksum', undef, qr/--snap.*not a sha256/, @base, '--snap', 'A' x 64);
refused('short clone checksum', undef, qr/--clone.*not a sha256/,
    qw(--container 6.1.8 --guest-common 6.0.3 --pve 9.9.1 --variant v6_1_7 --clone abc), '--snap', $NEW_SNAP);
refused('malformed version', undef, qr/--container.*not a version/,
    qw(--container 6.1 --guest-common 6.0.3 --pve 9.9.1 --variant v6_1_7),
    '--clone', '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198', '--snap', $NEW_SNAP);
refused('module anchor missing',
    sub { my $p = "$_[0]/$MOD"; spew($p, slurp($p) =~ s/^my %KNOWN_GOOD_CLONE_CHECKSUMS = \($/my %RENAMED = (/mr) },
    qr/anchor.*KNOWN_GOOD_CLONE_CHECKSUMS/, @base, '--snap', $NEW_SNAP);
refused('docs anchor missing',
    sub { my $p = "$_[0]/$DOC"; spew($p, slurp($p) =~ s/^### Supported \(tested-good\)$/### Renamed/mr) },
    qr/anchor.*### Supported \(tested-good\)/, @base, '--snap', $NEW_SNAP);
refused('variant module missing', undef, qr/variant v9_9_9.*no lib\/PVE\/LXC\/BindSnap\/Clone\/v9_9_9\.pm/,
    qw(--container 6.1.8 --guest-common 6.0.3 --pve 9.9.1 --variant v9_9_9),
    '--clone', '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198', '--snap', $NEW_SNAP);
refused('build not in builds.tsv', undef, qr/6\.1\.77.*builds\.tsv/,
    qw(--container 6.1.77 --guest-common 6.0.3 --pve 9.9.1 --variant v6_1_7),
    '--clone', '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198', '--snap', $NEW_SNAP);
refused('clone checksum disagrees with builds.tsv', undef, qr/builds\.tsv.*6\.1\.8/,
    qw(--container 6.1.8 --guest-common 6.0.3 --pve 9.9.1 --variant v6_1_7), '--clone', 'd' x 64, '--snap', $NEW_SNAP);
refused('variant disagrees with builds.tsv', undef, qr/variant.*v6_1_3.*builds\.tsv.*v6_1_7/,
    qw(--container 6.1.8 --guest-common 6.0.3 --pve 9.9.1 --variant v6_1_3),
    '--clone', '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198', '--snap', $NEW_SNAP);
refused('module and docs disagree on a label',
    sub { my $p = "$_[0]/$DOC"; spew($p, slurp($p) =~ s/\| 6\.1\.15, 6\.1\.16    /| 6.1.15            /r) },
    qr/docs.*6\.1\.15.*module.*6\.1\.15, 6\.1\.16/s,
    qw(--container 6.1.8 --guest-common 6.0.3 --pve 9.9.1 --variant v6_1_7),
    '--clone', '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198',
    '--snap', '3c7e8deb78600666b7462529721d00054b7a41b3b506c798c21a17351ff48998');

# --- usage error: exit 2 ---------------------------------------------------------------
{
    my $d = fresh_tree();
    my ($rc, undef, $err) = run_tool($d, qw(--container 6.1.8));
    is($rc, 2, 'missing flags: exit 2');
    like($err, qr/usage:/, 'missing flags: prints usage');
}

done_testing();
