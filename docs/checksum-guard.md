# The checksum guard

The overlay wraps Proxmox's snapshot methods, and those methods change between
releases. To avoid running against a version it wasn't checked on, it gates the
actual work on a checksum of the upstream source rather than on a version number. A
version string can move without the code moving, and the code can move without the
version telling you, so the bytes are what it trusts.

It hashes both files it depends on: the LXC config module (where `has_feature` and the
private `__snapshot_*` helpers live) and `/usr/share/perl5/PVE/AbstractConfig.pm`
(where `foreach_volume_full` and the `snapshot_create` / `delete` / `rollback`
originals are inherited from). The two per-file hashes are combined, in that fixed
order, into one value. Once installed, the genuine LXC config module is the diverted
`/usr/share/perl5/PVE/LXC/Config.pm.distrib` (the original path holds the thin
wrapper), and the overlay hashes the `.distrib`, the real upstream bytes, so the
value is the same whether or not the divert is in place.

The known-good list in the module maps that combined hash to the Proxmox version it
came from. Both are stored, but only the hash decides anything; the version is there
so the log line is readable.

```perl
my %KNOWN_GOOD_CHECKSUMS = (
    '1ebb1a44483bfdabed59f421c88003673a283cd83cd4009407ce39219faa6106' => '6.1.10',
);
```

You can reproduce that value by hand. This is exactly what the overlay computes and
logs, so the journal value and this command agree byte for byte. Use `Config.pm.distrib`
if the overlay is installed, plain `Config.pm` otherwise:

```bash
config=/usr/share/perl5/PVE/LXC/Config.pm
[ -e "$config.distrib" ] && config="$config.distrib"
printf '%s\n' \
  "$(sha256sum "$config"                              | awk '{print $1}')" \
  "$(sha256sum /usr/share/perl5/PVE/AbstractConfig.pm | awk '{print $1}')" \
| sha256sum | awk '{print $1}'
```

The gate only applies to containers that actually have bind/device mounts. A
container without them needs nothing from the overlay, so it snapshots like stock
Proxmox on **any** version, recognised or not. When the hash matches the list,
bind-mount snapshots also just work. When it doesn't, the overlay logs a "TEST mode"
line and `snapshot_create` refuses **bind-mount** containers unless you opt in with
the `BINDSNAP-UNSUPPORTED` keyword. You can always list and clean up snapshots you already
made (`snapshot_delete`/`snapshot_rollback` are unaffected by the gate).

There are two tables, not one. `%KNOWN_GOOD_CHECKSUMS` is the allow-list above;
`%KNOWN_BAD_CHECKSUMS` is a **deny-list** of builds reported to mishandle bind-mount
snapshots. A checksum on the deny-list is **hard-blocked**: bind-mount CT snapshots are
refused and `BINDSNAP-UNSUPPORTED` will *not* override it (the only override is updating
pve-container or using `zfs snapshot` directly). The deny-list is checked first, so a
bad build always loses. Both tables are mirrored for humans on the [compatible
versions](compatible-versions.md) page. The refusal messages print the known-good list
and link that page, so the operator can see what to update to.

## The clone guard

Clone support has a **second, independent** guard, because it works differently from the
snapshot overlay. The snapshot overlay wraps live upstream coderefs, so it stays correct
across versions and only gates whether bind-mount snapshots are *allowed*. The clone
override instead installs a *copy* of Proxmox's `clone_vm` body (the die it has to change
sits inline in a closure with no seam to wrap), so running it against a changed Proxmox
would mean running stale code. To prevent that, the clone override is **install-gated**: it
is only put in place when the checksum matches.

It hashes a single file, `/usr/share/perl5/PVE/API2/LXC.pm`, the one the copy comes from
(its `clone_vm` is the entire coupling surface; the helpers it calls are stable named
interfaces). The same two-table shape applies, with clone-specific tables:

```perl
my %KNOWN_GOOD_CLONE_CHECKSUMS = (
    '8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198' => '6.1.10',
);
```

Reproduce it the same way (use `LXC.pm.distrib` if the overlay is installed):

```bash
api=/usr/share/perl5/PVE/API2/LXC.pm
[ -e "$api.distrib" ] && api="$api.distrib"
sha256sum "$api" | awk '{print $1}' | sha256sum | awk '{print $1}'
```

On a build that isn't in the clone known-good table, the override is **not installed** at
all: `pct clone` keeps stock Proxmox behaviour, so a bind-mount container is refused exactly
as it is without the overlay. There is no `BINDSNAP-UNSUPPORTED`-style override for clone,
on purpose: the safe fallback is stock, never a stale copy. After a `pve-container` upgrade,
the new `clone_vm` lands at the diverted `.distrib`, the next daemon start re-hashes it, the
unrecognised hash disables the override, and clone reverts to stock until the new build is
vetted and its hash added. To get a new build clone-supported, vet it (clone a bind-mount CT
per the [test plan](testing.md)) and report the version and this clone hash so the
`hash => version` line can be added.

## When a version isn't recognised

After a `pve-container` upgrade that changes either file, the hash stops matching and
the overlay drops back to TEST mode. The button still appears, but a plain snapshot
of a bind-mount container is refused with a message that prints the version and the
combined hash. To get that version supported:

1. On a spare node, take the snapshot with `BINDSNAP-UNSUPPORTED` in the name or description,
   in the GUI dialog or with `pct` (the installed wrapper covers `pct snapshot`), for
   example `pct snapshot 123 testrun --description "BINDSNAP-UNSUPPORTED"`. That's the
   deliberate "I'm testing an unvetted build" opt-in. The snapshot succeeds, but the task
   finishes as a yellow `TASK WARNINGS` (not a green `TASK OK`), with a `WARN` line nudging
   you to report the build, so an untested snapshot never passes silently.
2. Run the [test plan](testing.md): a stopped create, rollback, and delete, the
   running-container `BINDSNAP-FORCE-RUNNING` path, and a check that `vzdump` still works.
3. If all of that holds up, report the version and the combined hash (both are in the
   journal line) to the project's issues page. The exact URL is the one the overlay
   prints; in the source it's the `$REPORT_ISSUES_URL` constant, which is the single
   place that holds it. A maintainer adds the `hash => version` line, and from then
   on the overlay snapshots that build with no keyword needed.

## What it's been checked against

`pve-container 6.1.10`, combined hash
`1ebb1a44483bfdabed59f421c88003673a283cd83cd4009407ce39219faa6106` (per file:
`Config.pm` `eb4ed7b4...3abf3be7`, `AbstractConfig.pm` `70432cce...61871494`). Every node
in a cluster on the same package version shares those exact bytes, so one entry
covers the whole cluster at that version.
