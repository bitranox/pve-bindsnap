# pve-bindsnap

Snapshot **and clone** Proxmox LXC containers that have bind-/device-mounts (`mpN`
entries pointing at host paths). Proxmox greys snapshots out and refuses the clone; this
overlay enables both again, delegating to Proxmox's genuine snapshot and clone code
rather than forking it.

> Release 1.1.0. It passes the unit tests and has been exercised on Proxmox VE 9.2 / 9.3
> (pve-container 6.1.10) across the full install lifecycle and matrix: create / rollback /
> delete (including a data-level rollback), the `BINDSNAP-FORCE-RUNNING`, `BINDSNAP-UNSUPPORTED`
> and `BINDSNAP-EXCLUDE` paths, each both per-snapshot and as a standing CT-Notes directive,
> plus the known-bad hard block, and it runs in the author's own production cluster.
> `pct clone` of a bind-mount container is covered too (the binds are carried to the clone,
> `BINDSNAP-EXCLUDE` drops them), gated by its own checksum so an untested build falls back
> to stock. It hasn't been run against other pve-container versions yet,
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

| What's in the container config  | In the snapshot?         | In a clone?                  | Notes                                                                                                                                         |
|---------------------------------|--------------------------|------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| `rootfs` (the root disk)        | **Yes**                  | **Yes** (copied)             | Proxmox-managed volume; always kept                                                                                                           |
| `mpN`: a storage volume         | **Yes**, unless excluded | **Yes** (copied)             | Managed volume (e.g. a data disk)                                                                                                             |
| `mpN`: a bind mount (host path) | **No** (setting kept)    | **Carried**, unless excluded | Only the mount *setting* is snapshotted/cloned and restored on rollback;<br>the host *data* is never snapshotted, cloned, or rolled back      |
| `devN`: a passthrough device    | **No** (setting kept)    | **Carried**                  | Only the mount *setting* is snapshotted/cloned and restored on rollback;<br>the host device/data is never snapshotted, cloned, or rolled back |

So a storage-backed data disk on `mp1` is captured right alongside the rootfs, while a
`/mnt/...` bind mount stays out of the snapshot, even if the path behind it happens to
sit on ZFS. Everything else Proxmox does carries on unchanged, backups (`vzdump`)
included.

A snapshot never *drops* a bind/device mount. Only the mount *setting* (the `mpN`/`devN` line
in the config) is stored in the snapshot and restored on rollback -- the overlay just hides it
from the volume-snapshot step so Proxmox doesn't try to snapshot a host path. The *data* behind
the bind is never snapshotted, cloned, or rolled back: a rollback rewinds the managed volumes
(rootfs and `volume` disks), but the host data behind a bind/device mount stays exactly as it is
now, untouched. So the outcome for the mount is the same either way -- snapshot and rollback, or
clone, both restore/carry the *setting* pointing at the live host path; only the managed volumes
are ever copied or rewound, never the bind data.

A clone is the mirror image: the managed volumes are copied to the new container, and each
bind/device mount is carried to it pointing at the same host path (not copied), unless you
drop it. Note `unless excluded` flips sides between the columns: `BINDSNAP-EXCLUDE` drops a
managed volume from a *snapshot*, and a bind/device mount from a *clone*. See
[Cloning a bind-mount container](#cloning-a-bind-mount-container).

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

Either way, `install.sh` installs the overlay module, diverts `PVE::LXC::Config` (for
snapshots) and `PVE::API2::LXC` (for clone) and puts a thin wrapper in place of each (the
genuine upstream is preserved alongside it), verifies both load, then restarts the PVE
daemons and prints the activation line. If any verification fails it rolls back both and
leaves the node untouched. Re-running it is safe (idempotent). Removing it is the same one
line with `uninstall.sh`:

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

Every snapshot, rollback, delete and clone **task log** (the GUI task "Output", or `pct`'s
task output) carries a short overlay summary instead of a bare `TASK OK`. For a snapshot:
which volumes were kept, excluded or skipped, the checksum status, and the
BINDSNAP-FORCE-RUNNING/BINDSNAP-UNSUPPORTED status, each briefly explained. For a rollback or delete: which
volumes were reverted/removed and which were left as-is (excluded from that snapshot). For
a clone: which volumes were cloned, which bind/device mounts were carried, and which
`BINDSNAP-EXCLUDE` dropped. It's task-log only, so it never clutters an interactive `pct`.

## Cloning a bind-mount container

Proxmox refuses to clone a container that has a bind/device mount: `pct clone` (and the GUI
"Clone") stop with `unable to clone mountpoint 'mp0' (type bind)`. The overlay lifts that
too. The managed volumes (rootfs and any storage-backed `mpN`) are cloned exactly as stock
does; each bind/device mount is **carried to the clone unchanged**, pointing at the same
host path as the source. Nothing about the host data is copied or moved.

```bash
pct clone 123 124 --hostname web-staging
```

Because a carried bind mount is the *same* host path, the clone and the source now share
that data. That is the right default for a passthrough device, but usually wrong for a data
directory you wanted the clone to leave alone (the motivating case: cloning a webserver CT
whose copy must not inherit the live data mount). So when a clone carries a bind mount the
task finishes as a yellow **`TASK WARNINGS`** with a `WARN` line naming the carried mounts
and the directive to drop them.

To leave a bind/device mount out of clones, add a `BINDSNAP-EXCLUDE` line to the **source**
container's Notes, the same directive used for snapshots:

```
#### BINDSNAP-EXCLUDE: mp0
```

An excluded mount is dropped from the clone instead of carried. (`BINDSNAP-EXCLUDE` only
drops bind/device mounts from a clone; a managed `mpN` volume is always cloned, since for a
clone there is a real volume to copy.) Cloning a container without bind/device mounts is
completely stock, on any version.

A note on running containers and snapshots: Proxmox already requires `--snapname` to fully
clone a *running* container ("Full clone of a running container is only possible from a
snapshot"). With the snapshot overlay plus `BINDSNAP-FORCE-RUNNING` you can snapshot the
running bind-mount CT first and then clone from that snapshot; the overlay covers that path
too.

Clone support has its **own** checksum guard, separate from the snapshot one, because it
installs a copy of Proxmox's clone routine with the one bind-mount change. On a
pve-container build that copy hasn't been vetted against, the clone override simply isn't
installed and `pct clone` keeps stock behaviour (bind mounts refused), so there is never a
regression and never a stale copy run against a changed Proxmox. The [compatible
versions](docs/compatible-versions.md) page lists the clone-tested builds alongside the
snapshot ones.

## Use with an AI agent (Claude Code skill)

This repo ships a Claude Code skill, **`proxmox-bindsnap`**, so an LLM agent can install,
verify, configure and operate pve-bindsnap on a Proxmox node for you. Two ways to get it:

- **As a plugin** (auto-discovered, one command):

  ```
  /plugin marketplace add bitranox/pve-bindsnap
  /plugin install pve-bindsnap@pve-bindsnap
  ```

  The skill then loads on demand and invokes as `/pve-bindsnap:proxmox-bindsnap`.

- **As a plain skill** (copy it in): copy the skill directory into your skills folder, e.g.
  `cp -r skills/proxmox-bindsnap ~/.claude/skills/` (or a project's `.claude/skills/`). It then
  invokes as `/proxmox-bindsnap`.

The same skill is also published in the
[bitranox-skills](https://github.com/bitranox/bitranox-skills) marketplace
(`/bitranox:proxmox-bindsnap`). The skill is a self-contained runbook; it drives the same
`install.sh` / `uninstall.sh` and `BINDSNAP-` markers documented here.

## More

- [How it works, and what it deliberately doesn't do](docs/design.md)
- [BINDSNAP-EXCLUDE](docs/bindsnap-exclude.md), leaving a managed volume out of a snapshot
- [Compatible versions](docs/compatible-versions.md), supported, hard-blocked, untested
- [The checksum guard, and adding a new Proxmox version](docs/checksum-guard.md)
- [Testing on a node, plus the local dev checks](docs/testing.md)
- [The bundled AI-agent skill](skills/proxmox-bindsnap/SKILL.md) (`proxmox-bindsnap`)
- [Changelog](CHANGELOG.md), and the versioning policy
- [AI transparency](ai-transparency.md), and the [general stance](ai-stance.md) behind it

## License

[GNU Affero General Public License v3.0](LICENSE), Copyright (C) 2026 bitranox.
Copyleft: if you pass it on, or run a modified copy on a server people can reach, you
keep the attribution and hand on the same license with the source.
