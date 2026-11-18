#!/usr/bin/perl
# tools/gen-clone-variants.pl --add DIR merges the builds in DIR into the committed
# builds.tsv and fixtures. Unlike --src, it never drops or renames a row or a variant the
# repo already has, so a DIR holding only the new builds (Proxmox prunes old .debs) is
# enough. Runs on a copy of the real tool, fixtures and variants in a temp dir.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Basename qw(dirname);
use Digest::SHA qw(sha256_hex);

my $REPO = "$FindBin::Bin/..";
my $FIX  = 't/fixtures/clone_vm';
my $VAR  = 'lib/PVE/LXC/BindSnap/Clone';
my $LXC  = 'usr/share/perl5/PVE/API2/LXC.pm';

sub slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or die "read $p: $!";
    local $/;
    return scalar <$fh>;
}

sub spew {
    my ($p, $d) = @_;
    make_path(dirname($p));
    open(my $fh, '>:raw', $p) or die "write $p: $!";
    print {$fh} $d;
    close $fh or die "write $p: $!";
}

sub ls_files {
    my ($root) = @_;
    my @out;
    my @todo = ($root);
    while (my $d = shift @todo) {
        opendir(my $dh, $d) or die "open $d: $!";
        for (sort grep { !/^\.\.?$/ } readdir $dh) {
            -d "$d/$_" ? push(@todo, "$d/$_") : push(@out, "$d/$_");
        }
    }
    return @out;
}

# A temp copy of everything the tool and t/09 read.
sub fresh_tree {
    my $dir = tempdir(CLEANUP => 1);
    for my $f (ls_files("$REPO/lib"), ls_files("$REPO/$FIX"), "$REPO/tools/gen-clone-variants.pl",
               "$REPO/t/09-clone-variants.t") {
        (my $rel = $f) =~ s{^\Q$REPO\E/}{};
        make_path(dirname("$dir/$rel"));
        copy($f, "$dir/$rel") or die "copy $rel: $!";
    }
    return $dir;
}

sub tree_state {
    my ($dir) = @_;
    return { map { (s{^\Q$dir\E/}{}r) => slurp($_) } ls_files("$dir/$FIX"), ls_files("$dir/$VAR") };
}

sub run_gen {
    my ($dir, @args) = @_;
    system("'$^X' '$dir/tools/gen-clone-variants.pl' " . join(' ', map { "'$_'" } @args)
         . " >'$dir/.out' 2>'$dir/.err'");
    return ($? >> 8, slurp("$dir/.out"), slurp("$dir/.err"));
}

# A synthetic LXC.pm around a clone_vm slice, shaped like upstream's.
sub lxc_pm {
    my ($ver, $slice) = @_;
    return "package PVE::API2::LXC;\n\n# synthetic pve-container $ver\n\n$slice\n1;\n";
}

my $v617   = slurp("$REPO/$FIX/v6_1_7.upstream");
# A new upstream body: one more comment line inside the method, every hunk anchor intact.
my $newbody = $v617 =~ s/\A(__PACKAGE__->register_method\(\{\n)/$1    # synthetic upstream change\n/r;
isnt($newbody, $v617, 'the synthetic new body differs from v6_1_7');

my $dir    = fresh_tree();
my %before = %{ tree_state($dir) };

# The tree is a copy of the repo's LIVE fixtures, which gain builds and variants with every
# vetted release, so no expectation names a real build or counts the real variants: they
# are read from the tree. The synthetic builds are 9.9.x, above every real one.
sub header_builds {
    my ($module) = @_;
    my ($list) = $module =~ /^# Upstream's clone_vm method .* as shipped in pve-container\n#   (.+)$/m;
    return defined $list ? [split /, /, $list] : undef;
}
my @variants   = sort map { m{^\Q$FIX\E/(v[\d_]+)\.upstream$} ? $1 : () } keys %before;
my @real_tsv   = grep { !/^#/ && length } split /\n/, $before{"$FIX/builds.tsv"};
my @real_build = map { (split /\t/)[0] } @real_tsv;
ok(!grep({ my @v = split /\./; $v[0] > 9 || ($v[0] == 9 && $v[1] >= 9) } @real_build),
   'every real build sorts below the synthetic 9.9.x ones');
ok(defined header_builds($before{"$VAR/v6_1_7.pm"}), 'the v6_1_7 module header lists its builds');
my $src    = tempdir(CLEANUP => 1);
spew("$src/x-pve-container-9.9.1/$LXC", lxc_pm('9.9.1', $v617));
spew("$src/x-pve-container-9.9.2/$LXC", lxc_pm('9.9.2', $newbody));
my $have_deb = !system('command -v dpkg-deb >/dev/null 2>&1');
if ($have_deb) {
    my $stage = tempdir(CLEANUP => 1);
    spew("$stage/$LXC", lxc_pm('9.9.3', $newbody));
    spew("$stage/DEBIAN/control", "Package: pve-container\nVersion: 9.9.3\nArchitecture: all\n"
        . "Maintainer: test <test\@example.invalid>\nDescription: synthetic test build\n");
    chmod(0755, $stage, "$stage/DEBIAN");
    system("dpkg-deb --root-owner-group --build '$stage' '$src/pve-container_9.9.3_all.deb' >/dev/null 2>&1") == 0
        or BAIL_OUT('dpkg-deb --build failed');
}

{
    my ($rc, $out, $err) = run_gen($dir, '--add', $src);
    is($rc, 0, '--add: exit 0') or diag $err;
    like($out, qr/^added 9\.9\.1 -> v6_1_7$/m, '--add: reports a build that joins an existing variant');
    like($out, qr/^added 9\.9\.2 -> v9_9_2 \(new variant\)$/m, '--add: reports a new variant');

    my @old = grep { !/^#/ && length } split /\n/, $before{"$FIX/builds.tsv"};
    my @new = grep { !/^#/ && length } split /\n/, slurp("$dir/$FIX/builds.tsv");
    my %oldset = map { $_ => 1 } @old;
    is_deeply([grep { $oldset{$_} } @new], \@old, 'builds.tsv: every existing row kept, unchanged, in order');
    my %row = map { my @c = split /\t/; ($c[0] => \@c) } @new;
    my @want = ('9.9.1', '9.9.2', $have_deb ? '9.9.3' : ());
    is_deeply([grep { !$oldset{$_} } @new], [map { join("\t", @{ $row{$_} }) } @want],
              'builds.tsv: only the new builds added, after the older ones');
    is($row{'9.9.1'}[4], 'v6_1_7', '9.9.1 has the v6_1_7 body, so it joins that variant');
    is($row{'9.9.2'}[4], 'v9_9_2', '9.9.2 has a new body, so it gets a variant named after it');
    is($row{'9.9.3'}[4], 'v9_9_2', '9.9.3 (.deb) shares 9.9.2\'s body and variant') if $have_deb;
    my $pm = lxc_pm('9.9.1', $v617);
    is($row{'9.9.1'}[1], sha256_hex($pm), 'row: LXC.pm sha256');
    is($row{'9.9.1'}[2], sha256_hex(sha256_hex($pm) . "\n"), 'row: clone checksum, BindSnap.pm formula');
    is($row{'9.9.1'}[3], sha256_hex($v617), 'row: slice sha256');

    my %after = %{ tree_state($dir) };
    is($after{"$FIX/v9_9_2.upstream"}, $newbody, 'new fixture is the new upstream slice');
    ok(exists $after{"$VAR/v9_9_2.pm"}, 'new variant module generated');
    for my $v (@variants) {
        is($after{"$FIX/$v.upstream"}, $before{"$FIX/$v.upstream"}, "$v fixture unchanged");
        ok(exists $after{"$VAR/$v.pm"}, "$v variant module kept");
    }
    is_deeply(header_builds($after{"$VAR/v6_1_7.pm"}), [@{ header_builds($before{"$VAR/v6_1_7.pm"}) }, '9.9.1'],
              'v6_1_7 module header now lists 9.9.1 after its real builds');

    my ($crc, $cout, $cerr) = run_gen($dir, '--check');
    is($crc, 0, '--check passes after --add') or diag $cerr;
    my $want = @variants + 1;
    like($cout, qr/OK: $want variant/, "--check sees the real variants plus the new one ($want)");

    my $t09 = `'$^X' -I'$dir/lib' '$dir/t/09-clone-variants.t' 2>&1`;
    is($?, 0, 't/09-clone-variants.t passes on the tree with a new variant') or diag $t09;
}

{
    my %mid = %{ tree_state($dir) };
    my ($rc, $out, $err) = run_gen($dir, '--add', $src);
    is($rc, 0, 'second --add: exit 0') or diag $err;
    unlike($out, qr/^added/m, 'second --add: nothing added');
    is_deeply(tree_state($dir), \%mid, 'second --add: every file byte-identical');
}

# --- refusals write nothing -------------------------------------------------------------
sub refused {
    my ($name, $build, $want) = @_;
    my $d   = fresh_tree();
    my %pre = %{ tree_state($d) };
    my $s   = tempdir(CLEANUP => 1);
    spew("$s/x-pve-container-$build->[0]/$LXC", $build->[1]);
    my ($rc, undef, $err) = run_gen($d, '--add', $s);
    isnt($rc, 0, "$name: non-zero exit");
    like($err, $want, "$name: says why");
    is_deeply(tree_state($d), \%pre, "$name: nothing written");
}

refused('a known build with different content', [$real_build[-1], lxc_pm($real_build[-1], $v617)],
        qr/\Q$real_build[-1]\E.*already in builds\.tsv/);
refused('a new body missing a hunk anchor', ['9.9.4', lxc_pm('9.9.4', $newbody =~ s/^        my \$running;\n//mr)],
        qr/anchor found 0 times/);

{
    my $d = fresh_tree();
    my ($rc, undef, $err) = run_gen($d, '--add', $src, '--src', $src);
    isnt($rc, 0, '--add with --src: refused');
    like($err, qr/--add and --src/, '--add with --src: says why');
}

done_testing();
