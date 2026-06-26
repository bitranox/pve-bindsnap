# How it works

## The problem

Proxmox gates snapshots on one question: can every mountpoint be snapshotted? A
bind mount fails that test. Its "volume" is a host path like `/mnt/cifs/backups`,
not a storage volume, so `has_feature('snapshot')` returns false and the whole
container's snapshot button greys out.

Forcing that gate open isn't enough on its own. The code that actually creates the
snapshot walks every mountpoint too (`snapshot_create` -> `foreach_volume` ->
`__snapshot_create_vol_snapshot` -> `PVE::Storage::volume_snapshot`), and it dies
the moment it tries to read a host path as `storage:volume`. The container's own
rootfs, on snapshot-capable storage like ZFS, was never the problem. The bind mounts
are.

## The approach

Hide the non-`volume` mountpoints from the snapshot code, and only from the snapshot
code. Everything funnels through one iteration primitive, so there's a single place
to do it:

- `foreach_volume()` just calls `foreach_volume_full()`.
- `__snapshot_activate_storages()` calls `foreach_volume_full()` directly, and it
  already skips anything that isn't a `volume`.

So `foreach_volume_full()` is the choke point. The overlay wraps it with a filter
that drops bind and device mounts, and it installs that filter only for the duration
of a snapshot call, with Perl's dynamic `local`. Outside snapshots, volume iteration
(for mount, start, migrate, and the rest) runs exactly as it did.

The skip is blanket, not clever. A mountpoint is dropped because its type is `bind`
or `device`, not because its storage can't be snapshotted. So a bind mount is left
out of the snapshot **even if the host path behind it sits on a ZFS dataset that
could be snapshotted on its own**. The overlay doesn't look at what's behind a bind
mount, and Proxmox doesn't manage it as a storage volume in the first place. What
gets snapshotted is the container's managed volumes: the rootfs, and any other
`volume`-type mountpoint on snapshot-capable storage (a second `mp1` data disk is
snapshotted right alongside the rootfs). Bind and device mounts are never part of the
snapshot, and their data is left untouched and unversioned.

A managed volume can also be left out on purpose with a `BINDSNAP-EXCLUDE` directive in the
container's Notes (overridable per snapshot, and frozen into each snapshot so rollback
stays consistent), useful for a large or throwaway data disk. See
[BINDSNAP-EXCLUDE](bindsnap-exclude.md) for the full details.

The overlay only engages for containers that actually have a bind or device mount. A
container whose mountpoints are all managed volumes needs nothing from it, so it's
left completely alone: its snapshot runs stock Proxmox, on any pve-container version,
recognised by the checksum guard or not. Only bind-mount containers are gated (see
[the checksum guard](checksum-guard.md)).

A few more decisions are worth spelling out, because they're what keep this from
being reckless:

It loads by diverting `PVE::LXC::Config`. `install.sh` runs `dpkg-divert` to rename
the genuine `/usr/share/perl5/PVE/LXC/Config.pm` to `Config.pm.distrib`, and installs
a thin wrapper at the original path. The wrapper `require`s `.distrib` (the genuine
upstream) and then the overlay. The Proxmox daemons and `pct` run `perl -T` (taint
mode), where a module is only honoured if it loads from `@INC` as part of the program,
so this is how the overlay reaches them. The wrapper loads the overlay eval-guarded:
an overlay bug can't stop `Config.pm` from loading, it just falls back to stock. The
one hard requirement is that the wrapper can load `.distrib`, which is the genuine
upstream file, so that's the same dependency Proxmox already has.

It calls the live upstream code rather than copying it. The wrapper `require`s the
diverted `.distrib`, and `dpkg-divert` reroutes `pve-container` upgrades to that path,
so we always run against the current upstream, never a frozen fork. The overlay
captures coderefs to the real `has_feature`, `snapshot_create`, and friends and calls
them; the only logic it actually owns is the thin bind filter, so when Proxmox changes
its snapshot internals, those changes come along for free.

It gates on a checksum, not a version string. The wrappers are always installed, but
whether a bind-mount container can actually be snapshotted depends on whether the
checksum of the upstream source matches a known-good value. That's its own page:
[the checksum guard](checksum-guard.md).

The backup path is left completely alone. `vzdump` already excludes bind mounts on
its own, so the overlay passes anything with the `vzdump` snapshot name straight
through to stock code.

It never patches the web GUI. Every parameter the overlay takes (`BINDSNAP-FORCE-RUNNING`,
`BINDSNAP-UNSUPPORTED`, `BINDSNAP-EXCLUDE`) rides in fields Proxmox already has: the snapshot's
name or description, and the container's Notes. There's no custom panel, no injected
JavaScript, nothing in the interface for a Proxmox update to clobber. Combined with the
`dpkg-divert` load (which upgrades reroute safely), the whole integration is update-safe
by construction: nothing the overlay touches is something an upgrade overwrites.

## Cloning bind-mount containers

`pct clone` fails for the same reason snapshots did, but in a different place. The reject
is an inline `die "unable to clone mountpoint '$opt' (type $mp->{type})"` inside
`PVE::API2::LXC::clone_vm`, a different module from the diverted `PVE::LXC::Config`, and the
clone loop walks the raw config keys rather than going through `foreach_volume_full`, so the
snapshot filter can't reach it. The non-`volume` branch just dies; the branch right next to
it (`# copy everything else`) already copies any other option to the new container verbatim.

So the change is small: for a `rootfs`/`mpN` whose type is not `volume`, carry the entry to
the clone unchanged (it points at the same host path/device) instead of dying, unless a
`BINDSNAP-EXCLUDE` directive drops it. Managed volumes and the rootfs clone exactly as
stock. A carried bind mount is not added to the clone's volume list, so the forked worker
never tries to copy a volume for it; it simply appears in the new container's config and
`mount_all` mounts the same host path, as it did on the source.

The override mechanism differs from the snapshot one, because `clone_vm` is registered as an
anonymous `register_method` *closure*, not a named sub: there is nothing to redefine by
typeglob, and re-registering the same method dies on a duplicate. Instead the overlay asks
`PVE::API2::LXC->map_method_by_name('clone_vm')` for the live method definition (the same
shared hashref every dispatch path uses, GUI/API and `pct` alike) and replaces its `code`
slot in place. It is loaded by a **second** `dpkg-divert`, of `PVE::API2::LXC`, with a thin
wrapper that `require`s the genuine `.distrib` (which registers the stock `clone_vm`) and
then calls the overlay's `apply_clone`, all under the same `perl -T` reasoning as the
`Config` divert.

One thing the clone override does that the snapshot overlay does not: it installs a *copy*
of upstream's `clone_vm` body (with the one change), rather than wrapping live coderefs.
That is unavoidable, because the die sits inline in a closure with no seam to wrap. It also
makes the override version-fragile, so it has its **own** checksum guard, separate from the
snapshot guard and hashing only `PVE/API2/LXC.pm` (the file the copy comes from). On a build
whose `clone_vm` the copy hasn't been vetted against, the override is simply not installed:
`clone_vm` stays stock (bind clones refused, the original behaviour), so there is never a
regression and never a stale copy dispatched against a changed Proxmox. A `pve-container`
upgrade reroutes to the `.distrib`, the next daemon start re-hashes it, and an unrecognised
hash disables the override automatically. See [the checksum guard](checksum-guard.md).

## What it deliberately doesn't do

There are real limits here. None of them are bugs, but you should know about them
before you lean on the overlay.

It's per-node. A snapshot you take on a patched node can't be deleted or rolled back
on an unpatched one in the same cluster, because that node's stock code hits the bind
path and dies. For a privileged container with host binds that won't migrate anyway,
this rarely bites, but it's a sharp edge.

A rollback rewinds the captured managed volumes -- the rootfs and any other
`volume`-type `mpN` disk that went into the snapshot -- but not the bind/device mounts.
That host-side data lives outside Proxmox storage and isn't versioned by any of this, so
a rollback is not a full point-in-time restore of everything the container can see: the
managed volumes rewind, the bind/device data stays as it is now.

## The zero-risk alternative

The overlay buys you one thing over plain ZFS: the snapshot shows up in the GUI and
`pct listsnapshot`. For the clean case, a stopped container, you get the identical
result from `zfs` directly, with none of the caveats above:

```bash
zfs snapshot <pool>/subvol-<vmid>-disk-0@before-change   # instant, container stopped
zfs rollback <pool>/subvol-<vmid>-disk-0@before-change   # container stopped
zfs destroy  <pool>/subvol-<vmid>-disk-0@before-change
```

A small wrapper over those three commands gets you most of the ergonomics at none of
the risk. Reach for the overlay when you specifically want Proxmox to know about the
snapshot.

## Repo layout

```
lib/PVE/LXC/BindSnap.pm          the overlay module (installed to /usr/local/lib/site_perl)
lib/PVE/LXC/Config.wrapper.pm    snapshot wrapper (installed as /usr/share/perl5/PVE/LXC/Config.pm)
lib/PVE/API2/LXC.wrapper.pm      clone wrapper (installed as /usr/share/perl5/PVE/API2/LXC.pm)
install.sh / uninstall.sh        helpers (read them first)
t/                               unit tests (no Proxmox needed)
docs/                            this and the other guides
```
