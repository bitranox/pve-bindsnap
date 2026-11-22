#!/usr/bin/perl
# install.sh carries a copy of debian/postinst's preflight_load (it must run standalone from
# curl | bash). The copies must stay identical, and install.sh's copy must load under perl -T
# and print perl's own error when the overlay does not load. The function is cut out of the
# script and run in bash with a recording perl on PATH.
use strict;
use warnings;
use FindBin;
use Test::More;
use File::Temp qw(tempdir);

my $REPO = "$FindBin::Bin/..";

sub slurp {
    my ($p) = @_;
    open(my $fh, '<', $p) or die "read $p: $!";
    local $/;
    return scalar <$fh>;
}

sub spew {
    my ($p, $d) = @_;
    open(my $fh, '>', $p) or die "write $p: $!";
    print {$fh} $d;
    close $fh or die "write $p: $!";
}

sub function_text {
    my ($file) = @_;
    my ($fn) = slurp("$REPO/$file") =~ /^(preflight_load\(\) \{\n.*?^\}\n)/ms;
    return $fn;
}

my $inst = function_text('install.sh');
my $deb  = function_text('debian/postinst');
ok(defined $inst && defined $deb, 'both scripts define preflight_load');
is($inst, $deb, 'install.sh and debian/postinst carry the same preflight_load');

# Run install.sh's copy with a perl that records its arguments and exits $rc, printing
# $stderr first. Returns (exit code, the script's stderr, perl's recorded arguments).
sub run_fn {
    my ($rc, $stderr) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $say = length($stderr) ? "echo '$stderr' >&2\n" : '';
    spew("$dir/perl", "#!/bin/sh\necho \"\$*\" > '$dir/args'\n${say}exit $rc\n");
    chmod 0755, "$dir/perl";
    spew("$dir/run.sh", $inst . "preflight_load 'the test overlay did not load' 'exit 0'\n");
    my $err = `PATH='$dir':/usr/bin:/bin bash '$dir/run.sh' 2>&1 >/dev/null`;
    return ($? >> 8, $err, slurp("$dir/args"));
}

my ($rc, $err, $args) = run_fn(0, '');
is($rc, 0, 'a load that works: exit 0');
is($err, '', 'a load that works: prints nothing');
like($args, qr/^-T -e exit 0$/, 'perl runs the check under -T');

($rc, $err) = run_fn(1, 'pve-bindsnap: overlay not loaded (Insecure dependency in require)');
is($rc, 1, 'a failed load: exit 1');
like($err, qr/PRE-FLIGHT FAILED -- the test overlay did not load\./, 'a failed load: says what failed');
like($err, qr/Insecure dependency in require/, "a failed load: prints perl's own error");

($rc, $err) = run_fn(1, '');
like($err, qr/perl printed no error/, 'a silent failure says perl printed nothing');

done_testing();
