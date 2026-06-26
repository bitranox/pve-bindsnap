# pve-bindsnap -- thin diversion wrapper for PVE::API2::LXC.
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# install.sh installs THIS file at /usr/share/perl5/PVE/API2/LXC.pm, AFTER
# dpkg-divert has renamed the genuine upstream module to LXC.pm.distrib in the
# same directory. It does two things, in this order, and nothing else:
#
#   1. Load the GENUINE upstream module (the diverted .distrib). It declares
#      `package PVE::API2::LXC` and register_method()s the LXC API, including
#      clone_vm. This MUST succeed: if it cannot load, PVE::API2::LXC is genuinely
#      broken and we let the failure propagate (same outcome as without us). This
#      is the one accepted point of failure.
#
#   2. Load our additive overlay and call apply_clone(), which (on a checksum-
#      validated build) replaces the registered clone_vm method's {code} with a
#      copy that carries bind/device mountpoints to the clone instead of dying.
#      This is eval-guarded so an overlay bug can NEVER stop PVE::API2::LXC from
#      loading; on failure we are simply back to stock clone behaviour.
#
# pvedaemon/pveproxy/pct run `perl -T` (taint), where a module is only honoured if it
# loads from @INC as part of the program -- so diverting PVE::API2::LXC and loading the
# overlay from here covers the GUI, the API and every pct invocation. dpkg-divert
# reroutes pve-container upgrades to .distrib, so step 1 always delegates to live upstream.
# =====================================================================

# 1) genuine upstream -- absolute-path file require, MUST succeed (no eval).
#    Constant string literal => taint-safe. Registers the stock clone_vm that
#    apply_clone() then overrides.
require '/usr/share/perl5/PVE/API2/LXC.pm.distrib';

# 2) additive overlay -- eval-guarded so it can never brick PVE::API2::LXC.
eval {
    require PVE::LXC::BindSnap;
    PVE::LXC::BindSnap::apply_clone();
    1;
} or do {
    warn "pve-bindsnap: clone overlay not applied ($@); PVE::API2::LXC clone is stock\n";
};

1;
