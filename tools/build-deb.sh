#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# pve-bindsnap -- build the Debian package
# ---------------------------------------------------------------------
# Writes dist/pve-bindsnap_<version>_all.deb from this checkout with plain dpkg-deb, no
# debhelper. Reproducible: every mtime is clamped to SOURCE_DATE_EPOCH (default: the
# last commit's time) and ownership is root:root.
#   tools/build-deb.sh                  version = $VERSION in BindSnap.pm
#   PKG_VERSION=1.4.0~e2e1 tools/build-deb.sh
#   OUT_DIR=/some/dir tools/build-deb.sh
# =====================================================================
set -euo pipefail
umask 022 # a group-writable dir in the package would land group-writable on the node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/lib/PVE/LXC/BindSnap.pm"
PERL5="usr/share/perl5"
DOC="usr/share/doc/pve-bindsnap"

module_version() {
    sed -n "s/^our \$VERSION = '\([^']*\)';\$/\1/p" "$MODULE"
}

VERSION="${PKG_VERSION:-$(module_version)}"
[ -n "$VERSION" ] || {
    echo "!! no version (PKG_VERSION unset and none found in $MODULE)" >&2
    exit 1
}
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct)}"
export SOURCE_DATE_EPOCH

stage="$(mktemp -d)"
chmod 0755 "$stage" # mktemp makes it 0700; dpkg-deb would record that for ./
trap 'rm -rf "$stage"' EXIT

stage_payload() {
    install -D -m 0644 "$MODULE" "$stage/$PERL5/PVE/LXC/BindSnap.pm"
    install -d "$stage/$PERL5/PVE/LXC/BindSnap/Clone"
    install -m 0644 "$ROOT"/lib/PVE/LXC/BindSnap/Clone/*.pm "$stage/$PERL5/PVE/LXC/BindSnap/Clone/"
    install -D -m 0644 "$ROOT/lib/PVE/LXC/Config.wrapper.pm" "$stage/$PERL5/PVE/LXC/Config.pm"
    install -D -m 0644 "$ROOT/lib/PVE/API2/LXC.wrapper.pm" "$stage/$PERL5/PVE/API2/LXC.pm"
    install -D -m 0644 "$ROOT/LICENSE" "$stage/$DOC/copyright"
    install -d "$stage/$DOC"
    gzip -9nc "$ROOT/CHANGELOG.md" >"$stage/$DOC/changelog.gz"
    chmod 0644 "$stage/$DOC/changelog.gz"
}

stage_control() {
    local size
    install -d "$stage/DEBIAN"
    size="$(du -sk --apparent-size "$stage/usr" | cut -f1)"
    sed -e "s/@VERSION@/$VERSION/" -e "s/@SIZE@/$size/" "$ROOT/debian/control" >"$stage/DEBIAN/control"
    install -m 0755 "$ROOT/debian/preinst" "$ROOT/debian/postinst" "$ROOT/debian/postrm" "$stage/DEBIAN/"
    install -m 0644 "$ROOT/debian/triggers" "$stage/DEBIAN/"
    (cd "$stage" && find usr -type f -print0 | sort -z | xargs -0 md5sum) >"$stage/DEBIAN/md5sums"
    chmod 0644 "$stage/DEBIAN/control" "$stage/DEBIAN/md5sums"
}

stage_payload
stage_control
find "$stage" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

mkdir -p "$OUT_DIR"
deb="$OUT_DIR/pve-bindsnap_${VERSION}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb" >/dev/null
echo "$deb"
