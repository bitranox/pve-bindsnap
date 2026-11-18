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

sub version_cmp {
    my @a = split /\./, $_[0];
    my @b = split /\./, $_[1];
    for my $i (0 .. 2) {
        my $c = $a[$i] <=> $b[$i];
        return $c if $c;
    }
    return 0;
}
sub vsorted      { return sort { version_cmp($a, $b) } @_ }
sub first_build  { return (vsorted(split /, /, $_[0]))[0] }
sub merged_label { my ($label, $ver) = @_; return join(', ', vsorted(split(/, /, $label), $ver)); }

# The cases run on a copy of the repo's LIVE tables, and every vetted release adds real
# rows to them. So no expectation names a real build: the rows a case works on are picked
# from the tree by shape, and the synthetic builds are derived from it so that no new real
# row can collide with them or change their order - three far above the tree's newest
# build (patch + 1001..1003), and one between its two oldest minor series (X.Y.999).
my ($SNAP0, $CLONE0) = module_tables($REPO);
my %TSV_ROW = map { my @c = split /\t/; ($c[0] => \@c) } grep { !/^#/ && length } split /\n/, slurp("$REPO/$TSV");
my @REAL = do {
    my %seen;
    vsorted(grep { !$seen{$_}++ } keys %TSV_ROW,
        map { split /, / } values(%$SNAP0), map { $_->{label} } values(%$CLONE0));
};
my ($MAJ, $MIN, $PAT) = split /\./, $REAL[-1];
my ($NEW1, $NEW2, $UNKNOWN) = map { "$MAJ.$MIN." . ($PAT + 1000 + $_) } 1 .. 3;
my ($MID) = map { $REAL[$_] =~ s/\.\d+$/.999/r }
    grep { ($REAL[$_] =~ s/\.\d+$//r) ne ($REAL[$_ + 1] =~ s/\.\d+$//r) } 0 .. $#REAL - 1;
ok(defined $MID && !grep({ $_ eq $MID } @REAL), 'the real builds span two minor series, with a gap between them')
    or BAIL_OUT('no gap between two minor series of the real builds');

# The rows the cases merge into, by shape: the v6_1_7 clone rows with the oldest and the
# newest first build, and the newest snapshot row that already names several builds.
my @V617 = sort { version_cmp(first_build($CLONE0->{$a}{label}), first_build($CLONE0->{$b}{label})) }
    grep { $CLONE0->{$_}{variant} eq 'v6_1_7' } keys %$CLONE0;
my ($CLONE_A, $CLONE_B) = @V617[0, -1];
my ($SNAP_B) = sort { version_cmp(first_build($SNAP0->{$b}), first_build($SNAP0->{$a})) }
    grep { $SNAP0->{$_} =~ /, / } keys %$SNAP0;
# A real build the refusal cases feed in: the oldest one builds.tsv files under v6_1_7.
my ($BASE) = vsorted(grep { $TSV_ROW{$_}[4] eq 'v6_1_7' } keys %TSV_ROW);
ok(@V617 >= 2 && defined $SNAP_B && defined $BASE, 'the tree has the rows the cases need')
    or BAIL_OUT('the real tables lack a row shape the cases need');
note("synthetic builds $MID, $NEW1, $NEW2, $UNKNOWN; refusals feed $BASE");

# Labels of the module's snapshot table, in file order.
sub module_snap_labels {
    my ($text) = @_;
    my ($block) = $text =~ /^my %KNOWN_GOOD_CHECKSUMS = \(\n(.*?)^\);/ms;
    return map { /=> '([^']+)'/ ? $1 : () } split /\n/, $block // '';
}

# --- the real tables agree with their human mirror (the tool relies on this) ----------
{
    my $doc = slurp("$REPO/$DOC");
    my %ds = map { ($_->[1] =~ s/`//gr) => $_->[0] } @{ doc_rows($doc, $SNAP_H) };
    my %dc = map { ($_->[1] =~ s/`//gr) => $_->[0] } @{ doc_rows($doc, $CLONE_H) };
    is_deeply(\%ds, $SNAP0, 'docs snapshot table mirrors %KNOWN_GOOD_CHECKSUMS (checksums and labels)');
    is_deeply(\%dc, { map { $_ => $CLONE0->{$_}{label} } keys %$CLONE0 },
              'docs clone table mirrors %KNOWN_GOOD_CLONE_CHECKSUMS (checksums and labels)');
}

# --- a new snapshot row + a label merged into an existing clone row -------------------
my $dir = fresh_tree();
add_tsv_row($dir, $MID, $CLONE_A, 'v6_1_7');
my %before = %{ snapshot_files($dir) };
my @args_mid = ('--container', $MID, qw(--guest-common 6.0.3 --pve 9.9.1),
                '--snap', $NEW_SNAP, '--clone', $CLONE_A, '--variant', 'v6_1_7');
{
    my ($rc, $out, $err) = run_tool($dir, @args_mid);
    is($rc, 0, "add $MID: exit 0") or diag $err;
    is($out, qq({"snap":"added","clone":"merged"}\n), "add $MID: one-line JSON summary");

    my $want_label = merged_label($CLONE0->{$CLONE_A}{label}, $MID);
    my ($snap, $clone) = module_tables($dir);
    is($snap->{$NEW_SNAP}, $MID, 'module: new snapshot row carries the version label');
    is($clone->{$CLONE_A}{label}, $want_label, 'module: clone label merged in version order');
    is($clone->{$CLONE_A}{variant}, 'v6_1_7', 'module: clone variant kept');

    my @mlab = module_snap_labels(slurp("$dir/$MOD"));
    my ($mat) = grep { $mlab[$_] eq $MID } 0 .. $#mlab;
    ok(defined $mat && $mat > 0 && $mat < $#mlab, 'module: the new snapshot row lands between two others');
    is_deeply([map { first_build($_) } @mlab], [vsorted(map { first_build($_) } @mlab)],
              'module: snapshot rows stay in version order');
    is(system("'$^X' -I'$dir/lib' -c '$dir/$MOD' >/dev/null 2>&1"), 0, 'module still compiles');

    my $doc  = slurp("$dir/$DOC");
    my @srow = grep { $_->[1] eq "`$NEW_SNAP`" } @{ doc_rows($doc, $SNAP_H) };
    is_deeply(\@srow, [[$MID, "`$NEW_SNAP`", 'E2E-tested on PVE 9.9.1, libpve-guest-common-perl 6.0.3']],
              'docs: new snapshot row with backticked checksum, PVE and guest-common in the notes');
    my @order = map { $_->[0] } @{ doc_rows($doc, $SNAP_H) };
    my ($at) = grep { $order[$_] eq $MID } 0 .. $#order;
    ok(defined $at && $at > 0 && $at < $#order, 'docs: the new snapshot row lands between two others');
    is_deeply([map { first_build($_) } @order], [vsorted(map { first_build($_) } @order)],
              'docs: snapshot rows stay in version order');
    my ($old_crow) = grep { $_->[1] eq "`$CLONE_A`" } @{ doc_rows($before{$DOC}, $CLONE_H) };
    my @crow = grep { $_->[1] eq "`$CLONE_A`" } @{ doc_rows($doc, $CLONE_H) };
    is($crow[0][0], $want_label, 'docs: clone label merged');
    is($crow[0][2], "$old_crow->[2]; $MID E2E-tested on PVE 9.9.1",
       'docs: merged clone row keeps its notes and names where the new build was tested');

    # every other row is unchanged apart from column padding
    my %old = map { $_->[1] => join('|', @$_) } @{ doc_rows($before{$DOC}, $SNAP_H) }, @{ doc_rows($before{$DOC}, $CLONE_H) };
    my %new = map { $_->[1] => join('|', @$_) } @{ doc_rows($doc, $SNAP_H) }, @{ doc_rows($doc, $CLONE_H) };
    delete @new{ "`$NEW_SNAP`", "`$CLONE_A`" };
    delete $old{"`$CLONE_A`"};
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
    my ($rc, $out) = run_tool($dir, @args_mid);
    is($rc, 0, 'second run: exit 0');
    is($out, qq({"snap":"unchanged","clone":"unchanged"}\n), 'second run: nothing to do');
    is_deeply(snapshot_files($dir), \%mid, 'second run: files byte-identical');
}

# --- both merged, then a new clone row ------------------------------------------------
{
    my $d = fresh_tree();
    add_tsv_row($d, $NEW1, $CLONE_B, 'v6_1_7');
    my ($rc, $out, $err) = run_tool($d, '--container', $NEW1, qw(--guest-common 6.0.5 --pve 9.9.2),
        '--snap', $SNAP_B, '--clone', $CLONE_B, '--variant', 'v6_1_7');
    is($rc, 0, "add $NEW1: exit 0") or diag $err;
    is($out, qq({"snap":"merged","clone":"merged"}\n), "add $NEW1: both merged");
    my ($snap, $clone) = module_tables($d);
    is($snap->{$SNAP_B}, merged_label($SNAP0->{$SNAP_B}, $NEW1), 'module: snapshot label merged');
    my $doc = slurp("$d/$DOC");
    my @srow = grep { $_->[1] eq "`$SNAP_B`" } @{ doc_rows($doc, $SNAP_H) };
    like($srow[0][2], qr/; \Q$NEW1\E E2E-tested on PVE 9\.9\.2, libpve-guest-common-perl 6\.0\.5$/,
         'docs: merged snapshot row names PVE and guest-common of the new build');

    my $cnew = 'c' x 64;
    add_tsv_row($d, $NEW2, $cnew, 'v6_1_7');
    ($rc, $out, $err) = run_tool($d, '--container', $NEW2, qw(--guest-common 6.0.5 --pve 9.9.3),
        '--snap', 'b' x 64, '--clone', $cnew, '--variant', 'v6_1_7');
    is($rc, 0, "add $NEW2: exit 0") or diag $err;
    is($out, qq({"snap":"added","clone":"added"}\n), "add $NEW2: two new rows");
    ($snap, $clone) = module_tables($d);
    is_deeply($clone->{$cnew}, { label => $NEW2, variant => 'v6_1_7' }, 'module: new clone row with its variant');
    my @c = @{ doc_rows(slurp("$d/$DOC"), $CLONE_H) };
    is_deeply($c[-1], [$NEW2, "`$cnew`", 'E2E-tested on PVE 9.9.3'], 'docs: new clone row last, in version order');
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

my $BASE_CLONE = $TSV_ROW{$BASE}[2];
my @flags = qw(--guest-common 6.0.3 --pve 9.9.1);
my @base  = ('--container', $BASE, @flags, '--variant', 'v6_1_7', '--clone', $BASE_CLONE);

refused('snapshot checksum on the bad list',
    sub { my $p = "$_[0]/$MOD"; spew($p, slurp($p) =~ s{^    # 'sha256\.\.\.' => 'pve-container X\.Y\.Z: snapshot_delete.*$}{    '$NEW_SNAP' => 'broken',}mr) },
    qr/known-BAD.*$NEW_SNAP/, @base, '--snap', $NEW_SNAP);
refused('clone checksum on the bad list',
    sub { my $p = "$_[0]/$MOD"; spew($p, slurp($p) =~ s{^    # 'sha256\.\.\.' => 'pve-container X\.Y\.Z: clone_vm.*$}{    '$BASE_CLONE' => 'broken',}mr) },
    qr/known-BAD.*\Q$BASE_CLONE\E/, @base, '--snap', $NEW_SNAP);
refused('malformed snapshot checksum', undef, qr/--snap.*not a sha256/, @base, '--snap', 'A' x 64);
refused('short clone checksum', undef, qr/--clone.*not a sha256/,
    '--container', $BASE, @flags, qw(--variant v6_1_7 --clone abc), '--snap', $NEW_SNAP);
refused('malformed version', undef, qr/--container.*not a version/,
    qw(--container 6.1), @flags, qw(--variant v6_1_7), '--clone', $BASE_CLONE, '--snap', $NEW_SNAP);
refused('module anchor missing',
    sub { my $p = "$_[0]/$MOD"; spew($p, slurp($p) =~ s/^my %KNOWN_GOOD_CLONE_CHECKSUMS = \($/my %RENAMED = (/mr) },
    qr/anchor.*KNOWN_GOOD_CLONE_CHECKSUMS/, @base, '--snap', $NEW_SNAP);
refused('docs anchor missing',
    sub { my $p = "$_[0]/$DOC"; spew($p, slurp($p) =~ s/^### Supported \(tested-good\)$/### Renamed/mr) },
    qr/anchor.*### Supported \(tested-good\)/, @base, '--snap', $NEW_SNAP);
refused('variant module missing', undef, qr/variant v9_9_9.*no lib\/PVE\/LXC\/BindSnap\/Clone\/v9_9_9\.pm/,
    '--container', $BASE, @flags, qw(--variant v9_9_9), '--clone', $BASE_CLONE, '--snap', $NEW_SNAP);
refused('build not in builds.tsv', undef, qr/\Q$UNKNOWN\E.*builds\.tsv/,
    '--container', $UNKNOWN, @flags, qw(--variant v6_1_7), '--clone', $BASE_CLONE, '--snap', $NEW_SNAP);
refused('clone checksum disagrees with builds.tsv', undef, qr/builds\.tsv.*\Q$BASE\E/,
    '--container', $BASE, @flags, qw(--variant v6_1_7), '--clone', 'd' x 64, '--snap', $NEW_SNAP);
refused('variant disagrees with builds.tsv', undef, qr/variant.*v6_1_3.*builds\.tsv.*v6_1_7/,
    '--container', $BASE, @flags, qw(--variant v6_1_3), '--clone', $BASE_CLONE, '--snap', $NEW_SNAP);
{
    # the docs label of $SNAP_B cut to its first build, the column width kept
    my $label = $SNAP0->{$SNAP_B};
    my $first = first_build($label);
    refused('module and docs disagree on a label',
        sub {
            my $p = "$_[0]/$DOC";
            my $d = slurp($p);
            $d =~ s/^\| \Q$label\E( *) \| `$SNAP_B`/sprintf('| %-*s | `%s`', length($label) + length($1), $first, $SNAP_B)/me
                or die "no docs row for $SNAP_B";
            spew($p, $d);
        },
        qr/docs.*\Q$first\E.*module.*\Q$label\E/s, @base, '--snap', $SNAP_B);
}

# --- usage error: exit 2 ---------------------------------------------------------------
{
    my $d = fresh_tree();
    my ($rc, undef, $err) = run_tool($d, '--container', $BASE);
    is($rc, 2, 'missing flags: exit 2');
    like($err, qr/usage:/, 'missing flags: prints usage');
}

done_testing();
