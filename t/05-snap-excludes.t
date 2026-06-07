#!/usr/bin/perl
# BINDSNAP-EXCLUDE directive parsing: undef when absent, a hashref of mpN keys when
# present ({} when present-but-empty). The undef-vs-{} distinction is what lets a
# per-snapshot directive override the CT default (empty => exclude nothing). The
# keyword is UPPERCASE and case-sensitive, and needs its colon: BINDSNAP-EXCLUDE_ (no
# colon) is not a directive, while BINDSNAP-EXCLUDE:_ is an empty exclusion.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null')   or die "redir STDERR: $!";
    require PVE::LXC::BindSnap;
    open(STDERR, '>&', $olderr)      or die "restore STDERR: $!";
}

my $ex = PVE::LXC::BindSnap->can('_snap_excludes')
    or BAIL_OUT('_snap_excludes missing');

# --- no directive present -> undef (so the CT default is NOT overridden) ---
ok( !defined $ex->(undef),                 'undef text -> undef');
ok( !defined $ex->(''),                    'empty text -> undef');
ok( !defined $ex->('just some notes'),     'no directive -> undef');
ok( !defined $ex->('mentions mp1 inline'), 'a stray mpN in prose is NOT a directive');

# --- the colon is the discriminator: no colon -> not a directive (undef) ---
ok( !defined $ex->('BINDSNAP-EXCLUDE_'),       'BINDSNAP-EXCLUDE_ (no colon) is NOT a directive');
ok( !defined $ex->('BINDSNAP-EXCLUDE_mp1'),    'BINDSNAP-EXCLUDE_mp1 (no colon) is NOT a directive');
ok( !defined $ex->('a BINDSNAP-EXCLUDE word'), 'BINDSNAP-EXCLUDE in prose without a colon -> undef');

# --- lowercase is NOT a directive (case-sensitive, like the other BINDSNAP- markers) ---
ok( !defined $ex->('bindsnap-exclude: mp1'),   'lowercase bindsnap-exclude -> undef (case-sensitive)');

# --- directive present but empty -> {} (override to "exclude nothing") ---
is_deeply( $ex->('BINDSNAP-EXCLUDE:'),      {}, 'empty directive -> {} (present, no keys)');
is_deeply( $ex->('BINDSNAP-EXCLUDE:_'),     {}, 'BINDSNAP-EXCLUDE:_ -> {} (colon present, "_" is not an mpN)');
is_deeply( $ex->('BINDSNAP-EXCLUDE: junk'), {}, 'non-mpN value -> {} (empty exclusion)');
is_deeply( $ex->('#### BINDSNAP-EXCLUDE:'), {}, 'empty directive as a heading -> {}');
is_deeply( $ex->('BINDSNAP-EXCLUDE: rootfs'), {},
    'rootfs-only directive -> {} (rootfs can never be excluded)');

# --- directive with keys ---
is_deeply( $ex->('BINDSNAP-EXCLUDE: mp1'),      { mp1 => 1 },           'single key');
is_deeply( $ex->('BINDSNAP-EXCLUDE: mp1 mp2'),  { mp1 => 1, mp2 => 1 }, 'space-separated keys');
is_deeply( $ex->('BINDSNAP-EXCLUDE: mp1,mp2'),  { mp1 => 1, mp2 => 1 }, 'comma-separated keys');
is_deeply( $ex->('BINDSNAP-EXCLUDE: mp1, mp2'), { mp1 => 1, mp2 => 1 }, 'comma+space separated');
is_deeply( $ex->('BINDSNAP-EXCLUDE=mp1'),       { mp1 => 1 },           'equals separator works');

# --- heading levels are optional cosmetic; 0..6 hashes all match ---
is_deeply( $ex->('#### BINDSNAP-EXCLUDE: mp1'),   { mp1 => 1 }, '#### heading matches');
is_deeply( $ex->('###### BINDSNAP-EXCLUDE: mp1'), { mp1 => 1 }, '###### heading matches');
is_deeply( $ex->('# BINDSNAP-EXCLUDE: mp1'),      { mp1 => 1 }, 'single-# (PVE-folded) matches');

# --- mp keys are mpN only ---
is_deeply( $ex->('BINDSNAP-EXCLUDE: rootfs mp1'), { mp1 => 1 },           'rootfs dropped, mp kept');
is_deeply( $ex->('BINDSNAP-EXCLUDE: mp1 garbage'),{ mp1 => 1 },           'unknown token dropped');
is_deeply( $ex->('BINDSNAP-EXCLUDE: dev0 mp1'),   { mp1 => 1 },           'devN dropped (binds handled elsewhere)');
is_deeply( $ex->('BINDSNAP-EXCLUDE: mp10 mp2'),   { mp10 => 1, mp2 => 1 },'multi-digit mpN');

# --- the directive may sit on any line of a multi-line description ---
is_deeply( $ex->("first note\nsecond note\n#### BINDSNAP-EXCLUDE: mp3\ntrailing"),
    { mp3 => 1 }, 'directive on a later line is found');
is_deeply( $ex->("#### BINDSNAP-EXCLUDE: mp1\nrest of notes"),
    { mp1 => 1 }, 'directive on the first line is found');

done_testing();
