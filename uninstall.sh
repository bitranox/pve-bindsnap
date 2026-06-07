#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# pve-bindsnap -- uninstaller
# Removes the wrapper, reverts the divert (restoring the genuine PVE::LXC::Config),
# and removes the overlay module. Idempotent; pipeable like the installer:
#   curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/uninstall.sh | bash
# =====================================================================
set -euo pipefail

# NOTE: these path/service constants are duplicated in install.sh on purpose --
# each script must stay standalone so `curl ... | bash` works (a piped script can't
# source a sibling). Keep the two in sync if any of them ever changes.
DEST_MOD="/usr/local/lib/site_perl/PVE/LXC/BindSnap.pm"
CONFIG_PM="/usr/share/perl5/PVE/LXC/Config.pm"
CONFIG_DISTRIB="/usr/share/perl5/PVE/LXC/Config.pm.distrib"
DIVERT_TAG="pve-bindsnap"
SERVICES=(pvedaemon pveproxy pvestatd)
changed=0

# Remove our wrapper FIRST, so reverting the divert can move .distrib back onto a
# free path. Only touch it if it is ours.
if [ -e "$CONFIG_PM" ] && grep -q "$DIVERT_TAG" "$CONFIG_PM" 2>/dev/null; then
    rm -f "$CONFIG_PM"
    changed=1
    echo "   - removed wrapper $CONFIG_PM"
fi

# Revert the divert: moves the genuine upstream from .distrib back to Config.pm.
if dpkg-divert --list "$CONFIG_PM" 2>/dev/null | grep -q "by $DIVERT_TAG"; then
    dpkg-divert --remove --rename --package "$DIVERT_TAG" --divert "$CONFIG_DISTRIB" "$CONFIG_PM"
    changed=1
    echo "   - reverted divert (restored $CONFIG_PM)"
fi

if [ -f "$DEST_MOD" ]; then
    rm -f "$DEST_MOD"
    changed=1
    echo "   - removed $DEST_MOD"
fi

if [ "$changed" -eq 0 ]; then
    echo ">> nothing of ours was installed; no changes made."
    exit 0
fi

echo ">> restarting ${SERVICES[*]}"
systemctl restart "${SERVICES[@]}"
echo ">> done. Stock behaviour restored."
echo "   NOTE: any snapshots you already TOOK still exist as zfs snapshots and"
echo "   in the CT config -- list with: zfs list -t snapshot | grep subvol-<vmid>"
