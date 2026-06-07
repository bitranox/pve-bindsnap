# pve-bindsnap -- thin diversion wrapper for PVE::LXC::Config.
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 bitranox  (see LICENSE: GNU AGPL v3.0)
# =====================================================================
# install.sh installs THIS file at /usr/share/perl5/PVE/LXC/Config.pm, AFTER
# dpkg-divert has renamed the genuine upstream module to Config.pm.distrib in
# the same directory. It does two things, in this order, and nothing else:
#
#   1. Load the GENUINE upstream module (the diverted .distrib). It declares
#      `package PVE::LXC::Config; use base qw(PVE::AbstractConfig)` and defines
#      has_feature / __snapshot_* etc. This MUST succeed: if it cannot load,
#      PVE::LXC::Config is genuinely broken and we let the failure propagate
#      (same outcome as without us). This is the one accepted point of failure.
#
#   2. Load our additive overlay, whose load-time _apply() captures the live
#      upstream methods (via ->can) and redefines the snapshot methods in
#      PVE::LXC::Config. This is eval-guarded so an overlay bug can NEVER stop
#      PVE::LXC::Config from loading (that would prevent pvedaemon/pveproxy/pct
#      from starting). On overlay failure we are simply back to stock behaviour.
#
# pvedaemon/pveproxy/pct run `perl -T` (taint), where a module is only honoured if
# it loads from @INC as part of the program -- so diverting PVE::LXC::Config and
# loading the overlay from here covers the GUI, the API and every pct invocation.
# dpkg-divert reroutes pve-container upgrades to .distrib, so step 1 always
# delegates to live upstream.
# =====================================================================

# 1) genuine upstream -- absolute-path file require, MUST succeed (no eval).
#    Constant string literal => taint-safe. Distinct %INC key from
#    'PVE/LXC/Config.pm', so the overlay's `require PVE::LXC::Config` (already in
#    %INC at this point) stays a harmless no-op.
require '/usr/share/perl5/PVE/LXC/Config.pm.distrib';

# 2) additive overlay -- eval-guarded so it can never brick Config.pm.
eval {
    require PVE::LXC::BindSnap;
    1;
} or do {
    warn "pve-bindsnap: overlay not loaded ($@); PVE::LXC::Config is stock\n";
};

1;
