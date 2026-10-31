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
#   tools/build-apt-repo.sh                       every dist/*.deb
#   tools/build-apt-repo.sh dist/pve-bindsnap_1.4.0_all.deb
#   APT_DIR=/some/dir tools/build-apt-repo.sh ...
# =====================================================================
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="${BINDSNAP_APT_KEY_FILE:-$HOME/.credentials/pve-bindsnap-apt-signing.key}"
PUBLIC_KEY="$ROOT/apt/pve-bindsnap-archive-keyring.asc"
APT_DIR="${APT_DIR:-$ROOT/dist/apt}"

debs=("$@")
if [ ${#debs[@]} -eq 0 ]; then
    shopt -s nullglob
    debs=("$ROOT"/dist/pve-bindsnap_*_all.deb)
    shopt -u nullglob
fi
[ ${#debs[@]} -gt 0 ] || {
    echo "!! no packages given and none in $ROOT/dist (run tools/build-deb.sh)" >&2
    exit 1
}
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
