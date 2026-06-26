#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# pve-bindsnap -- installer
# ---------------------------------------------------------------------
# Diverts PVE::LXC::Config and installs a thin wrapper that loads the genuine
# upstream plus the snapshot overlay, so the GUI, API and pct are all covered.
# Fully reversible (uninstall.sh). The source is on GitHub if you want to read it
# first. Run on ONE node only; re-running is idempotent. Works from a checkout
# (./install.sh) and piped:
#   curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install.sh | bash
# =====================================================================
set -euo pipefail

REPO_URL="https://github.com/bitranox/pve-bindsnap"

# NOTE: these path/service constants are duplicated in uninstall.sh on purpose --
# each script must stay standalone so `curl ... | bash` works (a piped script can't
# source a sibling). Keep the two in sync if any of them ever changes.
# The overlay module loads from Perl's default @INC, on local root, in a
# version-independent dir (survives perl upgrades).
DEST_MOD="/usr/local/lib/site_perl/PVE/LXC/BindSnap.pm"
# The modules we divert, and where dpkg-divert keeps the genuine upstream. Two diverts:
# Config.pm carries the snapshot overlay; API2/LXC.pm carries the clone override.
CONFIG_PM="/usr/share/perl5/PVE/LXC/Config.pm"
CONFIG_DISTRIB="/usr/share/perl5/PVE/LXC/Config.pm.distrib"
API_PM="/usr/share/perl5/PVE/API2/LXC.pm"
API_DISTRIB="/usr/share/perl5/PVE/API2/LXC.pm.distrib"
DIVERT_TAG="pve-bindsnap"
SERVICES=(pvedaemon pveproxy pvestatd)

# Roll back on ANY failure once the divert is in place, so the node is never left with
# Config.pm diverted away and no wrapper (which would break the LXC stack). The trap is
# armed the moment the divert exists (DIVERT_ACTIVE=1) and disarmed once the load is
# verified (INSTALL_OK=1); it also removes the temp dir from the piped path. A clean
# run that verifies fine never rolls back. Rolling back restores the genuine upstream
# Config.pm, which is always a safe (stock) state.
tmp=""
DIVERT_ACTIVE=0
INSTALL_OK=0
cleanup() {
    [ -n "$tmp" ] && rm -rf "$tmp"
    if [ "$DIVERT_ACTIVE" -eq 1 ] && [ "$INSTALL_OK" -eq 0 ]; then
        echo "!! install aborted -- rolling back; node restored to stock PVE modules." >&2
        # Remove BOTH wrappers FIRST so reverting each divert can move .distrib back onto
        # a free path, then revert BOTH diverts (reverting an absent one is a harmless
        # no-op via || true), then drop the overlay module. Covers the window where only
        # the first divert is in place too.
        rm -f "$CONFIG_PM" "$API_PM"
        dpkg-divert --remove --rename --package "$DIVERT_TAG" --divert "$CONFIG_DISTRIB" "$CONFIG_PM" 2>/dev/null || true
        dpkg-divert --remove --rename --package "$DIVERT_TAG" --divert "$API_DISTRIB" "$API_PM" 2>/dev/null || true
        rm -f "$DEST_MOD"
    fi
}
trap cleanup EXIT

# Use the files next to this script if they're here (checkout/tarball). If they
# aren't (piped one-liner), fetch a tarball into a temp dir and use that.
SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/lib/PVE/LXC/BindSnap.pm" ]; then
    echo ">> fetching files from $REPO_URL (main) ..."
    tmp="$(mktemp -d)"
    curl -fsSL "$REPO_URL/archive/refs/heads/main.tar.gz" | tar -xz -C "$tmp"
    SRC_DIR="$tmp/pve-bindsnap-main"
fi
if [ ! -f "$SRC_DIR/lib/PVE/LXC/BindSnap.pm" ] || [ ! -f "$SRC_DIR/lib/PVE/API2/LXC.wrapper.pm" ]; then
    echo "!! could not locate the overlay source (fetch failed?)" >&2
    exit 1
fi

[ -e "$CONFIG_PM" ] || {
    echo "!! $CONFIG_PM not found -- is this a Proxmox node?" >&2
    exit 1
}
[ -e "$API_PM" ] || {
    echo "!! $API_PM not found -- is this a Proxmox node?" >&2
    exit 1
}

echo ">> installing overlay module -> $DEST_MOD"
install -D -m 0644 "$SRC_DIR/lib/PVE/LXC/BindSnap.pm" "$DEST_MOD"
perl -c "$DEST_MOD"

echo ">> diverting $CONFIG_PM -> $CONFIG_DISTRIB"
if dpkg-divert --list "$CONFIG_PM" 2>/dev/null | grep -q "by $DIVERT_TAG"; then
    echo "   already diverted by us"
else
    dpkg-divert --add --rename --package "$DIVERT_TAG" --divert "$CONFIG_DISTRIB" "$CONFIG_PM"
fi
DIVERT_ACTIVE=1 # divert is in place -> any failure from here rolls back (see cleanup)
[ -e "$CONFIG_DISTRIB" ] || {
    echo "!! divert did not produce $CONFIG_DISTRIB" >&2
    exit 1
}

echo ">> installing wrapper -> $CONFIG_PM"
install -D -m 0644 "$SRC_DIR/lib/PVE/LXC/Config.wrapper.pm" "$CONFIG_PM"

echo ">> diverting $API_PM -> $API_DISTRIB"
if dpkg-divert --list "$API_PM" 2>/dev/null | grep -q "by $DIVERT_TAG"; then
    echo "   already diverted by us"
else
    dpkg-divert --add --rename --package "$DIVERT_TAG" --divert "$API_DISTRIB" "$API_PM"
fi
[ -e "$API_DISTRIB" ] || {
    echo "!! divert did not produce $API_DISTRIB" >&2
    exit 1
}

echo ">> installing wrapper -> $API_PM"
install -D -m 0644 "$SRC_DIR/lib/PVE/API2/LXC.wrapper.pm" "$API_PM"

# CRITICAL pre-flight: load PVE::LXC::Config exactly as a daemon will (default @INC,
# wrapper -> .distrib -> overlay) and confirm the overlay applied -- BEFORE restarting
# any daemon. On failure (here, or anywhere since the divert) the EXIT trap rolls back to
# stock; the daemons are never touched.
echo ">> verifying the diverted module loads and the overlay applies"
perl -e 'require PVE::LXC::Config; exit($PVE::LXC::BindSnap::APPLIED ? 0 : 1)' >/dev/null 2>&1 || {
    echo "!! PRE-FLIGHT FAILED -- the snapshot overlay did not apply." >&2
    exit 1
}

# Pre-flight the clone wrapper chain too: load PVE::API2::LXC through the wrapper
# (-> .distrib -> overlay -> apply_clone) and confirm apply_clone ran (CLONE_LOADED).
# We assert CLONE_LOADED (the wrapper chain works), NOT CLONE_APPLIED (the override is
# active), so installing on an UNTESTED build does not roll back -- clone simply stays
# stock there, exactly as snapshots run in TEST mode.
echo ">> verifying the diverted API module loads and the clone overlay ran"
perl -e 'require PVE::API2::LXC; exit($PVE::LXC::BindSnap::CLONE_LOADED ? 0 : 1)' >/dev/null 2>&1 || {
    echo "!! PRE-FLIGHT FAILED -- the clone overlay did not load." >&2
    exit 1
}
INSTALL_OK=1 # verified good -> disarm rollback; from here we only restart daemons

echo ">> restarting ${SERVICES[*]}"
systemctl restart "${SERVICES[@]}"

echo ">> activation line from the journal:"
line=""
for _ in 1 2 3 4 5; do
    line=$(journalctl -u pvedaemon -b --no-pager 2>/dev/null | grep -E 'pve-bindsnap:' | tail -n1 || true)
    [ -n "$line" ] && break
    sleep 1
done
if [ -n "$line" ]; then
    echo "   $line"
else
    echo "   (none yet -- check: journalctl -u pvedaemon -b | grep pve-bindsnap)"
fi
echo
echo "A 'checksum-validated' line means this pve-container is in the known-good table."
echo "An 'in TEST mode ... is untested' line means it is not: bind-mount CT snapshots are"
echo "refused unless the snapshot name/Description contains BINDSNAP-UNSUPPORTED (other CTs are unaffected)."
