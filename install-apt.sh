#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# pve-bindsnap -- apt installer
# ---------------------------------------------------------------------
# Adds the pve-bindsnap apt repository to this Proxmox VE node and installs the
# pve-bindsnap package. From then on it is updated like any other package: in the GUI
# (Node -> Updates -> Upgrade) or with apt-get upgrade, together with Proxmox itself.
# This is the alternative to install.sh; a node installed by install.sh is taken over
# by the package as it stands. Run on each node; re-running is idempotent.
#   curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install-apt.sh | bash
#
#   install-apt.sh                    add the repository and install the package
#   install-apt.sh --no-install       only add the repository (and run apt-get update)
#   install-apt.sh --remove           remove the repository and its key
#   install-apt.sh --remove --purge   also purge the package (restores stock Proxmox)
#   install-apt.sh --repo-url URL     use another repository (a mirror, a test repo)
#
# The repository is signed with the archive key embedded below, fingerprint
#   1445 C598 166A 481A C529  2FE1 A5A5 351D 2BC8 8FDC
# and apt trusts it for this repository only (Signed-By), never system-wide.
# =====================================================================
set -euo pipefail

REPO_URL="https://github.com/bitranox/pve-bindsnap/releases/latest/download/"
KEYRING="/usr/share/keyrings/pve-bindsnap-archive-keyring.asc"
SOURCES="/etc/apt/sources.list.d/pve-bindsnap.sources"
PACKAGE="pve-bindsnap"
export DEBIAN_FRONTEND=noninteractive

usage() {
    sed -n 's/^#   install-apt.sh/  install-apt.sh/p' "${BASH_SOURCE[0]}" 2>/dev/null ||
        echo "usage: install-apt.sh [--no-install | --remove [--purge]] [--repo-url URL]"
}

archive_key() {
    cat <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEauY7mRYJKwYBBAHaRw8BAQdA4FylmhwmFTDwowzW5amQ98DmMViecTL0CKea
QGHWlXq0OXB2ZS1iaW5kc25hcCBhcmNoaXZlIHNpZ25pbmcga2V5IDxybm93b3Ru
eTE5NjZAZ21haWwuY29tPoiQBBMWCgA4FiEEFEXFmBZqSBrFKS/hpaU1HSvIj9wF
AmrmO5kCGwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQpaU1HSvIj9yKIwEA
ixda1aCX9wHOOXn7EX9+nEGwIqqd2Lk81sev7pZ+j84A/AvTiQo+bizcKCwkFn/m
xF6bar+v0xXWB5DcnSmqF38M
=T7Z6
-----END PGP PUBLIC KEY BLOCK-----
KEY
}

package_installed() {
    local status
    status="$(dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null || true)"
    case "$status" in
    "" | *" not-installed" | *" config-files") return 1 ;;
    *) return 0 ;;
    esac
}

require_root_on_pve() {
    [ "$(id -u)" -eq 0 ] || {
        echo "!! run as root" >&2
        exit 1
    }
    command -v pveversion >/dev/null 2>&1 && [ -e /usr/share/perl5/PVE/LXC/Config.pm ] || {
        echo "!! this is not a Proxmox VE node (no pveversion / PVE::LXC::Config)" >&2
        exit 1
    }
    local codename
    codename="$(sed -n 's/^VERSION_CODENAME="\{0,1\}\([a-z]*\)"\{0,1\}$/\1/p' /etc/os-release)"
    [ "$codename" = "trixie" ] || {
        echo "!! pve-bindsnap packages are built for Proxmox VE 9 (Debian trixie); this is '$codename'" >&2
        exit 1
    }
}

write_source() {
    echo ">> writing the archive key -> $KEYRING"
    install -d -m 0755 "$(dirname "$KEYRING")"
    archive_key >"$KEYRING.tmp"
    chmod 0644 "$KEYRING.tmp"
    mv "$KEYRING.tmp" "$KEYRING"

    echo ">> writing the repository -> $SOURCES ($REPO_URL)"
    cat >"$SOURCES.tmp" <<EOF
# pve-bindsnap -- added by install-apt.sh; remove with: install-apt.sh --remove
Types: deb
URIs: $REPO_URL
Suites: ./
Signed-By: $KEYRING
EOF
    chmod 0644 "$SOURCES.tmp"
    mv "$SOURCES.tmp" "$SOURCES"
}

# Refresh only this repository: a failing third-party or enterprise repository must not
# stop the install, and the rest of the index stays as the node's own updates left it.
update_this_source() {
    local parts
    echo ">> apt-get update (pve-bindsnap repository only)"
    parts="$(mktemp -d)"
    cp "$SOURCES" "$parts/"
    apt-get update -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts="$parts" \
        -o APT::Get::List-Cleanup=0 || {
        rm -rf "$parts"
        return 1
    }
    rm -rf "$parts"
}

do_install() {
    require_root_on_pve
    write_source
    update_this_source
    [ "$NO_INSTALL" -eq 1 ] && {
        echo ">> repository added; install with: apt-get install $PACKAGE"
        return
    }
    if ! package_installed && dpkg-divert --list 2>/dev/null | grep -q "by $PACKAGE\$"; then
        echo ">> found an install.sh installation; the package takes it over"
    fi
    echo ">> apt-get install $PACKAGE"
    apt-get install -y "$PACKAGE"
    echo
    echo "Done. Updates now arrive with the Proxmox ones (GUI: Node -> Updates)."
    echo "The guard state is in the apt output above and in:"
    echo "  journalctl -u pvedaemon -b | grep pve-bindsnap"
}

do_remove() {
    require_root_on_pve
    if [ "$PURGE" -eq 1 ] && package_installed; then
        echo ">> apt-get purge $PACKAGE (restores the stock Proxmox modules)"
        apt-get purge -y "$PACKAGE"
    elif package_installed; then
        echo "   note: the $PACKAGE package stays installed (add --purge to remove it too)"
    fi
    rm -f "$SOURCES" "$KEYRING"
    echo ">> removed $SOURCES and $KEYRING"
    # A full update drops the removed repository's index files. Other repositories that
    # fail to refresh (no subscription, offline) must not turn the removal into an error.
    echo ">> apt-get update"
    apt-get update || echo "   (apt-get update reported errors from other repositories; the removal is complete)"
}

MODE=install
NO_INSTALL=0
PURGE=0
while [ $# -gt 0 ]; do
    case "$1" in
    --no-install) NO_INSTALL=1 ;;
    --remove) MODE=remove ;;
    --purge) PURGE=1 ;;
    --repo-url)
        [ $# -ge 2 ] || {
            echo "!! --repo-url needs a URL" >&2
            exit 2
        }
        REPO_URL="${2%/}/" # a flat repository URL must end in /
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "!! unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
done
[ "$PURGE" -eq 0 ] || [ "$MODE" = remove ] || {
    echo "!! --purge only goes with --remove" >&2
    exit 2
}

if [ "$MODE" = remove ]; then
    do_remove
else
    do_install
fi
