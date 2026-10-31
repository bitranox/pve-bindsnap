#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# pve-bindsnap -- uninstaller
# Removes the wrappers, reverts both diverts (restoring the genuine PVE modules),
# and removes the overlay module and its clone variants. Idempotent; pipeable like the installer:
#   curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/uninstall.sh | bash
# =====================================================================
set -euo pipefail

# NOTE: these path/service constants are duplicated in install.sh on purpose --
# each script must stay standalone so `curl ... | bash` works (a piped script can't
# source a sibling). Keep the two in sync if any of them ever changes.
DEST_MOD="/usr/local/lib/site_perl/PVE/LXC/BindSnap.pm"
DEST_CLONE="/usr/local/lib/site_perl/PVE/LXC/BindSnap/Clone"
CONFIG_PM="/usr/share/perl5/PVE/LXC/Config.pm"
CONFIG_DISTRIB="/usr/share/perl5/PVE/LXC/Config.pm.distrib"
API_PM="/usr/share/perl5/PVE/API2/LXC.pm"
API_DISTRIB="/usr/share/perl5/PVE/API2/LXC.pm.distrib"
DIVERT_TAG="pve-bindsnap"
SERVICES=(pvedaemon pveproxy pvestatd)
changed=0

# The Debian package (install-apt.sh, or apt install pve-bindsnap) owns the same diverts
# and wrappers. Mixing the two would leave dpkg and this script fighting over the files,
# so refuse while the package is installed (a removed-but-not-purged package owns
# nothing and is fine).
package_installed() {
    local status
    status="$(dpkg-query -W -f='${Status}' pve-bindsnap 2>/dev/null || true)"
    case "$status" in
    "" | *" not-installed" | *" config-files") return 1 ;;
    *) return 0 ;;
    esac
}

if package_installed; then
    echo "!! the pve-bindsnap Debian package is installed; remove it with apt instead:" >&2
    echo "   apt-get purge pve-bindsnap" >&2
    exit 1
fi

# Remove BOTH our wrappers FIRST, so reverting each divert can move its .distrib back
# onto a free path. Only touch a wrapper if it is ours.
if [ -e "$CONFIG_PM" ] && grep -q "$DIVERT_TAG" "$CONFIG_PM" 2>/dev/null; then
    rm -f "$CONFIG_PM"
    changed=1
    echo "   - removed wrapper $CONFIG_PM"
fi
if [ -e "$API_PM" ] && grep -q "$DIVERT_TAG" "$API_PM" 2>/dev/null; then
    rm -f "$API_PM"
    changed=1
    echo "   - removed wrapper $API_PM"
fi

# Revert the diverts: move each genuine upstream from .distrib back to its real path.
if dpkg-divert --list "$CONFIG_PM" 2>/dev/null | grep -q "by $DIVERT_TAG"; then
    dpkg-divert --remove --rename --package "$DIVERT_TAG" --divert "$CONFIG_DISTRIB" "$CONFIG_PM"
    changed=1
    echo "   - reverted divert (restored $CONFIG_PM)"
fi
if dpkg-divert --list "$API_PM" 2>/dev/null | grep -q "by $DIVERT_TAG"; then
    dpkg-divert --remove --rename --package "$DIVERT_TAG" --divert "$API_DISTRIB" "$API_PM"
    changed=1
    echo "   - reverted divert (restored $API_PM)"
fi

if [ -f "$DEST_MOD" ]; then
    rm -f "$DEST_MOD"
    changed=1
    echo "   - removed $DEST_MOD"
fi
if [ -d "$(dirname "$DEST_CLONE")" ]; then
    rm -rf "$(dirname "$DEST_CLONE")"
    changed=1
    echo "   - removed the clone_vm variants"
fi
# install.sh created these directories; stock Proxmox has none of them. Remove each
# once empty, innermost first, and stop at the first one something else still uses.
for d in /usr/local/lib/site_perl/PVE/LXC /usr/local/lib/site_perl/PVE /usr/local/lib/site_perl; do
    [ -d "$d" ] || continue
    rmdir "$d" 2>/dev/null || break
done

if [ "$changed" -eq 0 ]; then
    echo ">> nothing of ours was installed; no changes made."
    exit 0
fi

echo ">> restarting ${SERVICES[*]}"
systemctl restart "${SERVICES[@]}"
echo ">> done. Stock behaviour restored."
echo "   NOTE: any snapshots you already TOOK still exist as zfs snapshots and"
echo "   in the CT config -- list with: zfs list -t snapshot | grep subvol-<vmid>"
