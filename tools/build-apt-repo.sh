#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# pve-bindsnap -- build the signed flat apt repository
# ---------------------------------------------------------------------
# Turns built packages into a flat repository (Packages, Packages.gz, Release, InRelease,
# Release.gpg and the .deb files) in dist/apt. A release uploads those files as its
# assets, so apt reads them from
#   https://github.com/bitranox/pve-bindsnap/releases/latest/download/  (suite ./)
# which install-apt.sh configures. Signs with the archive key, read from
# BINDSNAP_APT_KEY_FILE (default ~/.credentials/pve-bindsnap-apt-signing.key) into a
# throwaway GNUPGHOME; the private key is never in the repository.
#   tools/build-apt-repo.sh                       dist/pve-bindsnap_<VERSION>_all.deb only
#   PKG_VERSION=1.4.0~e2e1 tools/build-apt-repo.sh  (VERSION as tools/build-deb.sh resolves it)
#   tools/build-apt-repo.sh dist/pve-bindsnap_1.4.0_all.deb
#   APT_DIR=/some/dir tools/build-apt-repo.sh ...
# =====================================================================
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="${BINDSNAP_APT_KEY_FILE:-$HOME/.credentials/pve-bindsnap-apt-signing.key}"
PUBLIC_KEY="$ROOT/apt/pve-bindsnap-archive-keyring.asc"
APT_DIR="${APT_DIR:-$ROOT/dist/apt}"
MODULE="$ROOT/lib/PVE/LXC/BindSnap.pm"

# The same lookup as tools/build-deb.sh (t/13 keeps the two copies identical).
module_version() {
    sed -n "s/^our \$VERSION = '\([^']*\)';\$/\1/p" "$MODULE"
}

# With no arguments, index only the deb this checkout builds. dist/ keeps the debs of earlier
# builds, and a release carries only the new one: an index naming an old deb would send apt
# to a file the release does not have.
default_debs() {
    local version want other
    version="${PKG_VERSION:-$(module_version)}"
    [ -n "$version" ] || {
        echo "!! no version (PKG_VERSION unset and none found in $MODULE)" >&2
        return 1
    }
    want="$ROOT/dist/pve-bindsnap_${version}_all.deb"
    [ -f "$want" ] || {
        echo "!! $want not found (run tools/build-deb.sh)" >&2
        return 1
    }
    shopt -s nullglob
    for other in "$ROOT"/dist/pve-bindsnap_*_all.deb; do
        [ "$other" = "$want" ] || echo "   ignoring $other (not version $version)" >&2
    done
    shopt -u nullglob
    debs=("$want")
}

debs=("$@")
if [ ${#debs[@]} -eq 0 ]; then
    default_debs || exit 1
fi
[ -r "$KEY_FILE" ] || {
    echo "!! signing key not readable: $KEY_FILE" >&2
    exit 1
}

gnupg="$(mktemp -d)"
trap 'gpgconf --homedir "$gnupg" --kill all 2>/dev/null || true; rm -rf "$gnupg"' EXIT

rm -rf "$APT_DIR"
mkdir -p "$APT_DIR"
cp "${debs[@]}" "$APT_DIR/"

(
    cd "$APT_DIR"
    dpkg-scanpackages --multiversion . /dev/null >Packages 2>/dev/null
    gzip -9nk Packages
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=pve-bindsnap \
        -o APT::FTPArchive::Release::Label=pve-bindsnap \
        -o APT::FTPArchive::Release::Architectures=all \
        -o APT::FTPArchive::Release::Description="pve-bindsnap for Proxmox VE" \
        release . >Release.tmp
    mv Release.tmp Release
)

export GNUPGHOME="$gnupg"
gpg --batch --quiet --import "$KEY_FILE"
gpg --batch --yes --digest-algo SHA512 --clearsign -o "$APT_DIR/InRelease" "$APT_DIR/Release"
gpg --batch --yes --digest-algo SHA512 --armor --detach-sign -o "$APT_DIR/Release.gpg" "$APT_DIR/Release"

# Prove the signature verifies against the PUBLISHED public key, the one install-apt.sh
# embeds, not just against the key we signed with.
gpg --batch --dearmor <"$PUBLIC_KEY" >"$gnupg/published.gpg"
gpgv --keyring "$gnupg/published.gpg" "$APT_DIR/InRelease" 2>/dev/null
gpgv --keyring "$gnupg/published.gpg" "$APT_DIR/Release.gpg" "$APT_DIR/Release" 2>/dev/null

echo "$APT_DIR"
ls -1 "$APT_DIR"
