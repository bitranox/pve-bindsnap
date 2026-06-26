# pve-bindsnap -- enable Proxmox snapshots for bind-mount LXC CTs.
# Copyright (C) 2026 bitranox
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version. Distributed WITHOUT ANY WARRANTY; see the GNU AGPL for details
# (the LICENSE file, or <https://www.gnu.org/licenses/>).

package PVE::LXC::BindSnap;

use strict;
use warnings;

# =====================================================================
# pve-bindsnap                                       (1.1.0)
# ---------------------------------------------------------------------
# Lets Proxmox snapshot LXC containers that carry bind-/device-mount
# entries (mpN pointing at host paths), by hiding every non-'volume'
# mountpoint from the snapshot code path only. It ALSO lets `pct clone`
# clone such containers -- see the "clone support" section lower in this
# file (a second divert of PVE::API2::LXC, gated by its own checksum).
#
# WHY THIS SHAPE
#   * LOADED VIA DIVERT. install.sh dpkg-diverts /usr/share/perl5/PVE/LXC/
#     Config.pm to Config.pm.distrib and installs a thin wrapper at the
#     original path that require()s the genuine upstream (.distrib) and then
#     this overlay. pvedaemon/pveproxy/pct run `perl -T` (taint), where a
#     module is only honoured if it loads from @INC as part of the program --
#     so riding in on the PVE::LXC::Config load covers GUI, API and every pct
#     invocation. The wrapper loads us eval-guarded: an overlay bug can NOT
#     stop Config.pm from loading (it falls back to stock).
#   * DELEGATE TO LIVE UPSTREAM. The wrapper require()s the diverted .distrib,
#     which dpkg keeps current across pve-container upgrades, so we never carry
#     a stale fork. This module captures coderefs to those live methods via
#     ->can and calls them; only the thin bind filter is "ours".
#   * SINGLE choke point. Upstream funnels ALL snapshot volume
#     iteration through foreach_volume_full() (foreach_volume() just
#     delegates to it; __snapshot_activate_storages() calls it directly
#     and already self-filters type ne 'volume'). We wrap ONLY
#     foreach_volume_full, and only for the duration of a snapshot
#     call (dynamic `local` scope) -> outside snapshots, iteration is
#     completely untouched.
#   * CHECKSUM-GATED, per snapshot (no env vars). We compute a sha256 of
#     the actual upstream source (PVE/LXC/Config.pm + PVE/AbstractConfig.pm)
#     at load, not a version string. If it is in the known-good table the
#     version is "tested" and bind-mount CT snapshots are allowed
#     automatically. If NOT (an unvetted version), the wrappers are still
#     installed but snapshot_create REFUSES bind-mount CTs unless the
#     snapshot name or Description contains the word BINDSNAP-UNSUPPORTED -- an
#     explicit "I am testing an unvetted version" opt-in. The pve-container
#     version is a human label in the log, never the decision.
#   * POLICY: uppercase BINDSNAP- opt-in markers, all matched case-sensitively as
#     their own token (a hyphen/underscore/space sets them off; a letter/digit
#     glued to a marker does not). The per-snapshot ones go in the snapshot
#     name or Description (no server-side prompt; works in the GUI dialog and
#     via `pct snapshot --description`):
#       BINDSNAP-FORCE-RUNNING -> snapshot a RUNNING CT (takes the upstream
#         fs-freeze, which can stall on FUSE/CIFS-backed mounts).
#       BINDSNAP-UNSUPPORTED   -> snapshot on a pve-container whose checksum is not
#         yet in the tested set, at your own risk.
#     Both are KEPT in the stored comment so the operator can see what they
#     passed. BINDSNAP-FORCE-RUNNING is also honoured as a STANDING directive in
#     the CT Notes -- the persistent form, so an automated tool (e.g.
#     cv4pve-autosnap) that can't put a keyword in each auto-generated snapshot
#     can still snapshot a RUNNING bind-mount CT. A separate `BINDSNAP-EXCLUDE:`
#     directive (in the CT Notes, or overridden per-snapshot) drops named
#     managed volumes from the snapshot and is frozen into the snapshot for
#     consistent rollback. The vzdump backup path is 100% stock.
#
# WHAT IT DOES NOT DO
#   * Cluster locality: per-node only. A snapshot taken on one node is
#     not deletable/rollback-able on an unpatched node.
#   * Coverage: because we divert PVE::LXC::Config itself, EVERY process
#     that loads it is covered -- GUI, API and all pct invocations.
#
# SEE README.md and the docs/ directory for the design rationale, install
# steps, the checksum-guard procedure, and the zero-risk `zfs snapshot`
# alternative.
# =====================================================================

our $VERSION = '1.1.0';

# Upstream files whose byte-content defines the snapshot surface we wrap.
# foreach_volume_full + snapshot_create/delete/rollback are INHERITED from
# AbstractConfig; has_feature/__snapshot_* live in LXC/Config. We hash BOTH so the
# guard's coverage equals our actual coupling surface. Order is load-bearing: it
# must match the documented manual command in README.
my @GUARDED_FILES = (
    'PVE/LXC/Config.pm',        # %INC key -> /usr/share/perl5/PVE/LXC/Config.pm
    'PVE/AbstractConfig.pm',    # %INC key -> /usr/share/perl5/PVE/AbstractConfig.pm
);

# Known-good table. KEY = combined sha256 of @GUARDED_FILES (see _config_checksum);
# VALUE = the pve-container version that checksum corresponds to. We save BOTH, but
# ONLY THE CHECKSUM (the key) decides activation; the version is a human label only.
# Recompute the manual way (must equal what the overlay logs):
#   printf '%s\n' \
#     "$(sha256sum /usr/share/perl5/PVE/LXC/Config.pm     | awk '{print $1}')" \
#     "$(sha256sum /usr/share/perl5/PVE/AbstractConfig.pm | awk '{print $1}')" \
#   | sha256sum | awk '{print $1}'
# To add a new release: test it (see README), then paste its combined sha256 here.
my %KNOWN_GOOD_CHECKSUMS = (
    '1ebb1a44483bfdabed59f421c88003673a283cd83cd4009407ce39219faa6106' => '6.1.10',
);

# Known-BAD table. KEY = combined sha256 (same as above); VALUE = a short reason. A
# build listed here is HARD-BLOCKED for bind-mount CT snapshots -- the refusal can NOT
# be overridden with BINDSNAP-UNSUPPORTED. Use it for builds reported to mishandle the overlay
# (data loss, broken snapshots). Starts empty; a maintainer adds an entry when a failure
# is reported and confirmed. Checked BEFORE the known-good/BINDSNAP-UNSUPPORTED logic, so a bad
# checksum always loses even if it were somehow also listed as good.
my %KNOWN_BAD_CHECKSUMS = (
    # 'sha256...' => 'pve-container X.Y.Z: snapshot_delete corrupts bind-mount CTs',
);

# --- clone guard (separate surface from the snapshot guard above) ---------
# `pct clone` of a bind-mount CT dies in PVE::API2::LXC::clone_vm (an inline die on a
# non-'volume' mountpoint), a different module and code path than the diverted
# PVE::LXC::Config. We override clone_vm by replacing a COPY of its whole method body
# (see _clone_code) -- so the override MUST be gated by the byte-content of the file we
# copied from. We hash ONLY PVE/API2/LXC.pm: that is the precise load-bearing surface
# (the methods it calls -- Config->set_lock/write_config/parse_volume -- are stable
# named interfaces). If the checksum is not known-good, we leave clone_vm stock (binds
# stay blocked, exactly as upstream -- no regression on an untested build).
# Recompute the manual way (must equal what the overlay logs):
#   sha256sum /usr/share/perl5/PVE/API2/LXC.pm | awk '{print $1}' | sha256sum | awk '{print $1}'
my @CLONE_GUARDED_FILES = (
    'PVE/API2/LXC.pm',          # %INC key -> /usr/share/perl5/PVE/API2/LXC.pm
);

# Known-good / known-bad tables for the CLONE override, same semantics as the snapshot
# tables: KEY = combined sha256 of @CLONE_GUARDED_FILES, VALUE = pve-container version
# (good) or a reason (bad). Only the checksum decides; the version is a human label.
my %KNOWN_GOOD_CLONE_CHECKSUMS = (
    '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198' => '6.1.10',
);

my %KNOWN_BAD_CLONE_CHECKSUMS = (
    # 'sha256...' => 'pve-container X.Y.Z: clone_vm mishandles carried bind mounts',
);

# Project + issues URLs, printed in the messages. SINGLE SOURCE: $PROJECT_URL is the
# base (where the supported list lives and newer overlay releases are published) and the
# issues URL is derived from it. The README refers to these generically rather than
# hardcoding them.
my $PROJECT_URL       = 'https://github.com/bitranox/pve-bindsnap';
my $REPORT_ISSUES_URL = "$PROJECT_URL/issues";
my $COMPAT_URL        = "$PROJECT_URL/blob/main/docs/compatible-versions.md";

my $TAG = 'pve-bindsnap';
our $APPLIED = 0;     # 'our' so install.sh's pre-flight can read it

# Clone-override flags ('our' so install.sh's pre-flight can read them):
#   $CLONE_LOADED  -- apply_clone() ran to completion (the API2/LXC wrapper chain works).
#                     The install pre-flight asserts THIS, so installing on an untested
#                     build does not roll back (clone just stays stock there).
#   $CLONE_APPLIED -- the clone_vm override is actually installed (checksum was known-good).
#                     Reported in the load banner; not required by the pre-flight.
our $CLONE_LOADED  = 0;
our $CLONE_APPLIED = 0;

# Effective per-snapshot exclude set (hashref of mpN keys), localised by
# snapshot_create for the duration of the create call. When defined the filter uses it
# (the create-time effective set, which may be a per-snapshot override); when undef the
# filter reads the directive from the config it is handed -- which for delete/rollback is
# the snapshot's OWN frozen description, so those operations honour exactly what the
# snapshot captured. See _make_filter and snapshot_create.
our $CURRENT_EXCLUDES;

# Status/diagnostic lines go to STDERR (the journal, for the daemons). Errors and
# notices always print -- an admin must see them even from an interactive pct.
sub _log { print STDERR "$TAG: $_[0]\n"; }

# Journal/task-log only: emit to STDERR when it is NOT a terminal, but stay silent on an
# interactive terminal. Used for the per-snapshot/rollback/delete summaries (which we want
# in the GUI/API task log, not spamming an interactive `pct snapshot`). die-based refusals
# and error _log calls are unaffected -- an admin must always see those. (The routine load
# banner uses the stricter _log_banner below, which also requires a PVE daemon.)
sub _log_journal { return if -t STDERR; _log($_[0]); }

# Is THIS process one of the long-running PVE daemons install.sh manages
# (pvedaemon/pveproxy/pvestatd)? Decided from $0 -- the daemon's script path
# (/usr/bin/pvedaemon) or its renamed worker title ("pvedaemon worker") both carry the
# name, bounded so a glued suffix does not match. Only the routine load banner uses this.
# Pure (reads $0); unit-testable by localizing $0.
sub _is_pve_daemon {
    return (($0 // '') =~ m{(?:\A|/)(?:pvedaemon|pveproxy|pvestatd)(?![A-Za-z0-9])}) ? 1 : 0;
}

# The routine "overlay active" load banner prints once per process that loads
# PVE::LXC::Config. Because the install DIVERTS that module, EVERY loader runs us --
# including non-PVE tooling (hookscripts, third-party VM managers like the openvmm helper)
# where the banner is just confusing noise in an unrelated log. Restrict it to a non-TTY
# PVE daemon: an admin greps the daemon journal to confirm the overlay is live, and nothing
# else sees it. The per-snapshot summaries and ALL refusals/warnings are emitted on the
# operation (via _log_journal / _log_block / die) and are deliberately NOT gated here, so
# GUI and CLI snapshots still report fully.
sub _log_banner { return if -t STDERR; return unless _is_pve_daemon(); _log($_[0]); }

# Print a pre-formatted multi-line block to STDERR as-is. A worker's STDERR is redirected
# straight to the task-log file, which PRESERVES newlines -- unlike a die message, which
# PVE's fork_worker flattens to one line (`$err =~ s/\n/ /`). So the full multi-line
# refusal explanation is printed here (visible in the GUI task "Output"), and the gate
# then dies with a short one-line status. Always prints, so an interactive pct sees it too.
sub _log_block { print STDERR $_[0]; }

# Emit a Proxmox task WARNING so the task ends as "TASK WARNINGS: N" -- a yellow line in the
# GUI/CLI task list, a nudge rather than a failure (the snapshot still succeeds).
# PVE::RESTEnvironment::log_warn increments the worker's warning_count when run inside a task
# (RESTEnvironment.pm: the count drives the WARNINGS status) and prints "WARN: ..." to the
# task log either way. Capability-checked + eval-guarded, so off-node and the unit tests (no
# PVE::RESTEnvironment) just fall back to a printed WARN line and are otherwise unaffected.
sub _task_warn {
    my ($msg) = @_;
    my $emitted = eval {
        if (my $fn = PVE::RESTEnvironment->can('log_warn')) { $fn->($msg); 1 }
    };
    print STDERR "WARN: $msg\n" unless $emitted;
}

sub _pkg_version {
    my ($pkg) = @_;
    return eval {
        # pvedaemon/pveproxy/pct run perl -T (taint), where a backtick with a tainted
        # PATH dies before exec. Use a clean %ENV and an absolute dpkg-query so the
        # version resolves there too (otherwise $vlabel shows up as 'unknown').
        local %ENV = (PATH => '/usr/sbin:/usr/bin:/sbin:/bin');
        my $out = `/usr/bin/dpkg-query -W -f='\${Version}' \Q$pkg\E 2>/dev/null`;
        $out =~ /\A\s*(\S+)\s*\z/ ? $1 : undef;
    };
}

# Resolve the on-disk path of the GENUINE upstream module to checksum. From %INC,
# falling back to the standard PVE perl5 dir. But when we are installed via
# dpkg-divert, $INC{'PVE/LXC/Config.pm'} points at our thin WRAPPER, not the real
# code -- the genuine upstream is at <path>.distrib. Prefer a `.distrib` sibling so
# the checksum reflects the real upstream bytes (otherwise the guard would hash the
# tiny wrapper and never match the known-good table => permanent TEST mode).
sub _module_path {
    my ($inc_key) = @_;
    my $p = $INC{$inc_key};
    $p = "/usr/share/perl5/$inc_key" unless defined($p) && length($p);
    return "$p.distrib" if -e "$p.distrib";
    return $p;
}

# sha256 hex of one file via core Digest::SHA (require-guarded so a missing module
# can't abort the -M load). Identical output to `sha256sum <file>`. undef on error.
sub _sha256_file {
    my ($path) = @_;
    return undef unless defined($path) && -r $path;
    return eval {
        require Digest::SHA;
        my $d = Digest::SHA->new(256);
        $d->addfile($path);
        $d->hexdigest;
    };
}

# Combined digest over a list of file PATHS in fixed order (defaults to the
# resolved @GUARDED_FILES). Returns ($combined, \%per): %per maps each path -> its
# per-file hex (or undef). $combined is undef if ANY file could not be hashed
# (fail-safe: one bad file => whole thing unknown). combined =
# sha256_hex(join '', map "$hex\n", @per_file_in_order), which exactly reproduces
# `printf '%s\n' h1 h2 | sha256sum`. Paths are a parameter so this is unit-testable.
sub _config_checksum {
    my @paths = @_ ? @_ : map { _module_path($_) } @GUARDED_FILES;
    my %per;
    my $joined = '';
    my $ok = 1;
    for my $path (@paths) {
        my $h = _sha256_file($path);
        $per{$path} = $h;
        if (!defined $h) { $ok = 0; next; }
        $joined .= "$h\n";
    }
    return (undef, \%per) if !$ok;
    my $combined = eval { require Digest::SHA; Digest::SHA::sha256_hex($joined); };
    return ($combined, \%per);
}

# True if $marker (e.g. BINDSNAP-FORCE-RUNNING, BINDSNAP-UNSUPPORTED) appears as its own token
# in $text. Case-sensitive, and bounded by anything that is NOT a letter or digit -- so
# an underscore, a hyphen or a space counts as a separator: BINDSNAP-UNSUPPORTED,
# BINDSNAP-UNSUPPORTED_2026, "pre BINDSNAP-UNSUPPORTED" all match, but letter/digit gluing
# ("xBINDSNAP-UNSUPPORTEDy") does NOT, and neither does the wrong case. The underscore is
# allowed deliberately so an auto-generated name like "BINDSNAP-FORCE-RUNNING_2026..." opts
# in cleanly. Used for the per-snapshot keywords AND for the standing BINDSNAP-FORCE-RUNNING
# directive in the CT Notes -- one mechanism, so the same token works in both places.
sub _has_marker {
    my ($text, $marker) = @_;
    return defined($text) && $text =~ /(?<![A-Za-z0-9])\Q$marker\E(?![A-Za-z0-9])/;
}

# Parse a "exclude these managed volumes from the snapshot" directive out of a
# description -- the CT's Notes, or a snapshot's own comment. It is its own line: the
# keyword is uppercase and case-sensitive (consistent with the other BINDSNAP- markers),
# optionally written as a markdown heading so it renders small in the GUI, then a `:`
# (or `=`) and the mountpoint list to end of line:
#     #### BINDSNAP-EXCLUDE: mp1 mp2
# Unlike the two boolean keywords, BINDSNAP-EXCLUDE is NOT underscore-glue-tolerant: it is
# always `BINDSNAP-EXCLUDE:` + (empty | list), never glued into an auto-generated name, so a
# trailing `BINDSNAP-EXCLUDE_` is simply not a directive. The leading `#{0,6}` is the optional
# markdown heading; a bare `BINDSNAP-EXCLUDE:` (no heading) is equally valid.
# Returns:
#   undef             -- NO directive present at all
#   { mpN => 1, ... } -- the named managed-volume mountpoints to drop (only mpN keys
#                        honoured; rootfs and unknown/device tokens are ignored)
#   {}                -- a directive IS present but names nothing valid
# The undef-vs-{} distinction is load-bearing: a directive in a snapshot's own
# description OVERRIDES the CT default, and an empty one ("BINDSNAP-EXCLUDE:") means "exclude
# nothing for this snapshot". Pure, so it's unit-testable off-node.
sub _snap_excludes {
    my ($text) = @_;
    return undef
        unless defined($text) && $text =~ /^\s*#{0,6}\s*BINDSNAP-EXCLUDE\s*[:=]\s*(.*)$/m;
    my %ex;
    for my $k (split /[\s,]+/, $1) {
        $ex{$k} = 1 if $k =~ /\Amp\d+\z/;    # mpN volume keys only; rootfs never excluded
    }
    return \%ex;
}

# True if this conf has a mountpoint the overlay would hide -- a non-'volume'
# (bind/device) mountpoint. Iterate with the LIVE upstream foreach_volume_full
# (undef opts == foreach_volume), so we see the bind mounts the filter drops. The
# predicate matches the filter exactly. Pure, so it's unit-testable off-node.
sub _conf_needs_overlay {
    my ($class, $conf, $orig_fvf) = @_;
    my $found = 0;
    eval {
        $orig_fvf->($class, $conf, undef, sub {
            my (undef, $v) = @_;
            $found = 1 if defined($v) && (($v->{type} // '') ne 'volume');
        });
        1;
    };
    return $found;
}

# Sort a CT's (or a snapshot's) mountpoints into three buckets via the live iterator:
# managed volumes kept, managed volumes the operator excluded (BINDSNAP-EXCLUDE), and
# bind/device mounts skipped. Shared by both task-log summaries so the rule lives in one
# place. Pure (the guarded iteration is the only effect); unit-testable with a stub.
sub _categorize_volumes {
    my ($class, $conf, $orig_fvf, $excl) = @_;
    my (@kept, @excluded, @skipped);
    eval {
        $orig_fvf->($class, $conf, undef, sub {
            my ($key, $v) = @_;
            return unless defined $v;
            if    (($v->{type} // '') ne 'volume') { push @skipped,  $key; }
            elsif ($excl->{$key})                  { push @excluded, $key; }
            else                                   { push @kept,     $key; }
        });
        1;
    };
    return (\@kept, \@excluded, \@skipped);
}

# Word-wrap a "  LABEL: value" line for the task Output. The viewer doesn't wrap, so a long
# value is one unreadable line; this fills the value to ~$width columns with continuation
# lines indented under it, keeping every word (nothing is dropped). $key is the full prefix
# (indent + label + ": "). Pure.
sub _wrap_kv {
    my ($key, $value, $width) = @_;
    $width ||= 78;
    my $indent = ' ' x length($key);
    my @out;
    my $line = $key;
    for my $word (split ' ', $value) {
        if ($line eq $key) {
            $line .= $word;                                       # $key ends with a space
        } elsif (length($line) + 1 + length($word) > $width) {
            push @out, $line;
            $line = $indent . $word;
        } else {
            $line .= ' ' . $word;
        }
    }
    push @out, $line;
    return join("\n", @out);
}

# The BINDSNAP-FORCE-RUNNING status line for the summary (full text, wrapped for the viewer).
# Priority order: n/a for a normal CT; stopped; standing Notes directive; per-snapshot keyword.
# Pure; same named context as _snapshot_summary.
sub _force_line {
    my (%c) = @_;
    my $k = "  BINDSNAP-FORCE-RUNNING: ";
    return _wrap_kv($k, "n/a -- only bind-mount CTs are gated; a normal CT snapshots whether running or stopped")
        unless $c{is_bind};
    return _wrap_kv($k, "not used -- CT was stopped. BINDSNAP-FORCE-RUNNING (in the snapshot name/description, or standing in the CT Notes) lets you snapshot a RUNNING CT; its filesystem is briefly frozen, which can stall on FUSE/CIFS mounts")
        unless $c{running};
    return _wrap_kv($k, "standing -- the CT is running and a standing BINDSNAP-FORCE-RUNNING directive in its Notes allowed it, so its filesystem was briefly frozen (no per-snapshot keyword needed; this is the opt-in for automated snapshot tools)")
        if $c{force_standing};
    return _wrap_kv($k, "used -- the CT is running, so its filesystem was briefly frozen for a consistent snapshot");
}

# The BINDSNAP-UNSUPPORTED status line (full text, wrapped). Priority order: n/a for a normal
# CT; untested build via a STANDING directive (risky); untested per-snapshot; dormant standing
# directive on a tested build; tested with no directive. Pure; same context as above.
sub _unsupported_line {
    my (%c) = @_;
    my $k = "  BINDSNAP-UNSUPPORTED  : ";
    return _wrap_kv($k, "n/a -- a normal CT snapshots on any build, tested or not")
        unless $c{is_bind};
    return _wrap_kv($k, "STANDING (risky) -- snapshotting on an UNTESTED build, allowed by a standing BINDSNAP-UNSUPPORTED in the CT Notes. A standing opt-in also covers FUTURE untested builds: after a PVE update, snapshots would proceed on the new build silently instead of being re-gated, and could misbehave or fail quietly. Prefer a per-snapshot BINDSNAP-UNSUPPORTED, or drop the directive once on a tested build. Please report the version+checksum (works or not).")
        if !$c{checksum_known} && $c{unsupported_standing};
    return _wrap_kv($k, "used -- snapshotting on an UNTESTED pve-container build at your own risk; please report the version and checksum (whether it works or not) so the tested set can grow.")
        if !$c{checksum_known} && $c{unsupported};
    return _wrap_kv($k, "not needed now -- this build is tested, but a standing BINDSNAP-UNSUPPORTED sits in the CT Notes; it would silently allow a FUTURE untested build after a PVE update, so consider removing it.")
        if $c{unsupported_standing};
    return _wrap_kv($k, "not needed -- this build is tested. BINDSNAP-UNSUPPORTED lets you snapshot a bind-mount CT on an untested build at your own risk.");
}

# Verbose multi-line summary of what the overlay did, for the task log only (never an
# interactive pct). Runs for EVERY snapshot -- including normal CTs the overlay leaves
# stock -- so each snapshot task shows the overlay reporting in, with the checksum and the
# BINDSNAP-FORCE-RUNNING/BINDSNAP-UNSUPPORTED status (each briefly explained). Takes named params
# so it's unit-testable with a stub iterator; the iteration is the only effect and guarded.
#   class conf fvf vmid : iterate this CT's mountpoints
#   excl                : the effective BINDSNAP-EXCLUDE set (hashref)
#   checksum_known      : is this build in the tested set
#   vlabel              : pve-container version label
#   is_bind             : does the CT have bind/device mounts (did the overlay engage)
#   running             : is the CT running
#   force / unsupported : was each marker present (from either the snapshot or the Notes)
#   force_standing / unsupported_standing : was it present as a STANDING directive in the
#                         CT Notes (vs only per-snapshot). For BINDSNAP-UNSUPPORTED, standing is
#                         flagged as risky -- it silently covers a future untested build.
sub _snapshot_summary {
    my (%c) = @_;
    my ($kept, $excluded, $skipped) = _categorize_volumes($c{class}, $c{conf}, $c{fvf}, $c{excl});
    my $vlabel = $c{vlabel} // 'unknown';

    my @lines;
    push @lines, $c{is_bind}
        ? "snapshot of CT $c{vmid} (bind-mount container)"
        : "snapshot of CT $c{vmid} (no bind/device mounts -- stock snapshot, overlay made no change)";

    my $vols = "kept " . (join(', ', @$kept) || 'nothing');
    $vols .= "; excluded " . join(', ', @$excluded) . " (BINDSNAP-EXCLUDE)" if @$excluded;
    $vols .= "; skipped "  . join(', ', @$skipped)  . " (bind/device)" if @$skipped;
    push @lines, _wrap_kv("  volumes               : ", $vols);

    my $cks = defined($c{bad})   ? "known-BAD -- pve-container $vlabel is on the known-bad list ($c{bad}); bind-mount CT snapshots are blocked"
            : $c{checksum_known} ? "validated -- pve-container $vlabel is in the tested set"
            :                      "TEST mode -- pve-container $vlabel is NOT in the tested set";
    push @lines, _wrap_kv("  checksum              : ", $cks);

    push @lines, _force_line(%c);
    push @lines, _unsupported_line(%c);

    return join("\n", @lines);
}

# Task-log summary for a rollback or delete. Categorises the SNAPSHOT's mountpoints
# (so it must be handed the snapshot's stored config section) into the managed volumes
# acted on, the ones left as-is (excluded when the snapshot was taken), and the
# bind/device mounts that were never part of it. $op is the noun ('rollback'/'delete'),
# $did the past-tense verb ('reverted'/'removed'). Pure; unit-testable with a stub.
sub _op_summary {
    my (%c) = @_;
    my ($acted, $left, $skipped) = _categorize_volumes($c{class}, $c{conf}, $c{fvf}, $c{excl});
    my $msg = "$c{op} of CT $c{vmid} snapshot '$c{snapname}': "
            . "$c{did} " . (join(', ', @$acted) || 'nothing');
    $msg .= "; left " . join(', ', @$left) . " as-is (excluded from this snapshot)" if @$left;
    $msg .= "; bind/device " . join(', ', @$skipped) . " untouched" if @$skipped;
    return $msg;
}

# Glue: load the snapshot's stored config, read its frozen exclude set, and log the
# rollback/delete summary to the task log. Thin (loads config), so not unit-tested; the
# formatting it delegates to _op_summary is.
sub _log_op_summary {
    my ($class, $vmid, $snapname, $orig_fvf, $op, $did) = @_;
    return unless defined $snapname;
    my $conf = eval { $class->load_config($vmid) };
    my $snap = $conf ? $conf->{snapshots}{$snapname} : undef;
    return unless $snap;
    _log_journal(_op_summary(
        op => $op, did => $did, class => $class, vmid => $vmid, snapname => $snapname,
        conf => $snap, fvf => $orig_fvf, excl => (_snap_excludes($snap->{description}) // {}),
    ));
}

# Indented "pve-container <ver>  <checksum>" lines for every known-good build, for the
# multi-line refusal explanations (printed to the task log, which preserves newlines).
# Pure, unit-testable.
sub _known_good_list {
    my @l = map { "    pve-container $KNOWN_GOOD_CHECKSUMS{$_}  $_" }
        sort { $KNOWN_GOOD_CHECKSUMS{$a} cmp $KNOWN_GOOD_CHECKSUMS{$b} } keys %KNOWN_GOOD_CHECKSUMS;
    return @l ? join("\n", @l) : "    (none recorded)";
}

# --- load-time status line ------------------------------------------------
sub _load_message {
    my ($known, $sum, $vlabel, $per, $bad_reason) = @_;
    my $combined = $sum // 'unavailable';

    return "overlay active but BLOCKED: pve-container $vlabel is on the known-BAD list "
         . "($bad_reason; combined sha256 $combined). Snapshots of bind-mount CTs are "
         . "REFUSED and BINDSNAP-UNSUPPORTED will NOT override this. CTs without bind/device "
         . "mounts snapshot normally."
        if defined $bad_reason;

    return "overlay active (pve-container $vlabel, checksum-validated; "
         . "combined sha256 $combined; running CT => stop or BINDSNAP-FORCE-RUNNING)"
        if $known;

    # TEST mode also lists the per-file hashes, so an upgrade that changes only
    # one of the two guarded files is easy to spot.
    my @parts = ("combined sha256 $combined");
    for my $key (@GUARDED_FILES) {
        (my $name = $key) =~ s{.*/}{};                 # Config.pm / AbstractConfig.pm
        push @parts, "$name " . (($per && $per->{_module_path($key)}) // '?');
    }
    my $detail = join('; ', @parts);

    return "overlay active in TEST mode: pve-container $vlabel is untested "
         . "($detail). CTs without bind/device mounts snapshot normally; bind-mount CT "
         . "snapshots are REFUSED unless the snapshot name or Description contains "
         . "BINDSNAP-UNSUPPORTED. Update pve-container to a tested build, or report this "
         . "version+checksum (works or not) at $REPORT_ISSUES_URL. "
         . "running CT => stop or BINDSNAP-FORCE-RUNNING";
}

# --- snapshot_create refusal messages (pure; built here so they're unit-testable and
#     don't bloat the gate logic). $good is _known_good_list() output. ----------------
sub _msg_blocked {
    my ($vlabel, $sha, $reason, $good) = @_;
    return "$TAG: pve-container $vlabel is on the overlay's known-BAD list -- this build\n"
         . "mishandles bind-mount snapshots, so they are BLOCKED and BINDSNAP-UNSUPPORTED will\n"
         . "NOT override it.\n"
         . "\n"
         . "    version : pve-container $vlabel\n"
         . "    checksum: $sha\n"
         . "    reason  : $reason\n"
         . "\n"
         . "Update pve-container to a tested-good build (full list: $COMPAT_URL):\n"
         . "$good\n"
         . "\n"
         . "Or snapshot the stopped CT with `zfs snapshot` directly. Report: $REPORT_ISSUES_URL\n";
}

sub _msg_untested {
    my ($vlabel, $sha, $good) = @_;
    return "$TAG: pve-container $vlabel is not in the overlay's tested set, so snapshots\n"
         . "of bind-mount containers are gated on it.\n"
         . "\n"
         . "    version : pve-container $vlabel\n"
         . "    checksum: $sha\n"
         . "\n"
         . "This overlay's tested-good builds:\n"
         . "$good\n"
         . "\n"
         . "A newer overlay release may already cover your build -- full supported list:\n"
         . "    $COMPAT_URL\n"
         . "\n"
         . "Otherwise update pve-container to one of the tested builds above, or to snapshot\n"
         . "on THIS build at your own risk add the word BINDSNAP-UNSUPPORTED to the snapshot name\n"
         . "or description -- then please report the result (works or not) at:\n"
         . "    $REPORT_ISSUES_URL\n";
}

sub _msg_running {
    my ($vmid) = @_;
    return "$TAG: CT $vmid is running.\n"
         . "\n"
         . "Stop it for a clean, application-consistent snapshot, or add the word\n"
         . "BINDSNAP-FORCE-RUNNING to the snapshot name or description to snapshot it while\n"
         . "running -- its filesystem is briefly frozen, which can stall on FUSE/CIFS mounts.\n"
         . "\n"
         . "For an automated snapshot tool that cannot set it on each snapshot (e.g.\n"
         . "cv4pve-autosnap), add a standing directive line to the CT's Notes instead:\n"
         . "    #### BINDSNAP-FORCE-RUNNING\n"
         . "That opts this CT into running snapshots without a per-snapshot keyword.\n";
}

# Build a filtered foreach_volume_full that skips non-'volume' mountpoints (bind/dev)
# AND any managed volume the operator excluded via a BINDSNAP-EXCLUDE directive. $orig is
# the LIVE upstream coderef. The exclude set is $CURRENT_EXCLUDES when set (during
# snapshot_create, where the effective set may be a per-snapshot override and $conf is
# the live CT config); otherwise it is read from the config being iterated -- which for
# delete/rollback is the snapshot's own frozen description.
sub _make_filter {
    my ($orig) = @_;
    return sub {
        my ($class, $conf, $opts, $func, @param) = @_;
        my $excl = defined($CURRENT_EXCLUDES)
            ? $CURRENT_EXCLUDES
            : (_snap_excludes($conf->{description}) // {});
        return $orig->(
            $class, $conf, $opts,
            sub {
                my ($key, $volume, @rest) = @_;
                return if !defined($volume) || (($volume->{type} // '') ne 'volume');
                return if $excl->{$key};    # operator-excluded managed volume
                return $func->($key, $volume, @rest);
            },
            @param,
        );
    };
}

sub _apply {
    return if $APPLIED;

    # --- load the genuine, undiverted upstream module -----------------
    eval { require PVE::LXC::Config; 1 } or do {
        _log("PVE::LXC::Config not loadable ($@); overlay inert");
        return;
    };

    # --- checksum status (NOT a load gate) ----------------------------
    # We always install the wrappers below. The checksum only decides whether
    # bind-mount CT snapshots are allowed automatically, or only with an explicit
    # BINDSNAP-UNSUPPORTED opt-in in the snapshot name/Description (handled in snapshot_create).
    # The pve-container version is a human label only -- never the decision.
    my ($sum, $per) = _config_checksum();
    my $vlabel = _pkg_version('pve-container') // 'unknown';
    my $checksum_known = defined($sum) && exists $KNOWN_GOOD_CHECKSUMS{$sum};
    # Known-BAD wins over everything: a hard block that BINDSNAP-UNSUPPORTED cannot override.
    my $bad_reason = (defined($sum) && exists $KNOWN_BAD_CHECKSUMS{$sum})
        ? $KNOWN_BAD_CHECKSUMS{$sum} : undef;

    # --- capture LIVE upstream implementations ------------------------
    my $orig_fvf      = PVE::LXC::Config->can('foreach_volume_full');
    my $orig_feature  = PVE::LXC::Config->can('has_feature');
    my $orig_create   = PVE::LXC::Config->can('snapshot_create');
    my $orig_delete   = PVE::LXC::Config->can('snapshot_delete');
    my $orig_rollback = PVE::LXC::Config->can('snapshot_rollback');

    unless ($orig_fvf && $orig_feature && $orig_create && $orig_delete && $orig_rollback) {
        _log("one or more expected methods missing; overlay DISABLED (stock behaviour)");
        return;
    }

    my $filter = _make_filter($orig_fvf);

    # 'redefine': we intentionally replace upstream subs. 'once': each fully
    # qualified PVE::LXC::Config::* glob below is named just once in a standalone
    # compile, which perl -c would otherwise flag as a possible typo.
    no warnings 'redefine', 'once';

    # has_feature: only touch the user-facing 'snapshot' query. Backup
    # (vzdump) decisions and every other feature delegate to live upstream
    # untouched, and so does any CT without bind/device mounts -- its snapshot
    # feature is exactly whatever stock says. We do NOT gate on $running here --
    # the button stays available while running so the user can reach the create
    # path and see the stop-or-BINDSNAP-FORCE-RUNNING message (the running decision is made in
    # snapshot_create, below).
    *PVE::LXC::Config::has_feature = sub {
        my ($class, $feature, $conf, $storecfg, $snapname, $running, $backup_only) = @_;
        return $orig_feature->(@_) if !defined($feature) || $feature ne 'snapshot';
        return $orig_feature->(@_) if $backup_only;     # leave vzdump's check alone
        return $orig_feature->(@_) if !_conf_needs_overlay($class, $conf, $orig_fvf);
        local *PVE::LXC::Config::foreach_volume_full = $filter;
        return $orig_feature->(@_);
    };

    # snapshot_create: the gates (BINDSNAP-UNSUPPORTED/BINDSNAP-FORCE-RUNNING) and the bind/volume
    # filter apply ONLY to bind-mount CTs; a normal CT runs 100% stock on any version.
    # Either way we log a verbose summary to the task log (see _snapshot_summary) so every
    # snapshot task shows the overlay reporting in. For a bind-mount CT, two opt-in markers
    # -- each read BOTH from the snapshot NAME/Description (per snapshot) AND from the CT
    # Notes (a standing directive), case-sensitive uppercase:
    #   * BINDSNAP-UNSUPPORTED   -- required when this pve-container's checksum is not in the
    #     tested set (you accept you are testing an unvetted version).
    #   * BINDSNAP-FORCE-RUNNING -- required when the CT is running (upstream fs-freeze, which
    #     can stall on FUSE/CIFS mounts).
    # Reading both markers from the CT Notes too is what lets an automated tool (e.g.
    # cv4pve-autosnap) -- which can't put a keyword in each auto-generated snapshot --
    # opt a CT in once and have its scheduled snapshots go through. Per-snapshot markers
    # are LEFT in the stored snapshot comment (not stripped) so the operator can see what
    # they passed. The BINDSNAP-EXCLUDE directive drops named managed volumes and is frozen
    # into the snapshot for consistent rollback (see _snap_excludes).
    *PVE::LXC::Config::snapshot_create = sub {
        my ($class, $vmid, $snapname, $save_vmstate, $comment) = @_;
        return $orig_create->(@_) if defined($snapname) && $snapname eq 'vzdump';

        # Load the config once -- reused for the engagement check, the BINDSNAP-EXCLUDE
        # directive, and the summary. Fail-safe: if it can't be read, assume the CT
        # might need us (never silently send a bind CT to stock).
        my $conf    = eval { $class->load_config($vmid) };
        my $is_bind = defined($conf) ? _conf_needs_overlay($class, $conf, $orig_fvf) : 1;
        my $markers = join(' ', grep { defined && length } ($snapname, $comment));
        my $notes   = defined($conf) ? $conf->{description} : undef;
        my $running = $class->__snapshot_check_running($vmid) ? 1 : 0;

        # Each marker is read BOTH from the snapshot name/Description (a per-snapshot
        # decision) AND from the CT Notes (a STANDING directive). The standing form is
        # what lets an automated tool (e.g. cv4pve-autosnap) -- which can't put a keyword
        # in each auto-generated snapshot -- opt a CT in once.
        #   BINDSNAP-FORCE-RUNNING : allow a running-CT snapshot (the fs-freeze). The CT's
        #     mount makeup decides whether that's safe, so a standing opt-in is low risk.
        #   BINDSNAP-UNSUPPORTED   : accept an untested pve-container build. A STANDING one is
        #     riskier: if it is left in the Notes and PVE is later updated to a new,
        #     untested build, the overlay would silently snapshot on it instead of
        #     refusing -- the snapshot could misbehave or fail quietly. The summary flags
        #     this (see _snapshot_summary); a per-snapshot BINDSNAP-UNSUPPORTED is a fresh
        #     decision each time and carries no such carry-over risk.
        my $force_kw    = _has_marker($markers, 'BINDSNAP-FORCE-RUNNING') ? 1 : 0;
        my $force_note  = _has_marker($notes,   'BINDSNAP-FORCE-RUNNING') ? 1 : 0;
        my $force       = $force_kw || $force_note;
        my $unsupp_kw   = _has_marker($markers, 'BINDSNAP-UNSUPPORTED') ? 1 : 0;
        my $unsupp_note = _has_marker($notes,   'BINDSNAP-UNSUPPORTED') ? 1 : 0;
        my $unsupp      = $unsupp_kw || $unsupp_note;

        my $excl = {};
        if ($is_bind) {
            my $sha  = $sum // 'unavailable';
            my $good = _known_good_list();

            # Gates apply to bind-mount CTs only. Order is load-bearing: a known-BAD build
            # is a HARD block (BINDSNAP-UNSUPPORTED cannot override), so it is checked first.
            # The full multi-line explanation goes to the task log (preserves newlines via
            # _log_block); the die carries a short one-line status, which PVE flattens.
            if (defined $bad_reason) {
                _log_block(_msg_blocked($vlabel, $sha, $bad_reason, $good));
                die "$TAG: snapshot BLOCKED -- pve-container $vlabel is on the overlay's "
                  . "known-bad list; BINDSNAP-UNSUPPORTED cannot override (details in the task log)\n";
            }
            if (!$checksum_known && !$unsupp) {
                _log_block(_msg_untested($vlabel, $sha, $good));
                die "$TAG: snapshot gated -- pve-container $vlabel is untested; add "
                  . "BINDSNAP-UNSUPPORTED or update pve-container (details in the task log)\n";
            }
            if ($running && !$force) {
                _log_block(_msg_running($vmid));
                die "$TAG: CT $vmid is running -- stop it, or add BINDSNAP-FORCE-RUNNING to "
                  . "snapshot it running (details in the task log)\n";
            }

            # Nudge via a yellow "TASK WARNINGS" (not a failure -- the snapshot still goes
            # ahead). If this is going onto an UNTESTED build (only possible here because
            # BINDSNAP-UNSUPPORTED is in play), ask the operator to report the build so it can
            # join the known-good list. If instead a standing BINDSNAP-UNSUPPORTED is lingering
            # on a tested build, nudge them to remove it (it would silently cover a future
            # untested build after a PVE update).
            # Messages are wrapped into short lines (the task viewer doesn't wrap), with the
            # long checksum on its own line so the prose stays readable.
            if (!$checksum_known && $unsupp_note) {
                _task_warn("$TAG: snapshot taken on an UNTESTED pve-container build via a standing\n"
                         . "  BINDSNAP-UNSUPPORTED in CT ${vmid}'s Notes, which also silently covers future\n"
                         . "  untested builds. If it works, report it so this build joins the known-good\n"
                         . "  list (then drop the directive):\n"
                         . "    pve-container $vlabel, combined sha256 $sha\n"
                         . "    $REPORT_ISSUES_URL");
            } elsif (!$checksum_known) {
                _task_warn("$TAG: snapshot taken on an UNTESTED pve-container build. If it works,\n"
                         . "  please report it so this build can be added to the known-good list\n"
                         . "  (then no keyword is needed):\n"
                         . "    pve-container $vlabel, combined sha256 $sha\n"
                         . "    $REPORT_ISSUES_URL");
            } elsif ($unsupp_note) {
                _task_warn("$TAG: CT $vmid has a standing BINDSNAP-UNSUPPORTED in its Notes on a tested\n"
                         . "  build. It would silently cover a future untested build after a PVE update.\n"
                         . "  Remove the directive unless you need it.");
            }

            # Resolve which managed volumes to exclude from THIS snapshot. A BINDSNAP-EXCLUDE
            # directive in the snapshot's own description overrides the CT default outright
            # (empty => exclude nothing); absent one, the CT's directive applies and we
            # FREEZE it into the snapshot comment so delete/rollback honour the same set
            # even if the CT config changes later.
            $excl = _snap_excludes($comment);    # snapshot-level override (undef if none)
            if (!defined $excl) {
                $excl = (defined($conf) ? _snap_excludes($conf->{description}) : undef) // {};
                if (%$excl) {
                    my $dir = '#### BINDSNAP-EXCLUDE: ' . join(' ', sort keys %$excl);
                    $comment = (defined($comment) && length($comment)) ? "$comment\n$dir" : $dir;
                }
            }
            @_ = ($class, $vmid, $snapname, $save_vmstate, $comment);
        }

        # Verbose summary to the task log for EVERY snapshot (silent on an interactive
        # pct via -t STDERR). A normal CT gets a line too, confirming the overlay is
        # active and made no change.
        _log_journal(_snapshot_summary(
            class => $class, conf => $conf, fvf => $orig_fvf, vmid => $vmid,
            excl => $excl, checksum_known => $checksum_known, vlabel => $vlabel,
            is_bind => $is_bind, running => $running,
            force => $force, force_standing => $force_note,
            unsupported => $unsupp, unsupported_standing => $unsupp_note,
            bad => $bad_reason,
        )) if defined $conf;

        # Normal CT: run stock, untouched. Bind CT: install the filter for the call.
        return $orig_create->(@_) if !$is_bind;
        local $CURRENT_EXCLUDES = $excl;
        local *PVE::LXC::Config::foreach_volume_full = $filter;
        return $orig_create->(@_);
    };

    # snapshot_delete: hide binds so volume_snapshot_delete is never
    # called on a bind path. vzdump path stays stock. (The internal
    # cleanup call from a failed snapshot_create uses the USER snapname,
    # so it routes through here and gets the filter too.)
    *PVE::LXC::Config::snapshot_delete = sub {
        my ($class, $vmid, $snapname, $force_del, $drivehash) = @_;
        return $orig_delete->(@_) if defined($snapname) && $snapname eq 'vzdump';
        _log_op_summary($class, $vmid, $snapname, $orig_fvf, 'delete', 'removed');
        local *PVE::LXC::Config::foreach_volume_full = $filter;
        return $orig_delete->(@_);
    };

    # snapshot_rollback: hide binds; upstream stops the CT itself.
    *PVE::LXC::Config::snapshot_rollback = sub {
        my ($class, $vmid, $snapname) = @_;
        _log_op_summary($class, $vmid, $snapname, $orig_fvf, 'rollback', 'reverted');
        local *PVE::LXC::Config::foreach_volume_full = $filter;
        return $orig_rollback->(@_);
    };

    $APPLIED = 1;
    _log_banner(_load_message($checksum_known, $sum, $vlabel, $per, $bad_reason));
}

# =====================================================================
# clone support: override PVE::API2::LXC::clone_vm
# ---------------------------------------------------------------------
# clone_vm is registered as an anonymous register_method CLOSURE -- there is NO named
# PVE::API2::LXC::clone_vm sub to typeglob-redefine, and re-registering dies on a
# duplicate name/path. The supported override is to mutate the LIVE method definition
# in place: PVE::API2::LXC->map_method_by_name('clone_vm') returns the shared $info
# hashref used by every dispatch path (GUI/API and pct CLI), so replacing $info->{code}
# overrides the dispatched code everywhere. We install a COPY of upstream's clone_vm body
# with a single change (bind/device mountpoints carried-or-excluded instead of die), so
# the whole thing is gated by the @CLONE_GUARDED_FILES checksum.
# =====================================================================

# Pure decision helper, factored out of _clone_code so the carry/exclude rule is
# unit-testable off-node (the full closure needs the live PVE stack). Given a config
# option, its parsed mountpoint type, and the effective BINDSNAP-EXCLUDE set, classify
# what clone_vm does with it:
#   'clone-volume' -- a managed (type 'volume') rootfs/mpN: stock clone of the volume
#   'exclude'      -- a bind/device mpN named in BINDSNAP-EXCLUDE: dropped from the clone
#   'carry'        -- any other bind/device rootfs/mpN: carried to the clone unchanged
#   'copy-other'   -- not a mountpoint (netN, hostname, ...): upstream copies it as-is
# rootfs is never in the exclude set (_snap_excludes only yields mpN keys), so a rootfs
# can only ever be 'clone-volume' or 'carry'.
sub _clone_disposition {
    my ($opt, $type, $excl) = @_;
    $excl //= {};
    if (($opt eq 'rootfs') || ($opt =~ m/^mp\d+$/)) {
        return 'clone-volume' if defined($type) && $type eq 'volume';
        return 'exclude' if $excl->{$opt};
        return 'carry';
    }
    return 'copy-other';
}

# Task-log summary for a clone, parity with _snapshot_summary: a multi-line block printed
# into the 'vzclone' worker's task log (newlines preserved). Reports the managed volumes
# cloned, the bind/device mounts carried (same host path), and the ones BINDSNAP-EXCLUDE
# dropped. Pure; unit-testable.
sub _clone_summary {
    my (%c) = @_;
    my $vlabel   = $c{vlabel} // 'unknown';
    my @cloned   = @{ $c{cloned}   // [] };
    my @carried  = @{ $c{carried}  // [] };
    my @excluded = @{ $c{excluded} // [] };
    my $is_bind  = (@carried || @excluded) ? 1 : 0;

    my @lines;
    push @lines, $is_bind
        ? "clone of CT $c{vmid} -> $c{newid} (bind-mount container)"
        : "clone of CT $c{vmid} -> $c{newid} (no bind/device mounts -- stock clone, overlay made no change)";

    my $vols = "cloned " . (join(', ', @cloned) || 'nothing');
    $vols .= "; carried " . join(', ', @carried) . " (bind/device, same host path as source)" if @carried;
    $vols .= "; excluded " . join(', ', @excluded) . " (BINDSNAP-EXCLUDE)" if @excluded;
    push @lines, _wrap_kv("  volumes               : ", $vols);
    push @lines, _wrap_kv("  checksum              : ", "validated -- pve-container $vlabel is in the clone tested set");

    return join("\n", @lines) . "\n";
}

# The carried-bind warning (parity with the snapshot _task_warn nudges). Carrying a bind/
# device mount to a clone references the SAME host path as the source -- it is NOT copied,
# so both CTs now share that data. Worth a yellow TASK WARNING so the operator notices (the
# real 53000->53001 case: a cloned webserver must not inherit the data mount). Returns ''
# when nothing was carried. Pure; unit-testable.
sub _clone_carry_warning {
    my ($carried) = @_;
    my @c = @{ $carried // [] };
    return '' unless @c;
    return "$TAG: clone carried bind/device mount(s) " . join(', ', @c) . " to the new CT.\n"
         . "  They point at the SAME host path(s) as the source, NOT a copy -- both CTs now\n"
         . "  share that data. To drop a data mount from clones, add a standing directive to\n"
         . "  the SOURCE CT's Notes:\n"
         . "    #### BINDSNAP-EXCLUDE: " . join(' ', @c) . "\n";
}

# Return a coderef to install as clone_vm's {code}. This is a copy of upstream's clone_vm
# body (pve-container 6.1.10, PVE/API2/LXC.pm) with three marked "pve-bindsnap" changes:
#   1. compute the effective BINDSNAP-EXCLUDE set from the source/snapshot description, and
#      collect the carried/excluded bind mounts for the task-log summary.
#   2. the non-'volume' branch carries the entry to the new CT (or drops it if excluded)
#      instead of `die "unable to clone mountpoint ..."`.
#   3. the 'vzclone' worker prints a task-log summary and warns when binds were carried.
# Imported-sub calls from the original (only extract_param) are fully qualified here, since
# this body runs in package PVE::LXC::BindSnap which does not import them. Because it is a
# whole-method copy it is only installed on a checksum-validated build (see apply_clone);
# $vlabel is the pve-container version label, baked in for the summary.
sub _clone_code {
    my ($vlabel) = @_;
    return sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $node = PVE::Tools::extract_param($param, 'node');
        my $vmid = PVE::Tools::extract_param($param, 'vmid');
        my $newid = PVE::Tools::extract_param($param, 'newid');
        my $pool = PVE::Tools::extract_param($param, 'pool');
        if (defined($pool)) {
            $rpcenv->check_pool_exist($pool);
        }
        my $snapname = PVE::Tools::extract_param($param, 'snapname');
        my $storage = PVE::Tools::extract_param($param, 'storage');
        my $target = PVE::Tools::extract_param($param, 'target');
        my $localnode = PVE::INotify::nodename();

        undef $target if $target && ($target eq $localnode || $target eq 'localhost');

        PVE::Cluster::check_node_exists($target) if $target;

        my $storecfg = PVE::Storage::config();

        if ($storage) {
            # check if storage is enabled on local node
            PVE::Storage::storage_check_enabled($storecfg, $storage);
            if ($target) {
                # check if storage is available on target node
                PVE::Storage::storage_check_enabled($storecfg, $storage, $target);
                # clone only works if target storage is shared
                my $scfg = PVE::Storage::storage_config($storecfg, $storage);
                die "can't clone to non-shared storage '$storage'\n" if !$scfg->{shared};
            }
        }

        PVE::Cluster::check_cfs_quorum();

        my $newconf = {};
        my $mountpoints = {};
        my $fullclone = {};
        my $vollist = [];
        my $running;
        # pve-bindsnap: bind/device mounts carried/excluded, collected in the loop below and
        # reported by $realcmd; declared in the outer scope so the worker closure sees them.
        my (@clone_carried, @clone_excluded);

        my $lock_and_reload = sub {
            my ($vmid, $code) = @_;
            return PVE::LXC::Config->lock_config(
                $vmid,
                sub {
                    my $conf = PVE::LXC::Config->load_config($vmid);
                    die "Lost 'create' config lock, aborting.\n"
                        if !PVE::LXC::Config->has_lock($conf, 'create');

                    return $code->($conf);
                },
            );
        };

        my $src_conf = PVE::LXC::Config->set_lock($vmid, 'disk');

        eval { PVE::LXC::Config->create_and_lock_config($newid, 0); };
        if (my $err = $@) {
            eval { PVE::LXC::Config->remove_lock($vmid, 'disk') };
            warn "Failed to remove source CT config lock - $@\n" if $@;

            die $err;
        }

        eval {
            $running = PVE::LXC::check_running($vmid) || 0;

            my $full = PVE::Tools::extract_param($param, 'full');
            if (!defined($full)) {
                $full = !PVE::LXC::Config->is_template($src_conf);
            }

            PVE::Firewall::clone_vmfw_conf($vmid, $newid);

            die "parameter 'storage' not allowed for linked clones\n"
                if defined($storage) && !$full;

            die "snapshot '$snapname' does not exist\n"
                if $snapname && !defined($src_conf->{snapshots}->{$snapname});

            my $src_conf = $snapname ? $src_conf->{snapshots}->{$snapname} : $src_conf;

            # pve-bindsnap: effective BINDSNAP-EXCLUDE set for this clone. Read from the
            # source CT Notes for a live clone, or the snapshot's own frozen description
            # for a --snapname clone (both are $src_conf->{description} at this scope).
            # @clone_carried / @clone_excluded (declared in the outer scope) feed the
            # task-log summary + warning below.
            my $clone_excl = _snap_excludes($src_conf->{description}) // {};

            my $sharedvm = 1;
            for my $opt (sort keys %$src_conf) {
                next if $opt =~ m/^unused\d+$/;

                my $value = $src_conf->{$opt};

                if (($opt eq 'rootfs') || ($opt =~ m/^mp\d+$/)) {
                    my $mp = PVE::LXC::Config->parse_volume($opt, $value);

                    if ($mp->{type} eq 'volume') {
                        my $volid = $mp->{volume};

                        my ($sid, $volname) = PVE::Storage::parse_volume_id($volid);
                        $sid = $storage if defined($storage);
                        my $scfg = PVE::Storage::storage_config($storecfg, $sid);
                        if (!$scfg->{shared}) {
                            $sharedvm = 0;
                            warn "found non-shared volume: $volid\n" if $target;
                        }

                        $rpcenv->check($authuser, "/storage/$sid", ['Datastore.AllocateSpace']);

                        if ($full) {
                            if ($running && !defined($snapname)) {
                                die "Full clone of a running container is only possible from a"
                                    . " snapshot\n";
                            }
                            $fullclone->{$opt} = 1;
                        } else {
                            # not full means clone instead of copy
                            die "Linked clone feature for '$volid' is not available\n"
                                if !PVE::Storage::volume_has_feature(
                                    $storecfg,
                                    'clone',
                                    $volid,
                                    $snapname,
                                    $running,
                                    { 'valid_target_formats' => ['raw', 'subvol'] },
                                );
                        }

                        $mountpoints->{$opt} = $mp;
                        push @$vollist, $volid;

                    } else {
                        # pve-bindsnap: bind/device mountpoint has no managed volume to
                        # clone. Carry the entry to the new CT unchanged (same host path/
                        # device) unless a BINDSNAP-EXCLUDE directive drops it. Replaces
                        # upstream's `die "unable to clone mountpoint ..."`. The carried
                        # entry is NOT added to %mountpoints, so the forked realcmd never
                        # tries to copy a volume for it.
                        if ($clone_excl->{$opt}) { push @clone_excluded, $opt; next; }
                        push @clone_carried, $opt;
                        $newconf->{$opt} = $value;
                    }
                } elsif ($opt =~ m/^net(\d+)$/) {
                    # always change MAC! address
                    my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
                    my $net = PVE::LXC::Config->parse_lxc_network($value);
                    $net->{hwaddr} = PVE::Tools::random_ether_addr($dc->{mac_prefix});
                    $newconf->{$opt} = PVE::LXC::Config->print_lxc_network($net);

                    PVE::LXC::check_bridge_access($rpcenv, $authuser, $newconf->{$opt});
                } else {
                    # copy everything else
                    $newconf->{$opt} = $value;
                }
            }
            die "can't clone CT to node '$target' (CT uses local storage)\n"
                if $target && !$sharedvm;

            # Replace the 'disk' lock with a 'create' lock.
            $newconf->{lock} = 'create';

            # delete all snapshot related config options
            delete $newconf->@{qw(snapshots parent snaptime snapstate)};

            delete $newconf->{pending};
            delete $newconf->{template};

            $newconf->{hostname} = $param->{hostname} if $param->{hostname};
            $newconf->{description} = $param->{description} if $param->{description};

            $lock_and_reload->(
                $newid,
                sub {
                    PVE::LXC::Config->write_config($newid, $newconf);
                },
            );
        };
        if (my $err = $@) {
            eval { PVE::LXC::Config->remove_lock($vmid, 'disk') };
            warn "Failed to remove source CT config lock - $@\n" if $@;

            eval {
                $lock_and_reload->(
                    $newid,
                    sub {
                        PVE::LXC::Config->destroy_config($newid);
                        PVE::Firewall::remove_vmfw_conf($newid);
                    },
                );
            };
            warn "Failed to remove target CT config - $@\n" if $@;

            die $err;
        }

        my $update_conf = sub {
            my ($key, $value) = @_;
            return $lock_and_reload->(
                $newid,
                sub {
                    my $conf = shift;
                    $conf->{$key} = $value;
                    PVE::LXC::Config->write_config($newid, $conf);
                },
            );
        };

        my $realcmd = sub {
            my ($upid) = @_;

            my $newvollist = [];

            print("creating a clone of container $vmid with ID $newid\n");

            # pve-bindsnap: report what the overlay did to the 'vzclone' task log (parity
            # with the snapshot summary), and warn if bind/device mounts were carried (they
            # share the source's host paths). Printed in the worker so it reaches the task
            # Output; eval-guarded so it can never affect the clone itself.
            eval {
                print _clone_summary(
                    vmid => $vmid, newid => $newid, vlabel => $vlabel,
                    cloned => [sort keys %$mountpoints],
                    carried => \@clone_carried, excluded => \@clone_excluded,
                );
                _task_warn(_clone_carry_warning(\@clone_carried)) if @clone_carried;
                1;
            };

            my $verify_running = PVE::LXC::check_running($vmid) || 0;
            die "unexpected state change\n" if $verify_running != $running;

            eval {
                local $SIG{INT} = local $SIG{TERM} = local $SIG{QUIT} = local $SIG{HUP} =
                    sub { die "interrupted by signal\n"; };

                PVE::Storage::activate_volumes($storecfg, $vollist, $snapname);
                my $bwlimit = PVE::Tools::extract_param($param, 'bwlimit');

                foreach my $opt (keys %$mountpoints) {
                    my $mp = $mountpoints->{$opt};
                    my $volid = $mp->{volume};

                    my $newvolid;
                    if ($fullclone->{$opt}) {
                        print "create full clone of mountpoint $opt ($volid)\n";
                        my $source_storage = PVE::Storage::parse_volume_id($volid);
                        my $target_storage = $storage // $source_storage;
                        my $clonelimit = PVE::Storage::get_bandwidth_limit(
                            'clone', [$source_storage, $target_storage], $bwlimit,
                        );
                        $newvolid = PVE::LXC::copy_volume(
                            $mp,
                            $newid,
                            $target_storage,
                            $storecfg,
                            $newconf,
                            $snapname,
                            $clonelimit,
                        );
                    } else {
                        print "create linked clone of mount point $opt ($volid)\n";
                        $newvolid =
                            PVE::Storage::vdisk_clone($storecfg, $volid, $newid, $snapname);
                    }

                    push @$newvollist, $newvolid;
                    $mp->{volume} = $newvolid;

                    $update_conf->(
                        $opt,
                        PVE::LXC::Config->print_ct_mountpoint($mp, $opt eq 'rootfs'),
                    );
                }

                PVE::AccessControl::add_vm_to_pool($newid, $pool) if $pool;

                $lock_and_reload->(
                    $newid,
                    sub {
                        my $conf = shift;
                        my $rootdir = PVE::LXC::mount_all($newid, $storecfg, $conf, 1);

                        eval {
                            PVE::LXC::create_ifaces_ipams_ips($conf, $newid);
                            my $lxc_setup = PVE::LXC::Setup->new($conf, $rootdir);
                            $lxc_setup->post_clone_hook($conf);
                        };
                        my $err = $@;
                        eval { PVE::LXC::umount_all($newid, $storecfg, $conf, 1); };
                        if ($err) {
                            warn "$@\n" if $@;
                            die $err;
                        } else {
                            die $@ if $@;
                        }
                    },
                );
            };
            my $err = $@;
            # Unlock the source config in any case:
            eval { PVE::LXC::Config->remove_lock($vmid, 'disk') };
            warn $@ if $@;

            if ($err) {
                # Now cleanup the config & disks & ipam:
                sleep 1; # some storages like rbd need to wait before release volume - really?

                foreach my $volid (@$newvollist) {
                    eval { PVE::Storage::vdisk_free($storecfg, $volid); };
                    warn $@ if $@;
                }

                eval {
                    $lock_and_reload->(
                        $newid,
                        sub {
                            my $conf = shift;
                            PVE::LXC::delete_ifaces_ipams_ips($conf, $newid);
                            PVE::LXC::Config->destroy_config($newid);
                            PVE::Firewall::remove_vmfw_conf($newid);
                        },
                    );
                };
                warn "Failed to remove target CT config - $@\n" if $@;

                die "clone failed: $err";
            }

            $lock_and_reload->(
                $newid,
                sub {
                    PVE::LXC::Config->remove_lock($newid, 'create');

                    if ($target) {
                        # always deactivate volumes - avoid lvm LVs to be active on several nodes
                        PVE::Storage::deactivate_volumes($storecfg, $vollist, $snapname)
                            if !$running;
                        PVE::Storage::deactivate_volumes($storecfg, $newvollist);

                        PVE::LXC::Config->move_config_to_node($newid, $target);
                    }
                },
            );

            return;
        };

        return $rpcenv->fork_worker('vzclone', $vmid, $authuser, $realcmd);
    };
}

# Install the clone_vm override, gated by the @CLONE_GUARDED_FILES checksum. Called by the
# API2/LXC wrapper AFTER it has require()d the genuine upstream (which registers the stock
# clone_vm). Idempotent and never-die-critical (the wrapper also eval-guards the call).
sub apply_clone {
    return if $CLONE_LOADED;

    eval { require PVE::API2::LXC; 1 } or do {
        _log("PVE::API2::LXC not loadable ($@); clone override inert");
        return;
    };

    my ($sum, $per) = _config_checksum(map { _module_path($_) } @CLONE_GUARDED_FILES);
    my $vlabel = _pkg_version('pve-container') // 'unknown';
    my $checksum_known = defined($sum) && exists $KNOWN_GOOD_CLONE_CHECKSUMS{$sum};
    my $bad_reason = (defined($sum) && exists $KNOWN_BAD_CLONE_CHECKSUMS{$sum})
        ? $KNOWN_BAD_CLONE_CHECKSUMS{$sum} : undef;
    my $combined = $sum // 'unavailable';

    # Untested or known-bad clone_vm: do NOT install our copied method body (it could be
    # stale against a different upstream). Leave stock clone_vm -- bind clones stay blocked
    # exactly as upstream, no regression. CLONE_LOADED is still set (the wrapper chain works).
    if (!$checksum_known || defined $bad_reason) {
        my $why = defined $bad_reason ? "known-BAD ($bad_reason)" : "untested";
        _log_banner("clone overlay loaded but NOT active: pve-container $vlabel clone_vm is "
                  . "$why (combined sha256 $combined); bind-mount clones use stock behaviour. "
                  . "Compatible builds: $COMPAT_URL");
        $CLONE_LOADED = 1;
        return;
    }

    my $info = eval { PVE::API2::LXC->map_method_by_name('clone_vm') };
    if ($info && ref($info) eq 'HASH' && ref($info->{code}) eq 'CODE') {
        $info->{code} = _clone_code($vlabel);    # mutate the live, shared method definition
        $CLONE_APPLIED = 1;
        _log_banner("clone overlay active (pve-container $vlabel, checksum-validated; "
                  . "combined sha256 $combined): bind/device mountpoints are carried to the "
                  . "clone (BINDSNAP-EXCLUDE drops named mpN)");
    } else {
        _log("clone_vm method definition not found; clone override DISABLED (stock behaviour)");
    }

    $CLONE_LOADED = 1;
}

# Top-level must NEVER die: the wrapper already eval-guards loading us, and staying
# inert on any error keeps PVE::LXC::Config stock rather than broken.
eval { _apply(); 1 } or do {
    _log("apply failed, staying inert: $@");
};

1;
