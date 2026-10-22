#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# pve-bindsnap -- vet a pve-container build
# ---------------------------------------------------------------------
# Makes vetting a new pve-container release mechanical: downloads the .deb packages from
# the Proxmox mirror, extracts them into temp dirs (nothing from them is ever executed;
# perl only reads the files, and the extracted packages are never on its @INC -- it loads
# the module from the repo's lib/), and computes the same two checksums the overlay checks
# at load time by calling the module itself:
#   - the snapshot guard: combined sha256 over Config.pm + AbstractConfig.pm
#   - the clone guard:    sha256 of the clone_vm block of API2/LXC.pm
# Each is looked up in the module's known-good / known-bad tables and reported as
# known-good / known-bad / new. With a reference version, it also diffs Config.pm and the
# clone_vm block against that (already vetted) build, to see what changed upstream.
#
# The downloads are NOT signature-verified (no apt/gpg check), so the output is advisory.
# Before adding a hash to a known-good table, confirm it on a node's apt-installed package:
# the overlay's journal line, or the manual commands in docs/checksum-guard.md and
# docs/compatible-versions.md.
#
# Usage:   tools/vet-build.sh <pve-container-version> [<reference-version>]
#   e.g.   tools/vet-build.sh 6.1.14 6.1.12
# Env:     MIRROR        default http://download.proxmox.com/debian/pve
#          SUITE         default trixie
#          COMPONENT     default pve-no-subscription
#          GUEST_COMMON  libpve-guest-common-perl version (AbstractConfig.pm); default: the
#                        newest one listed in the component's binary-amd64/Packages.gz
#                        (used for BOTH builds, so only Config.pm / API2/LXC.pm differ)
# Needs: bash, curl, gzip, xz, ar, tar, awk, diff, mktemp, sort -V, perl (no dpkg-deb;
#        works on Linux and macOS).
# =====================================================================
set -euo pipefail

MIRROR="${MIRROR:-http://download.proxmox.com/debian/pve}"
SUITE="${SUITE:-trixie}"
COMPONENT="${COMPONENT:-pve-no-subscription}"
GUEST_COMMON="${GUEST_COMMON:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$MIRROR/dists/$SUITE/$COMPONENT/binary-amd64"

CONFIG_REL="usr/share/perl5/PVE/LXC/Config.pm"
API_REL="usr/share/perl5/PVE/API2/LXC.pm"
ABSTRACT_REL="usr/share/perl5/PVE/AbstractConfig.pm"

die() {
    echo "!! $*" >&2
    exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: $0 <pve-container-version> [<reference-version>]"
TARGET="$1"
REFERENCE="${2:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The perl side: the module does all the hashing and holds the tables, nothing is
# reimplemented here. Loading it off-node logs one harmless line to STDERR (its load-time
# apply cannot find PVE::LXC::Config), so STDERR is silenced around the require.
#   report  LABEL CONFIG ABSTRACT API   print both checksums and their table status
#   clone-sha   API                     print the clone_vm block sha256 (empty if none)
#   clone-block API                     print the clone_vm block
PERL_PROG=$(
    cat <<'PERL'
use strict;
use warnings;
BEGIN {
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', '/dev/null')   or die "redir STDERR: $!";
    my $err;
    { local $@; eval { require PVE::LXC::BindSnap; 1 } or $err = $@; }
    open(STDERR, '>&', $olderr)      or die "restore STDERR: $!";
    die $err if defined $err;
}
my $m = 'PVE::LXC::BindSnap';
my ($mode, @a) = @ARGV;

sub status {
    my ($hash, $good, $bad) = @_;
    return 'unknown (a file could not be hashed)' unless defined $hash;
    return "KNOWN-BAD ($bad->{$hash})" if exists $bad->{$hash};
    return "known-good ($good->{$hash})" if exists $good->{$hash};
    return 'NEW (in neither table)';
}

no strict 'refs';
if ($mode eq 'report') {
    my ($label, $config, $abstract, $api) = @a;
    my ($combined, $per) = $m->can('_config_checksum')->($config, $abstract);
    my $clone = $m->can('_clone_checksum')->($api);
    print "== $label\n";
    print "snapshot guard (Config.pm + AbstractConfig.pm)\n";
    print "  combined          ", $combined // '(none)', "\n";
    print "  Config.pm         ", $per->{$config} // '(unreadable)', "\n";
    print "  AbstractConfig.pm ", $per->{$abstract} // '(unreadable)', "\n";
    print "  status            ",
        status($combined, \%{"${m}::KNOWN_GOOD_CHECKSUMS"}, \%{"${m}::KNOWN_BAD_CHECKSUMS"}), "\n";
    print "clone guard (clone_vm block of API2/LXC.pm)\n";
    print "  clone_vm          ", $clone // '(no clone_vm block found)', "\n";
    print "  status            ",
        status($clone, \%{"${m}::KNOWN_GOOD_CLONE_CHECKSUMS"}, \%{"${m}::KNOWN_BAD_CLONE_CHECKSUMS"}),
        "\n";
    exit(defined $combined && defined $clone ? 0 : 1);
} elsif ($mode eq 'clone-sha') {
    print $m->can('_clone_checksum')->($a[0]) // '', "\n";
} elsif ($mode eq 'clone-block') {
    my $b = $m->can('_clone_block')->($a[0]);
    defined $b or exit 1;
    print $b;
} else {
    die "bad mode $mode\n";
}
PERL
)

vperl() {
    perl -I "$REPO/lib" -e "$PERL_PROG" -- "$@"
}

fetch() { # fetch URL DEST
    curl -fsSL -o "$2" "$1" || die "download failed: $1"
}

# fetch_pkg PKG VERSION DIR -- download PKG_VERSION_all.deb and extract it into DIR
fetch_pkg() {
    local pkg="$1" ver="$2" dir="$3" deb
    deb="${pkg}_${ver}_all.deb"
    mkdir -p "$dir"
    echo ">> fetching $deb"
    fetch "$BASE/$deb" "$dir/$deb"
    (cd "$dir" && ar x "$deb" && tar -xf data.tar.*) || die "could not extract $deb"
    rm -f "$dir"/"$deb"
}

need_file() {
    [ -f "$1" ] || die "missing in package: ${1#"$tmp"/}"
}

if [ -z "$GUEST_COMMON" ]; then
    echo ">> looking up the newest libpve-guest-common-perl in $BASE/Packages.gz"
    fetch "$BASE/Packages.gz" "$tmp/Packages.gz"
    GUEST_COMMON="$(gzip -dc "$tmp/Packages.gz" |
        awk '/^Package: /{p=($2=="libpve-guest-common-perl")} p&&/^Version: /{print $2}' |
        sort -V | tail -n1)"
    [ -n "$GUEST_COMMON" ] || die "libpve-guest-common-perl not found in $BASE/Packages.gz"
fi

fetch_pkg libpve-guest-common-perl "$GUEST_COMMON" "$tmp/guest-common"
fetch_pkg pve-container "$TARGET" "$tmp/target"
ABSTRACT="$tmp/guest-common/$ABSTRACT_REL"
T_CONFIG="$tmp/target/$CONFIG_REL"
T_API="$tmp/target/$API_REL"
need_file "$ABSTRACT"
need_file "$T_CONFIG"
need_file "$T_API"

if [ -n "$REFERENCE" ]; then
    fetch_pkg pve-container "$REFERENCE" "$tmp/reference"
    R_CONFIG="$tmp/reference/$CONFIG_REL"
    R_API="$tmp/reference/$API_REL"
    need_file "$R_CONFIG"
    need_file "$R_API"
fi

echo
echo "libpve-guest-common-perl $GUEST_COMMON (AbstractConfig.pm)${REFERENCE:+, same for both builds}"
echo
rc=0
vperl report "pve-container $TARGET (target)" "$T_CONFIG" "$ABSTRACT" "$T_API" || rc=1

if [ -n "$REFERENCE" ]; then
    echo
    vperl report "pve-container $REFERENCE (reference)" "$R_CONFIG" "$ABSTRACT" "$R_API" || rc=1

    echo
    echo "== Config.pm: reference $REFERENCE -> target $TARGET"
    if diff -u -L "Config.pm $REFERENCE" -L "Config.pm $TARGET" "$R_CONFIG" "$T_CONFIG"; then
        echo "identical"
    fi

    echo
    echo "== clone_vm block: reference $REFERENCE -> target $TARGET"
    r_sha="$(vperl clone-sha "$R_API")"
    t_sha="$(vperl clone-sha "$T_API")"
    if [ -n "$r_sha" ] && [ "$r_sha" = "$t_sha" ]; then
        echo "identical"
    elif [ -z "$r_sha" ] || [ -z "$t_sha" ]; then
        echo "cannot compare: no clone_vm block found in one of the builds"
        rc=1
    else
        vperl clone-block "$R_API" >"$tmp/clone-ref.txt"
        vperl clone-block "$T_API" >"$tmp/clone-target.txt"
        diff -u -L "clone_vm $REFERENCE" -L "clone_vm $TARGET" \
            "$tmp/clone-ref.txt" "$tmp/clone-target.txt" || true
    fi
fi

exit "$rc"
