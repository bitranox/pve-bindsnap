# pve-bindsnap

Snapshot Proxmox LXC containers that have bind-/device-mounts (`mpN` entries
pointing at host paths). Proxmox greys those out; this overlay enables them again,
delegating to Proxmox's genuine snapshot code rather than forking it.

> Release 1.0.1. It passes the unit tests and has been exercised on Proxmox VE 9.2
> (pve-container 6.1.10) across the full install lifecycle and matrix: create / rollback /
> delete (including a data-level rollback), the `BINDSNAP-FORCE-RUNNING`, `BINDSNAP-UNSUPPORTED`
> and `BINDSNAP-EXCLUDE` paths, each both per-snapshot and as a standing CT-Notes directive,
> plus the known-bad hard block, and it runs in the author's own production cluster. It
> hasn't been run against other pve-container versions yet,
> so on a build it doesn't recognise it refuses by default until you opt in. It's a small,
> commented overlay: read the source and the [test plan](docs/testing.md) before you deploy.
>
> The risks are low: the wrapper loads the overlay eval-guarded (a bug in it just falls
> back to stock), the installer pre-flights and rolls back on failure, `uninstall.sh`
> restores stock cleanly, and containers without bind/device mounts are never touched. So
> please try it on other Proxmox / pve-container versions and report back on the
> [issues page](https://github.com/bitranox/pve-bindsnap/issues), whether it
> worked or **not**, with the version and combined checksum the overlay prints, so the
> tested set can grow and known-bad builds get flagged.

## Why?

Add a bind mount to a container and Proxmox stops letting you snapshot it. The check
it runs is "can every mountpoint be snapshotted?", and a bind mount (just a host
path) can't, so the whole container loses its snapshot button. That happens even
when the real rootfs sits on ZFS and would snapshot fine on its own.

The overlay hides the bind and device mounts from the snapshot code path, and only
from that path. Your Proxmox-managed volumes are still snapshotted exactly as they
would be normally; only the bind/device mounts are skipped, and their data on the host
is left untouched.

| What's in the container config  | In the snapshot?         | Notes                               |
|---------------------------------|--------------------------|-------------------------------------|
| `rootfs` (the root disk)        | **Yes**                  | Proxmox-managed volume; always kept |
| `mpN`: a storage volume         | **Yes**, unless excluded | Managed volume (e.g. a data disk)   |
| `mpN`: a bind mount (host path) | **No**                   | Host data, left untouched           |
| `devN`: a passthrough device    | **No**                   | Not a managed volume                |

So a storage-backed data disk on `mp1` is captured right alongside the rootfs, while a
`/mnt/...` bind mount stays out of the snapshot, even if the path behind it happens to
sit on ZFS. Everything else Proxmox does carries on unchanged, backups (`vzdump`)
included.

If you only want the rootfs snapshot and don't care about seeing it in the GUI, you
don't need any of this: `zfs snapshot` on the stopped container gives you the same
result. The overlay earns its keep when you want the snapshot to show up in the GUI and
`pct`, or when a scheduled fleet snapshotter like
[cv4pve-autosnap](https://github.com/Corsinvest/cv4pve-autosnap) takes them through the API
for you (the divert covers that path too, so it can finally snapshot a bind-mount CT). The
trade-offs are in [the design notes](docs/design.md).

## Install

One line, on one node. It patches a running hypervisor as root; the source is right
there on [GitHub](https://github.com/bitranox/pve-bindsnap) if you want to read it first.

```bash
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install.sh | bash
```

Prefer to clone and look before you run?

```bash
git clone https://github.com/bitranox/pve-bindsnap
cd pve-bindsnap && less install.sh && ./install.sh
```

Either way, `install.sh` installs the overlay module, diverts `PVE::LXC::Config` and
puts a thin wrapper in its place (the genuine upstream is preserved alongside it),
verifies it loads, then restarts the PVE daemons and prints the activation line. If
the verification fails it rolls back and leaves the node untouched. Re-running it is
safe (idempotent). Removing it is the same one line with `uninstall.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/uninstall.sh | bash
```

## Using it

Snapshots of a bind-mount container then work the usual way: the GUI "Take Snapshot"
button, the API, or `pct snapshot`. Stop the container first and there's nothing else
to do.

Two cases ask you to opt in, and you do that by putting a keyword in the snapshot's
**name** or its **description** (either field). The keyword stays in the saved comment,
so later you can see what you passed. Parameters ride in fields Proxmox already has,
the snapshot name/description and the container Notes, so the overlay never patches the
web GUI, and a Proxmox update can't break it.

Type `BINDSNAP-FORCE-RUNNING` to snapshot a *running* container. A running container is refused
otherwise, because the snapshot briefly freezes its filesystem and that freeze can
stall on FUSE or CIFS mounts.

The freeze quiesces the running container so the snapshot is consistent, and the overlay
doesn't change it: even though the bind mounts are kept out of the snapshot itself, a slow
userspace (FUSE) or network (CIFS) mount can still hold the freeze up. On local or ZFS
storage it's instant, but such a mount has to flush its in-flight I/O first, and if the
backing store is slow or unreachable that flush blocks. While it blocks, anything writing to
that mount hangs, so the container appears stalled until the freeze clears or times out, and
a wedged backing store can drag that out. So stop the container for a clean snapshot, or
force a running one only when you know those mounts are fast and healthy. The keyword says
you've accepted that:

```bash
pct snapshot 123 pre-change --description "BINDSNAP-FORCE-RUNNING"
```

Each keyword is matched as its own token: a hyphen, an underscore or a space sets it
off, so `BINDSNAP-FORCE-RUNNING`, `BINDSNAP-FORCE-RUNNING_2026-08-11` (an auto-generated name)
and `pre-BINDSNAP-UNSUPPORTED` all count, but it won't fire glued onto a letter or digit,
or in the wrong case. (`BINDSNAP-EXCLUDE` is the exception: it always needs its colon and a
list, e.g. `BINDSNAP-EXCLUDE: mp1`, so it isn't underscore-glued.)

Type `BINDSNAP-UNSUPPORTED` to snapshot on a Proxmox build the overlay hasn't been checked
against. On a build it doesn't recognise it refuses by default and logs what it saw;
the keyword says you're testing it on purpose. A few builds are instead **hard-blocked**,
known to mishandle bind-mount snapshots, and `BINDSNAP-UNSUPPORTED` will *not* override those;
there you update pve-container or use `zfs snapshot` directly. This only affects
bind-mount containers, though: a container without bind/device mounts snapshots normally
on any version, since the overlay leaves it alone entirely. The [compatible
versions](docs/compatible-versions.md) page lists what's supported, hard-blocked, or
untested; [how the guard works](docs/checksum-guard.md) explains the rest.

`BINDSNAP-UNSUPPORTED` can also be a standing line in the container's Notes (so an automated
tool can snapshot a bind-mount CT on an untested build), but **a standing
`BINDSNAP-UNSUPPORTED` is risky**: leave it there, let Proxmox later update to a new,
*untested* build, and the overlay will silently snapshot on that build instead of
re-gating, so the snapshot could misbehave or fail quietly. Prefer the per-snapshot
form, or remove the Notes line once you're back on a tested build. Better still, the proper
fix for an untested build is to get it onto the known-good list: run the
[test plan](docs/testing.md), and if it holds up, report the version and the combined
checksum (both printed by the overlay) on the
[issues page](https://github.com/bitranox/pve-bindsnap/issues) so it can be added. After that
the build snapshots with no keyword at all, and the standing opt-in is no longer needed. (A
standing `BINDSNAP-FORCE-RUNNING` doesn't carry this risk: whether a running freeze is safe
depends on the container's mounts, not on the Proxmox build.)

It's a nudge, not a wall. A snapshot on an untested build, or one taken while a standing
`BINDSNAP-UNSUPPORTED` lingers in the Notes, still succeeds, but the task finishes as a yellow
**`TASK WARNINGS`** in the task list (not a red error), with a `WARN` line that says exactly
what to do: report the build so it can join the known-good list, or drop the directive. So it
stands out instead of passing silently as a green `TASK OK`.

### Automated / scheduled snapshots of running containers (`BINDSNAP-FORCE-RUNNING`)

`BINDSNAP-FORCE-RUNNING` is fine when you take a snapshot by hand, but a scheduler can't type it: tools
like [cv4pve-autosnap](https://github.com/Corsinvest/cv4pve-autosnap) snapshot *running*
containers on a timer with an auto-generated name and a fixed description, so there's
nowhere to put the keyword. For that, mark the **container** once instead of each
snapshot: add a `BINDSNAP-FORCE-RUNNING` line to its **Notes** (its description), the same place
`BINDSNAP-EXCLUDE` goes:

```
#### BINDSNAP-FORCE-RUNNING
```

From then on this container may be snapshotted while running with no per-snapshot
keyword, exactly what an automated tool needs. It's a standing per-container opt-in to
the filesystem-freeze, so apply it only where that freeze is safe (it still doesn't
apply to plain containers, which the overlay never gates). Nothing else changes:
containers are filesystem-snapshotted (Proxmox has no RAM-state snapshots for
containers; cv4pve-autosnap's `--state` only affects VMs and is ignored for CTs), and
the bind/device mounts are skipped as always.

### Leaving a managed volume out of the snapshot

By default every managed volume is captured (see the table above). To keep a specific
data disk *out* of the snapshot, say a large or throwaway `mp1` you don't want
versioned with the rootfs, add a `BINDSNAP-EXCLUDE` line to the container's **Notes**
(its description). Write it as a small markdown heading so it tucks itself away:

```
#### BINDSNAP-EXCLUDE: mp1 mp2
```

That's a standing rule on the container: from then on those volumes are skipped, and
the rule is frozen into each snapshot when it's taken, so a later edit to the
container can never change what an existing snapshot rolls back to. You can override it
for a single snapshot by putting a `BINDSNAP-EXCLUDE` line in *that snapshot's* description;
an empty one (`BINDSNAP-EXCLUDE:`) means "exclude nothing this time":

| Container Notes         | This snapshot's description | What's left out of the snapshot |
|-------------------------|-----------------------------|---------------------------------|
| `BINDSNAP-EXCLUDE: mp1` | (nothing about exclude)     | `mp1` (the standing rule)       |
| `BINDSNAP-EXCLUDE: mp1` | `BINDSNAP-EXCLUDE: mp2`     | `mp2` only (override)           |
| `BINDSNAP-EXCLUDE: mp1` | `BINDSNAP-EXCLUDE:` (empty) | nothing (override clears it)    |
| (nothing)               | `BINDSNAP-EXCLUDE: mp2`     | `mp2` (just this snapshot)      |
| (nothing)               | (nothing)                   | nothing                         |

Only `mpN` mountpoints can be excluded; the `rootfs` is always kept. This applies to
bind-mount containers (the ones the overlay engages for); a plain container the overlay
doesn't touch is unaffected.

The GUI, the API, and every `pct` invocation are all covered: the overlay rides in on
the `PVE::LXC::Config` module, so every process that loads it gets it. The [design
notes](docs/design.md) explain how.

Every snapshot, rollback and delete **task log** (the GUI task "Output", or `pct`'s task
output) carries a short overlay summary instead of a bare `TASK OK`. For a snapshot:
which volumes were kept, excluded or skipped, the checksum status, and the
BINDSNAP-FORCE-RUNNING/BINDSNAP-UNSUPPORTED status, each briefly explained. For a rollback or delete: which
volumes were reverted/removed and which were left as-is (excluded from that snapshot).
It's task-log only, so it never clutters an interactive `pct`.

## More

- [How it works, and what it deliberately doesn't do](docs/design.md)
- [BINDSNAP-EXCLUDE](docs/bindsnap-exclude.md), leaving a managed volume out of a snapshot
- [Compatible versions](docs/compatible-versions.md), supported, hard-blocked, untested
- [The checksum guard, and adding a new Proxmox version](docs/checksum-guard.md)
- [Testing on a node, plus the local dev checks](docs/testing.md)
- [Changelog](CHANGELOG.md), and the versioning policy
- [AI transparency](ai-transparency.md), and the [general stance](ai-stance.md) behind it

## License

[GNU Affero General Public License v3.0](LICENSE), Copyright (C) 2026 bitranox.
Copyleft: if you pass it on, or run a modified copy on a server people can reach, you
keep the attribution and hand on the same license with the source.
