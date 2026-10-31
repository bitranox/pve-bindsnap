#!/usr/bin/perl
# Per-build clone_vm variants (lib/PVE/LXC/BindSnap/Clone/*.pm). The contract:
#   * each variant is upstream's clone_vm verbatim except its fenced BINDSNAP hunks --
#     dropping the fence lines and un-prefixing "#|" gives the upstream slice back byte
#     for byte (t/fixtures/clone_vm/<variant>.upstream);
#   * each fixture is the slice builds.tsv records for its builds (slice sha256);
#   * every clone checksum the overlay trusts selects a variant whose builds.tsv row
#     carries that same checksum, so the selected body IS that build's own body;
#   * each variant compiles and returns the clone_vm method hash with a CODE ref.
use strict;
use warnings;
use Test::More;
use FindBin;
use Digest::SHA qw(sha256_hex);
use lib "$FindBin::Bin/../lib";

my $FIX = "$FindBin::Bin/fixtures/clone_vm";
my $VAR = "$FindBin::Bin/../lib/PVE/LXC/BindSnap/Clone";

sub slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or die "read $p: $!";
    local $/;
    return scalar <$fh>;
}

# Inverse of the generator's hunks: the text between the UPSTREAM markers with every
# fence removed and its "#|" lines restored.
sub unpatch {
    my ($text) = @_;
    my ($body) = $text =~ /^# BINDSNAP-UPSTREAM-BEGIN\n(.*?)^# BINDSNAP-UPSTREAM-END\n/ms
        or return undef;
    my ($out, $in) = ('', 0);
    for my $line (split /^/, $body) {
        if ($line =~ /^# <<< BINDSNAP /) { $in = 1; next; }
        if ($line =~ /^# >>> BINDSNAP$/) { $in = 0; next; }
        if ($in) { $out .= $1 if $line =~ /^#\| (.*\n)\z/s; next; }
        $out .= $line;
    }
    return $out;
}

# --- builds.tsv ---
my (%rows, %by_checksum);
for (split /\n/, slurp("$FIX/builds.tsv")) {
    next if /^#/ || !length;
    my ($ver, $pm, $csum, $ssum, $var) = split /\t/;
    $rows{$ver} = { pm => $pm, csum => $csum, ssum => $ssum, var => $var };
    push @{ $by_checksum{$csum} }, $ver;
}
cmp_ok(scalar keys %rows, '>=', 20, 'builds.tsv lists every build from 6.0.17 on');

my %variants = map { $_->{var} => 1 } values %rows;
is_deeply([sort keys %variants], [qw(v6_0_17 v6_0_19 v6_1_3 v6_1_7)],
          'four distinct upstream clone_vm bodies, one variant each');

for my $var (sort keys %variants) {
    my $file = "$VAR/$var.pm";
    ok(-f $file, "$var: variant module exists") or next;
    my $text    = slurp($file);
    my $fixture = slurp("$FIX/$var.upstream");

    is(unpatch($text), $fixture, "$var: unpatched variant equals the upstream slice byte for byte");
    for my $ver (grep { $rows{$_}{var} eq $var } keys %rows) {
        is(sha256_hex($fixture), $rows{$ver}{ssum}, "$var: fixture is the clone_vm slice of $ver");
    }
    my @fences = $text =~ /^# <<< BINDSNAP (\S+)$/mg;
    is_deeply([sort @fences], [sort qw(wrap-first wrap-last declare excludes carry summary)],
              "$var: exactly the six expected hunks");
    my ($region) = $text =~ /^# BINDSNAP-UPSTREAM-BEGIN\n(.*?)^# BINDSNAP-UPSTREAM-END\n/ms;
    unlike(($region // '') =~ s/^# <<< BINDSNAP.*?^# >>> BINDSNAP\n//msgr, qr/BindSnap/,
           "$var: no overlay reference outside the fences");
}

# --- the overlay's trusted checksums map onto variants that carry that very body ---
require PVE::LXC::BindSnap;
my $table = PVE::LXC::BindSnap->can('_clone_variant_table') or BAIL_OUT('_clone_variant_table missing');
my %t = %{ $table->() };
cmp_ok(scalar keys %t, '>=', 9, 'every vetted clone checksum is in the table');
for my $csum (sort keys %t) {
    my $builds = $by_checksum{$csum};
    ok($builds, "table checksum $csum ($t{$csum}{label}) is a build in builds.tsv") or next;
    my %vars = map { $rows{$_}{var} => 1 } @$builds;
    is_deeply([keys %vars], [$t{$csum}{variant}],
              "checksum for $t{$csum}{label} selects the variant of its own body ($t{$csum}{variant})");
}

# --- each variant compiles and yields the method hash. Imported names in the code body
#     are only called at run time; building the hash calls get_standard_option, which
#     upstream imports from PVE::JSONSchema, so stand it in for that one. ---
{
    no strict 'refs';
    *{'PVE::API2::LXC::get_standard_option'} = sub { my ($n, $x) = @_; return { %{ $x // {} } } }
        unless defined &PVE::API2::LXC::get_standard_option;
}
for my $var (sort keys %variants) {
    my $mod = "PVE::LXC::BindSnap::Clone::$var";
    ok(eval "require $mod; 1", "$var: compiles") or diag $@;
    my $m = eval { $mod->can('method_def')->() };
    is(ref $m, 'HASH', "$var: method_def returns a hash");
    is($m->{name}, 'clone_vm', "$var: it is the clone_vm method");
    is(ref $m->{code}, 'CODE', "$var: with a code ref");
}

done_testing();
