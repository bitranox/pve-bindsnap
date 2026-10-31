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

my ($src, $check, $min) = (undef, 0, '6.0.17');
GetOptions('src=s' => \$src, 'check' => \$check, 'min=s' => \$min)
    or die "usage: $0 [--src DIR] [--check] [--min VER]\n";

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

# Stage 1: upstream builds -> { fixtures => {variant => slice}, tsv => text }.
sub stage_upstream {
    my ($dir) = @_;
    my (%fixtures, %variant_of_slice, @rows);
    for my $ver (builds_in($dir)) {
        my $pm    = lxc_pm_of($dir, $ver);
        my $slice = slice_clone_vm($pm, "pve-container $ver");
        my $ssum  = sha256_hex($slice);
        my $var   = $variant_of_slice{$ssum} //= variant_of($ver);
        $fixtures{$var} = $slice;
        push @rows, join("\t", $ver, sha256_hex($pm), clone_checksum($pm), $ssum, $var);
    }
    die "no pve-container builds >= $min in $dir\n" if !@rows;
    my $tsv = "# build\tlxc_pm_sha256\tclone_checksum\tslice_sha256\tvariant\n"
            . join('', map { "$_\n" } @rows);
    return { fixtures => \%fixtures, tsv => $tsv };
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
    if ($check) {
        push @drift, $path if !-f $path || slurp($path) ne $data;
    } else {
        spew($path, $data);
        print "wrote $path\n";
    }
}

my ($fixtures, $tsv);
if (defined $src) {
    my $up = stage_upstream($src);
    ($fixtures, $tsv) = ($up->{fixtures}, $up->{tsv});
    compare_or_write("$FIXTURES/$_.upstream", $fixtures->{$_}) for sort keys %$fixtures;
    compare_or_write("$FIXTURES/builds.tsv", $tsv);
} else {
    die "without --src only --check is meaningful\n" if !$check;
    ($fixtures, $tsv) = (committed_fixtures(), slurp("$FIXTURES/builds.tsv"));
}

my $variants = variants_from($fixtures, $tsv);
compare_or_write($_, $variants->{$_}) for sort keys %$variants;

if ($check) {
    if (@drift) {
        print STDERR "DRIFT (regenerate with tools/gen-clone-variants.pl --src DIR):\n";
        print STDERR "  $_\n" for @drift;
        exit 1;
    }
    printf "OK: %d variant(s) match their fixtures\n", scalar keys %$variants;
}
