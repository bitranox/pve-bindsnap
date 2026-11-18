#!/usr/bin/perl
# pve-bindsnap -- generate the per-build clone_vm variants.
# Copyright (C) 2026 bitranox
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The clone override runs upstream's own clone_vm method, verbatim except for a few
# marked hunks. Upstream changed clone_vm between pve-container builds, so one copy
# cannot match every build: this tool produces one variant per DISTINCT upstream body.
#
#   tools/gen-clone-variants.pl --src DIR         slice every build in DIR, write the
#                                                 fixtures, builds.tsv and the variants
#   tools/gen-clone-variants.pl --check           regenerate the variants from the
#                                                 committed fixtures, fail on any drift
#   tools/gen-clone-variants.pl --src DIR --check also re-slice DIR and compare
#   tools/gen-clone-variants.pl --add DIR         merge the builds in DIR into the
#                                                 committed builds.tsv and fixtures
#
# --src rebuilds builds.tsv from DIR alone, so DIR must hold every build from --min on;
# a build missing from DIR drops its row, and a variant can be renamed after the oldest
# build left. --add never drops or renames: rows already in builds.tsv stay as they are,
# a new build whose clone_vm body is already known joins that body's variant, and only a
# new body gets a new variant (named after the oldest new build that has it). A build
# already recorded must come back byte-identical, or --add refuses.
#
# DIR holds pve-container builds, either extracted (x-pve-container-<ver>/usr/share/
# perl5/PVE/API2/LXC.pm) or as pve-container_<ver>_all.deb. Builds older than --min
# (default 6.0.17, the oldest build sharing a body with a vetted one) are skipped.
#
# Two stages, so CI needs no upstream download:
#   1. upstream -> t/fixtures/clone_vm/<variant>.upstream (the verbatim register_method
#      slice) + t/fixtures/clone_vm/builds.tsv (which build has which body)
#   2. fixture + hunks -> lib/PVE/LXC/BindSnap/Clone/<variant>.pm
# Each hunk is fenced "# <<< BINDSNAP <name>" .. "# >>> BINDSNAP", and every upstream
# line it replaces stays inside the fence as "#| <line>", so dropping the fences' own
# lines and un-prefixing the "#|" lines gives the upstream slice back byte for byte
# (t/09-clone-variants.t asserts it).
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions);

my $ROOT     = dirname(dirname(__FILE__ =~ m{^/} ? __FILE__ : "./" . __FILE__));
my $FIXTURES = "$ROOT/t/fixtures/clone_vm";
my $OUTDIR   = "$ROOT/lib/PVE/LXC/BindSnap/Clone";
my $LXC_PM   = 'usr/share/perl5/PVE/API2/LXC.pm';

my ($src, $add, $check, $min) = (undef, undef, 0, '6.0.17');
GetOptions('src=s' => \$src, 'add=s' => \$add, 'check' => \$check, 'min=s' => \$min)
    or die "usage: $0 [--src DIR | --add DIR] [--check] [--min VER]\n";
die "--add and --src are exclusive: --src rebuilds builds.tsv from DIR, --add merges into it\n"
    if defined $src && defined $add;

# --- the hunks: the ONLY places a variant differs from upstream ------------------------
# Each anchor is a whole upstream line that must occur exactly once in the slice.
#   after   -- insert the new lines after the anchor
#   before  -- insert the new lines before the anchor
#   replace -- replace the anchor and the lines listed in 'also' (checked verbatim)
my @HUNKS = (
    {
        name   => 'declare',
        anchor => '        my $running;',
        mode   => 'after',
        new    => [
            '        # pve-bindsnap: bind/device mounts carried/excluded, collected in the loop',
            '        # below and reported by $realcmd; outer scope so the worker closure sees them.',
            '        my (@clone_carried, @clone_excluded);',
        ],
    },
    {
        name   => 'excludes',
        anchor => '            my $src_conf = $snapname ? $src_conf->{snapshots}->{$snapname} : $src_conf;',
        mode   => 'after',
        new    => [
            '',
            '            # pve-bindsnap: effective BINDSNAP-EXCLUDE set for this clone: the source CT',
            "            # Notes for a live clone, the snapshot's own frozen description for a",
            '            # --snapname clone (both are $src_conf->{description} at this scope).',
            '            my $clone_excl = PVE::LXC::BindSnap::_snap_excludes($src_conf->{description}) // {};',
        ],
    },
    {
        name   => 'carry',
        anchor => '                        # TODO: allow bind mounts?',
        also   => [q{                        die "unable to clone mountpoint '$opt' (type $mp->{type})\n";}],
        mode   => 'replace',
        new    => [
            '                        # pve-bindsnap: a bind/device mountpoint has no managed volume',
            '                        # to clone. Carry the entry to the new CT unchanged (same host',
            '                        # path/device) unless BINDSNAP-EXCLUDE drops it. It is NOT added',
            '                        # to %$mountpoints, so the worker never copies a volume for it.',
            '                        if ($clone_excl->{$opt}) { push @clone_excluded, $opt; next; }',
            '                        push @clone_carried, $opt;',
            '                        $newconf->{$opt} = $value;',
        ],
    },
    {
        name   => 'summary',
        anchor => '            my $verify_running = PVE::LXC::check_running($vmid) || 0;',
        mode   => 'before',
        new    => [
            "            # pve-bindsnap: report what the overlay did to the 'vzclone' task log, and",
            '            # warn when bind/device mounts were carried (they share the source host',
            '            # paths). Eval-guarded so it can never affect the clone itself.',
            '            eval {',
            '                print PVE::LXC::BindSnap::_clone_summary(',
            '                    vmid => $vmid, newid => $newid,',
            '                    vlabel => PVE::LXC::BindSnap::_clone_vlabel(),',
            '                    cloned => [sort keys %$mountpoints],',
            '                    carried => \@clone_carried, excluded => \@clone_excluded,',
            '                );',
            '                PVE::LXC::BindSnap::_task_warn(',
            '                    PVE::LXC::BindSnap::_clone_carry_warning(\@clone_carried))',
            '                    if @clone_carried;',
            '                1;',
            '            };',
            '',
        ],
    },
);

# The slice is a register_method call; the variant returns the method hash instead of
# registering it again (re-registering dies on the duplicate name).
my %WRAP = (
    first => ['__PACKAGE__->register_method({', 'return {'],
    last  => ['});',                            '};'],
);

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "read $path: $!\n";
    local $/;
    return scalar <$fh>;
}

sub spew {
    my ($path, $data) = @_;
    make_path(dirname($path));
    open(my $fh, '>:raw', $path) or die "write $path: $!\n";
    print {$fh} $data;
    close($fh) or die "write $path: $!\n";
}

sub version_key { return sprintf('%05d' x 3, split /\./, $_[0]); }
sub variant_of  { (my $v = $_[0]) =~ tr/./_/; return "v$v"; }

# Same formula as BindSnap.pm's _config_checksum over @CLONE_GUARDED_FILES.
sub clone_checksum { return sha256_hex(sha256_hex($_[0]) . "\n"); }

# The clone_vm register_method call: from its "__PACKAGE__->register_method({" line
# through the first line that is exactly "});".
sub slice_clone_vm {
    my ($text, $what) = @_;
    my $name = index($text, "name => 'clone_vm'");
    die "$what: no clone_vm method\n" if $name < 0;
    my $start = rindex($text, "__PACKAGE__->register_method({\n", $name);
    die "$what: no register_method before clone_vm\n" if $start < 0;
    my $end = index($text, "\n});\n", $name);
    die "$what: clone_vm register_method not closed\n" if $end < 0;
    return substr($text, $start, $end + length("\n});\n") - $start);
}

sub lxc_pm_of {
    my ($dir, $ver) = @_;
    my $tree = "$dir/x-pve-container-$ver/$LXC_PM";
    return slurp($tree) if -f $tree;
    my $deb = "$dir/pve-container_${ver}_all.deb";
    open(my $fh, '-|', "dpkg-deb --fsys-tarfile '$deb' | tar -xOf - './$LXC_PM'")
        or die "dpkg-deb $deb: $!\n";
    binmode($fh);
    local $/;
    my $data = <$fh>;
    close($fh) or die "extract $LXC_PM from $deb failed\n";
    return $data;
}

sub builds_in {
    my ($dir) = @_;
    opendir(my $dh, $dir) or die "open $dir: $!\n";
    my %v;
    for (readdir $dh) {
        $v{$1} = 1 if /^x-pve-container-(\d+\.\d+\.\d+)$/ || /^pve-container_(\d+\.\d+\.\d+)_all\.deb$/;
    }
    return grep { version_key($_) ge version_key($min) } sort { version_key($a) cmp version_key($b) } keys %v;
}

my $TSV_HEADER = "# build\tlxc_pm_sha256\tclone_checksum\tslice_sha256\tvariant\n";

# One build of DIR: its builds.tsv fields (variant still to be chosen) and its slice.
sub build_row {
    my ($dir, $ver) = @_;
    my $pm    = lxc_pm_of($dir, $ver);
    my $slice = slice_clone_vm($pm, "pve-container $ver");
    return { ver => $ver, pm => sha256_hex($pm), csum => clone_checksum($pm),
             ssum => sha256_hex($slice), slice => $slice };
}

sub tsv_line { my ($r) = @_; return join("\t", @$r{qw(ver pm csum ssum var)}) . "\n"; }

# Stage 1: upstream builds -> { fixtures => {variant => slice}, tsv => text }.
sub stage_upstream {
    my ($dir) = @_;
    my (%fixtures, %variant_of_slice, @rows);
    for my $ver (builds_in($dir)) {
        my $r = build_row($dir, $ver);
        $r->{var} = $variant_of_slice{ $r->{ssum} } //= variant_of($ver);
        $fixtures{ $r->{var} } = $r->{slice};
        push @rows, $r;
    }
    die "no pve-container builds >= $min in $dir\n" if !@rows;
    return { fixtures => \%fixtures, tsv => $TSV_HEADER . join('', map { tsv_line($_) } @rows) };
}

# Stage 1 for --add: the committed fixtures and builds.tsv plus the new builds in DIR.
# Returns { fixtures, tsv, notes => [lines saying what was added] }.
sub merge_upstream {
    my ($dir) = @_;
    my $fixtures = committed_fixtures();
    my (%row, %variant_of_slice);
    for (split /\n/, slurp("$FIXTURES/builds.tsv")) {
        next if /^#/ || !length;
        my %r;
        @r{qw(ver pm csum ssum var)} = split /\t/;
        $row{ $r{ver} } = \%r;
        $variant_of_slice{ $r{ssum} } //= $r{var};
    }
    my @builds = builds_in($dir);
    die "no pve-container builds >= $min in $dir\n" if !@builds;
    my @notes;
    for my $ver (@builds) {
        my $r = build_row($dir, $ver);
        if (my $old = $row{$ver}) {
            next if !grep { $old->{$_} ne $r->{$_} } qw(pm csum ssum);
            die "pve-container $ver is already in builds.tsv with a different LXC.pm "
              . "(recorded $old->{pm}, DIR has $r->{pm}); --add never changes a recorded build\n";
        }
        my $var = $variant_of_slice{ $r->{ssum} };
        my $new = !defined $var;
        if ($new) {
            $var = variant_of($ver);
            die "pve-container $ver has a new clone_vm body, but variant $var already exists with another one\n"
                if exists $fixtures->{$var};
            $fixtures->{$var} = $r->{slice};
            $variant_of_slice{ $r->{ssum} } = $var;
        }
        $r->{var} = $var;
        $row{$ver} = $r;
        push @notes, "added $ver -> $var" . ($new ? ' (new variant)' : '');
    }
    my @rows = map { $row{$_} } sort { version_key($a) cmp version_key($b) } keys %row;
    return { fixtures => $fixtures, tsv => $TSV_HEADER . join('', map { tsv_line($_) } @rows), notes => \@notes };
}

sub find_once {
    my ($lines, $anchor, $what) = @_;
    my @at = grep { $lines->[$_] eq $anchor } 0 .. $#$lines;
    die "$what: anchor found " . scalar(@at) . " times, want 1: $anchor\n" if @at != 1;
    return $at[0];
}

sub fence {
    my ($name, $orig, $new) = @_;
    return ("# <<< BINDSNAP $name", (map { "#| $_" } @$orig), @$new, '# >>> BINDSNAP');
}

# Stage 2: one upstream slice -> the variant module text.
sub render_variant {
    my ($variant, $slice, $builds) = @_;
    my @l = split /\n/, $slice, -1;
    pop @l if @l && $l[-1] eq '';    # the slice ends with "\n"
    die "$variant: slice does not start with $WRAP{first}[0]\n" if $l[0] ne $WRAP{first}[0];
    die "$variant: slice does not end with $WRAP{last}[0]\n"    if $l[-1] ne $WRAP{last}[0];

    # Locate every hunk against the pristine slice first, then apply bottom-up so the
    # earlier indices stay valid.
    my @plan;
    for my $h (@HUNKS) {
        my $i = find_once(\@l, $h->{anchor}, "$variant hunk $h->{name}");
        my @orig = ($h->{anchor});
        for my $k (0 .. $#{ $h->{also} // [] }) {
            my $want = $h->{also}[$k];
            die "$variant hunk $h->{name}: line after anchor is not: $want\n"
                if ($l[$i + 1 + $k] // '') ne $want;
            push @orig, $want;
        }
        my @rep = $h->{mode} eq 'after'  ? fence($h->{name}, [], $h->{new})
                : $h->{mode} eq 'before' ? fence($h->{name}, [], $h->{new})
                :                          fence($h->{name}, \@orig, $h->{new});
        my ($at, $len) = $h->{mode} eq 'after'  ? ($i + 1, 0)
                       : $h->{mode} eq 'before' ? ($i, 0)
                       :                          ($i, scalar @orig);
        push @plan, [$at, $len, \@rep];
    }
    push @plan, [$#l, 1, [fence('wrap-last',  [$l[-1]], [$WRAP{last}[1]])]];
    push @plan, [0,   1, [fence('wrap-first', [$l[0]],  [$WRAP{first}[1]])]];
    for my $p (sort { $b->[0] <=> $a->[0] } @plan) {
        splice(@l, $p->[0], $p->[1], @{ $p->[2] });
    }

    my $list = join(', ', @$builds);
    return <<"HEAD" . join("\n", @l) . "\n" . <<'TAIL';
# pve-bindsnap -- clone_vm variant $variant.
# GENERATED by tools/gen-clone-variants.pl -- do not edit; edit the hunks there.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Upstream's clone_vm method (PVE/API2/LXC.pm) as shipped in pve-container
#   $list
# Verbatim between the UPSTREAM markers except for the fenced "BINDSNAP" hunks; each
# replaced upstream line is kept inside its fence as "#| <line>". It is compiled in
# package PVE::API2::LXC so every name upstream imports resolves exactly as there.
# BindSnap.pm picks this variant by the checksum of the node's PVE/API2/LXC.pm and
# installs method_def()->{code}.
package PVE::LXC::BindSnap::Clone::$variant;

use strict;
use warnings;

sub method_def {
package PVE::API2::LXC;
# BINDSNAP-UPSTREAM-BEGIN
HEAD
# BINDSNAP-UPSTREAM-END
}

1;
TAIL
}

sub parse_tsv {
    my ($tsv) = @_;
    my %builds;
    for (split /\n/, $tsv) {
        next if /^#/ || !length;
        my ($ver, undef, undef, $ssum, $var) = split /\t/;
        push @{ $builds{$var} }, $ver;
    }
    return \%builds;
}

sub variants_from {
    my ($fixtures, $tsv) = @_;
    my $builds = parse_tsv($tsv);
    my %out;
    for my $var (sort keys %$fixtures) {
        die "builds.tsv names no build for fixture $var\n" if !$builds->{$var};
        $out{"$OUTDIR/$var.pm"} = render_variant($var, $fixtures->{$var}, $builds->{$var});
    }
    return \%out;
}

sub committed_fixtures {
    opendir(my $dh, $FIXTURES) or die "open $FIXTURES: $!\n";
    my %f = map { /^(v[\d_]+)\.upstream$/ ? ($1 => slurp("$FIXTURES/$_")) : () } readdir $dh;
    die "no fixtures in $FIXTURES\n" if !%f;
    return \%f;
}

my @drift;
sub compare_or_write {
    my ($path, $data) = @_;
    my $same = -f $path && slurp($path) eq $data;
    if ($check) {
        push @drift, $path if !$same;
    } elsif (!$same) {
        spew($path, $data);
        print "wrote $path\n";
    }
}

my ($fixtures, $tsv, $notes);
if (defined $src || defined $add) {
    my $up = defined $src ? stage_upstream($src) : merge_upstream($add);
    ($fixtures, $tsv, $notes) = ($up->{fixtures}, $up->{tsv}, $up->{notes});
} else {
    die "without --src or --add only --check is meaningful\n" if !$check;
    ($fixtures, $tsv) = (committed_fixtures(), slurp("$FIXTURES/builds.tsv"));
}

# Render every variant before anything is written, so a hunk anchor missing from a new
# build stops the run with the committed files untouched.
my $variants = variants_from($fixtures, $tsv);
if (defined $src || defined $add) {
    compare_or_write("$FIXTURES/$_.upstream", $fixtures->{$_}) for sort keys %$fixtures;
    compare_or_write("$FIXTURES/builds.tsv", $tsv);
}
compare_or_write($_, $variants->{$_}) for sort keys %$variants;
print "$_\n" for @{ $notes // [] };

if ($check) {
    if (@drift) {
        print STDERR "DRIFT (regenerate with tools/gen-clone-variants.pl --src DIR):\n";
        print STDERR "  $_\n" for @drift;
        exit 1;
    }
    printf "OK: %d variant(s) match their fixtures\n", scalar keys %$variants;
}
