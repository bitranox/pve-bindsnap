#!/usr/bin/perl
# Opt-in marker matching (_has_marker): case-sensitive, bounded by non-alphanumerics
# (so '_' and '-' are separators) -- casual prose and letter/digit gluing never trigger
# BINDSNAP-FORCE-RUNNING / BINDSNAP-UNSUPPORTED by accident, but an underscore-joined auto-name
# (BINDSNAP-FORCE-RUNNING_2026...) does. The same helper detects the standing form in the
# CT Notes, so these cases cover both the per-snapshot and the standing use.
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

my $has = PVE::LXC::BindSnap->can('_has_marker')
    or BAIL_OUT('_has_marker missing');

# matches: standalone, or set off by a hyphen/underscore/space (name, description or Notes)
ok( $has->('BINDSNAP-UNSUPPORTED', 'BINDSNAP-UNSUPPORTED'),            'standalone matches');
ok( $has->('BINDSNAP-UNSUPPORTED-test', 'BINDSNAP-UNSUPPORTED'),       'hyphen suffix matches');
ok( $has->('test-BINDSNAP-UNSUPPORTED', 'BINDSNAP-UNSUPPORTED'),       'hyphen prefix matches');
ok( $has->('BINDSNAP-UNSUPPORTED_2026', 'BINDSNAP-UNSUPPORTED'),       'underscore suffix matches (glue)');
ok( $has->('auto_BINDSNAP-UNSUPPORTED_x', 'BINDSNAP-UNSUPPORTED'),     'underscore both sides matches (glue)');
ok( $has->('please BINDSNAP-UNSUPPORTED now', 'BINDSNAP-UNSUPPORTED'), 'spaced in description matches');

# does NOT match: glued by letters/digits, wrong case, empty/undef
ok( !$has->('myBINDSNAP-UNSUPPORTEDx', 'BINDSNAP-UNSUPPORTED'), 'letter-glued does NOT match');
ok( !$has->('BINDSNAP-UNSUPPORTED9', 'BINDSNAP-UNSUPPORTED'),   'digit-glued does NOT match');
ok( !$has->('bindsnap-unsupported', 'BINDSNAP-UNSUPPORTED'),    'lowercase does NOT match (case-sensitive)');
ok( !$has->(undef, 'BINDSNAP-UNSUPPORTED'),                 'undef text does NOT match');
ok( !$has->('', 'BINDSNAP-UNSUPPORTED'),                    'empty text does NOT match');

# BINDSNAP-FORCE-RUNNING behaves the same: hyphen/underscore set it off, letter-gluing does not
ok(  $has->('BINDSNAP-FORCE-RUNNING pre-change', 'BINDSNAP-FORCE-RUNNING'), 'as a word matches');
ok(  $has->('pre-BINDSNAP-FORCE-RUNNING', 'BINDSNAP-FORCE-RUNNING'),        'hyphen prefix matches');
ok(  $has->('auto_BINDSNAP-FORCE-RUNNING_2026', 'BINDSNAP-FORCE-RUNNING'),  'underscore glue (auto-name) matches');
ok( !$has->('xBINDSNAP-FORCE-RUNNING', 'BINDSNAP-FORCE-RUNNING'),           'letter-glued prefix does NOT match');
ok( !$has->('bindsnap-force-running', 'BINDSNAP-FORCE-RUNNING'),            'lowercase does NOT match');

# the standing form lives in the CT Notes -- same helper, applied to the Notes text;
# a markdown heading or its own line both work, glued forms do not
ok( $has->("#### BINDSNAP-FORCE-RUNNING", 'BINDSNAP-FORCE-RUNNING'),         'heading line in Notes matches');
ok( $has->("first note\nBINDSNAP-UNSUPPORTED\nmore", 'BINDSNAP-UNSUPPORTED'),'bare line in Notes matches');
ok( $has->("notes\n#### BINDSNAP-FORCE-RUNNING\nx", 'BINDSNAP-FORCE-RUNNING'),'heading mid-Notes matches');

done_testing();
