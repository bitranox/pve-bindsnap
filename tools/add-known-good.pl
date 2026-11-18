#!/usr/bin/perl
# pve-bindsnap -- add a vetted pve-container build to the known-good tables.
# Copyright (C) 2026 bitranox
# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   tools/add-known-good.pl --container VER --guest-common VER --pve VER \
#                           --snap SHA --clone SHA --variant NAME
#
# Writes the build into BOTH guard tables of lib/PVE/LXC/BindSnap.pm
# (%KNOWN_GOOD_CHECKSUMS sha => label, %KNOWN_GOOD_CLONE_CHECKSUMS sha => {label, variant})
# and into their human mirror, docs/compatible-versions.md (snapshot and clone tables).
# A checksum that already has a row gets the version merged into its label (labels stay
# version-sorted, comma-separated, without duplicates); a new checksum gets a new row in
# version order. Running it again with the same input changes nothing.
#
# It refuses (exit 1, nothing written) a checksum on a known-BAD table, a malformed
# checksum or version, an anchor it cannot find, a clone checksum or variant that
# disagrees with t/fixtures/clone_vm/builds.tsv (run tools/gen-clone-variants.pl --add
# first), and a row whose label differs between the module and the docs. Exit 2 is a
# usage error. On success it prints one line of JSON:
#   {"snap":"added|merged|unchanged","clone":"added|merged|unchanged"}
#
# The bad tables are never written here: a known-BAD entry is a maintainer's decision.
use strict;
use warnings;
use File::Basename qw(dirname);
use Getopt::Long qw(GetOptionsFromArray);

my $ROOT = dirname(dirname(__FILE__ =~ m{^/} ? __FILE__ : "./" . __FILE__));
my %REL = (
    mod => 'lib/PVE/LXC/BindSnap.pm',
    doc => 'docs/compatible-versions.md',
    tsv => 't/fixtures/clone_vm/builds.tsv',
);
my $VARIANT_DIR = 'lib/PVE/LXC/BindSnap/Clone';

my $SNAP_ENTRY  = qr/^    '([0-9a-f]{64})' => '([^']*)',$/;
my $CLONE_ENTRY = qr/^    '([0-9a-f]{64})' => \{ label => '([^']*)', variant => '(v\d+_\d+_\d+)' \},$/;
my $DOC_SNAP_HEADING  = '## Supported (tested-good)';
my $DOC_CLONE_HEADING = '### Supported (tested-good)';

my $USAGE = "usage: $0 --container VER --guest-common VER --pve VER --snap SHA --clone SHA --variant NAME\n";

sub refuse { die "add-known-good: $_[0]\n"; }

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or refuse("read $path: $!");
    local $/;
    return scalar <$fh>;
}

# Replace $path atomically, keeping its mode, so a crash never leaves half a table.
sub replace_file {
    my ($path, $data) = @_;
    my $tmp  = "$path.add-known-good.$$";
    my $mode = (stat $path)[2] & 07777;
    open(my $fh, '>:raw', $tmp) or refuse("write $tmp: $!");
    print {$fh} $data;
    close($fh) or refuse("write $tmp: $!");
    chmod($mode, $tmp);
    rename($tmp, $path) or refuse("rename $tmp: $!");
}

sub version_key { return sprintf('%05d' x 3, split /\./, $_[0]); }

# Label "6.1.2, 6.1.3" -> (6.1.2, 6.1.3); every part must be a plain X.Y.Z version so
# the merged label can be sorted.
sub label_versions {
    my ($label, $what) = @_;
    my @v = split /,\s*/, $label;
    for (@v) { refuse("$what: label '$label' holds '$_', not an X.Y.Z version") if !/^\d+\.\d+\.\d+$/; }
    return @v;
}

# The label with $ver merged in, or undef when it already lists $ver.
sub merged_label {
    my ($label, $ver, $what) = @_;
    my @v = label_versions($label, $what);
    return undef if grep { $_ eq $ver } @v;
    return join(', ', sort { version_key($a) cmp version_key($b) } @v, $ver);
}

sub min_key {
    my ($label, $what) = @_;
    my ($first) = sort { version_key($a) cmp version_key($b) } label_versions($label, $what);
    return version_key($first);
}

# --- module tables ---------------------------------------------------------------------

# [open line index, close line index] of "my %NAME = (" .. ");" in @$lines.
sub table_span {
    my ($lines, $name) = @_;
    my $anchor = "my %$name = (";
    my @at = grep { $lines->[$_] eq $anchor } 0 .. $#$lines;
    refuse("anchor not found in $REL{mod} (want it exactly once, found " . scalar(@at) . "): $anchor") if @at != 1;
    my ($end) = grep { $lines->[$_] eq ');' } $at[0] + 1 .. $#$lines;
    refuse("$REL{mod}: %$name is not closed by a ');' line") if !defined $end;
    return ($at[0], $end);
}

# Checksums on a bad table. Read loosely (any 64-hex string on a non-comment line), so a
# bad entry in an unexpected layout still refuses rather than slipping through.
sub bad_checksums {
    my ($lines, $name) = @_;
    my ($s, $e) = table_span($lines, $name);
    my %bad;
    for my $l (@$lines[$s + 1 .. $e - 1]) {
        next if $l =~ /^\s*#/;
        $bad{$_} = 1 for $l =~ /([0-9a-f]{64})/g;
    }
    return \%bad;
}

# Merge or insert one entry in a good table. $entry_re captures (sha, label, ...);
# $render->(sha, label) gives the line. Returns 'added', 'merged' or 'unchanged'.
sub upsert_module {
    my (%a) = @_;
    my ($lines, $name, $sha, $ver) = @a{qw(lines name sha ver)};
    my ($s, $e) = table_span($lines, $name);
    my @entries;
    for my $i ($s + 1 .. $e - 1) {
        my @m = $lines->[$i] =~ $a{entry_re} or refuse("$REL{mod}: unexpected line in %$name: $lines->[$i]");
        push @entries, { at => $i, sha => $m[0], label => $m[1], rest => [@m[2 .. $#m]] };
    }
    my ($hit) = grep { $_->{sha} eq $sha } @entries;
    if ($hit) {
        $a{on_hit}->($hit) if $a{on_hit};
        my $new = merged_label($hit->{label}, $ver, "%$name $sha");
        return ('unchanged', $hit->{label}) if !defined $new;
        $lines->[$hit->{at}] = $a{render}->($sha, $new);
        return ('merged', $hit->{label});
    }
    my ($after) = grep { min_key($_->{label}, "%$name $_->{sha}") gt version_key($ver) } @entries;
    splice(@$lines, $after ? $after->{at} : $e, 0, $a{render}->($sha, $ver));
    return ('added', undef);
}

# --- docs tables -----------------------------------------------------------------------

# The markdown table after the exactly-once heading line $heading:
# { first => line index, last => line index, header => [cells], rows => [[cells]] }.
sub doc_table {
    my ($lines, $heading) = @_;
    my @at = grep { $lines->[$_] eq $heading } 0 .. $#$lines;
    refuse("anchor not found in $REL{doc} (want it exactly once, found " . scalar(@at) . "): $heading") if @at != 1;
    my $i = $at[0] + 1;
    while ($i <= $#$lines && $lines->[$i] !~ /^\|/) {
        refuse("$REL{doc}: no table under '$heading'") if $lines->[$i] =~ /^#/;
        $i++;
    }
    refuse("$REL{doc}: no table under '$heading'") if $i > $#$lines;
    my $first = $i;
    my @t;
    push @t, $lines->[$i++] while $i <= $#$lines && $lines->[$i] =~ /^\|/;
    refuse("$REL{doc}: table under '$heading' has no separator row") if @t < 2 || $t[1] !~ /^\|[-:|]+\|$/;
    my @cells = map { [map { s/^\s+|\s+$//gr } (split /\|/, $_, -1)[1 .. 3]] } @t;
    for my $k (0 .. $#t) {
        my $n = () = $t[$k] =~ /\|/g;
        refuse("$REL{doc}: row under '$heading' does not have 3 cells: $t[$k]") if $n != 4;
    }
    my @rows = @cells[2 .. $#cells];
    for (@rows) { refuse("$REL{doc}: checksum cell is not a backticked sha256: $_->[1]") if $_->[1] !~ /^`[0-9a-f]{64}`$/; }
    return { first => $first, last => $i - 1, header => $cells[0], rows => \@rows };
}

sub render_table {
    my ($header, $rows) = @_;
    my @w = (0, 0, 0);
    for my $r ($header, @$rows) {
        for my $c (0 .. 2) { $w[$c] = length($r->[$c]) if length($r->[$c]) > $w[$c]; }
    }
    my $line = sub { my ($r) = @_; return '| ' . join(' | ', map { sprintf("%-*s", $w[$_], $r->[$_]) } 0 .. 2) . ' |'; };
    return ($line->($header), '|' . join('|', map { '-' x ($_ + 2) } @w) . '|', map { $line->($_) } @$rows);
}

# Mirror one module change into the docs table. $status/$old_label come from the module.
sub upsert_doc {
    my (%a) = @_;
    my ($lines, $heading, $sha, $ver, $note) = @a{qw(lines heading sha ver note)};
    my $t = doc_table($lines, $heading);
    my @rows = @{ $t->{rows} };
    my ($hit) = grep { $_->[1] eq "`$sha`" } @rows;
    if (defined $a{old_label}) {
        refuse("$REL{doc} has no row for $sha under '$heading', but the module labels it '$a{old_label}'") if !$hit;
        refuse("$REL{doc} labels $sha '$hit->[0]' under '$heading', but the module labels it '$a{old_label}'")
            if $hit->[0] ne $a{old_label};
    } elsif ($hit) {
        refuse("$REL{doc} has a row for $sha under '$heading' ('$hit->[0]'), but the module does not");
    }
    return if $a{status} eq 'unchanged';
    if ($hit) {
        $hit->[0] = merged_label($hit->[0], $ver, "$REL{doc} $sha");
        $hit->[2] = length($hit->[2]) ? "$hit->[2]; $ver $note" : "$ver $note";
    } else {
        my $row = [$ver, "`$sha`", $note];
        my ($k) = grep { min_key($rows[$_][0], "$REL{doc} $rows[$_][1]") gt version_key($ver) } 0 .. $#rows;
        splice(@rows, $k // scalar(@rows), 0, $row);
    }
    splice(@$lines, $t->{first}, $t->{last} - $t->{first} + 1, render_table($t->{header}, \@rows));
}

# --- inputs ----------------------------------------------------------------------------

sub parse_args {
    my (@argv) = @_;
    my %o;
    GetOptionsFromArray(\@argv, \%o, map { "$_=s" } qw(container guest-common pve snap clone variant))
        or return undef;
    return undef if @argv || grep { !defined $o{$_} } qw(container guest-common pve snap clone variant);
    refuse("--container '$o{container}': not a version (X.Y.Z)") if $o{container} !~ /^\d+\.\d+\.\d+$/;
    for my $k (qw(guest-common pve)) {
        refuse("--$k '$o{$k}': not a version (X.Y[.Z[.W]])") if $o{$k} !~ /^\d+(?:\.\d+){1,3}$/;
    }
    for my $k (qw(snap clone)) {
        refuse("--$k '$o{$k}': not a sha256 (64 lowercase hex digits)") if $o{$k} !~ /^[0-9a-f]{64}$/;
    }
    refuse("--variant '$o{variant}': not a variant name (vX_Y_Z)") if $o{variant} !~ /^v\d+_\d+_\d+$/;
    return \%o;
}

# The clone checksum and variant must be what builds.tsv records for this build, or the
# table would select another build's clone_vm (t/09-clone-variants.t asserts the same).
sub check_builds_tsv {
    my ($o) = @_;
    refuse("variant $o->{variant}: no $VARIANT_DIR/$o->{variant}.pm (generate it with tools/gen-clone-variants.pl --add DIR)")
        if !-f "$ROOT/$VARIANT_DIR/$o->{variant}.pm";
    my ($row) = grep { $_->[0] eq $o->{container} }
        map { [split /\t/] } grep { !/^#/ && length } split /\n/, slurp("$ROOT/$REL{tsv}");
    refuse("pve-container $o->{container} has no row in $REL{tsv} (run tools/gen-clone-variants.pl --add DIR first)")
        if !$row;
    refuse("$REL{tsv} records clone checksum $row->[2] for $o->{container}, not $o->{clone}")
        if $row->[2] ne $o->{clone};
    refuse("--variant $o->{variant} does not match $REL{tsv}, which names $row->[4] for $o->{container}")
        if $row->[4] ne $o->{variant};
}

sub main {
    my (@argv) = @_;
    my $o = eval { parse_args(@argv) };
    if ($@) { print STDERR $@; return 1; }
    if (!$o) { print STDERR $USAGE; return 2; }

    my $out = eval { plan_change($o) };
    if ($@) { print STDERR $@; return 1; }

    # Every check has passed for both files before either is written.
    for my $k (qw(mod doc)) {
        replace_file("$ROOT/$REL{$k}", $out->{$k}) if $out->{$k} ne $out->{"orig_$k"};
    }
    print qq({"snap":"$out->{snap}","clone":"$out->{clone}"}\n);
    return 0;
}

sub plan_change {
    my ($o) = @_;
    my ($ver, $snap, $clone, $variant) = @$o{qw(container snap clone variant)};
    check_builds_tsv($o);

    my $mod_text = slurp("$ROOT/$REL{mod}");
    my $doc_text = slurp("$ROOT/$REL{doc}");
    my @m = split /\n/, $mod_text, -1;
    my @d = split /\n/, $doc_text, -1;

    refuse("known-BAD snapshot checksum $snap (in %KNOWN_BAD_CHECKSUMS): refusing to list it as known-good")
        if bad_checksums(\@m, 'KNOWN_BAD_CHECKSUMS')->{$snap};
    refuse("known-BAD clone checksum $clone (in %KNOWN_BAD_CLONE_CHECKSUMS): refusing to list it as known-good")
        if bad_checksums(\@m, 'KNOWN_BAD_CLONE_CHECKSUMS')->{$clone};

    my ($snap_status, $snap_old) = upsert_module(
        lines => \@m, name => 'KNOWN_GOOD_CHECKSUMS', sha => $snap, ver => $ver,
        entry_re => $SNAP_ENTRY,
        render => sub { "    '$_[0]' => '$_[1]'," },
    );
    my ($clone_status, $clone_old) = upsert_module(
        lines => \@m, name => 'KNOWN_GOOD_CLONE_CHECKSUMS', sha => $clone, ver => $ver,
        entry_re => $CLONE_ENTRY,
        render => sub { "    '$_[0]' => { label => '$_[1]', variant => '$variant' }," },
        on_hit => sub {
            my ($e) = @_;
            refuse("clone checksum $clone is already in the table with variant $e->{rest}[0], not $variant")
                if $e->{rest}[0] ne $variant;
        },
    );

    upsert_doc(lines => \@d, heading => $DOC_SNAP_HEADING, sha => $snap, ver => $ver,
               status => $snap_status, old_label => $snap_old,
               note => "E2E-tested on PVE $o->{pve}, libpve-guest-common-perl $o->{'guest-common'}");
    upsert_doc(lines => \@d, heading => $DOC_CLONE_HEADING, sha => $clone, ver => $ver,
               status => $clone_status, old_label => $clone_old,
               note => "E2E-tested on PVE $o->{pve}");

    return {
        mod => join("\n", @m), orig_mod => $mod_text,
        doc => join("\n", @d), orig_doc => $doc_text,
        snap => $snap_status, clone => $clone_status,
    };
}

exit main(@ARGV);
