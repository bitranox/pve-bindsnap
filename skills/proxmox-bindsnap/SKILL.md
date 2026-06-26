---
name: proxmox-bindsnap
description: >-
  Use when snapshotting or cloning Proxmox LXC containers that have bind/device
  mounts (mpN -> host paths) - the snapshot button is greyed out, or pct clone /
  pct snapshot fails with "unable to clone mountpoint (type bind)" or cannot
  snapshot a bind-mount container. Covers installing, verifying, configuring
  (BINDSNAP-FORCE-RUNNING, BINDSNAP-UNSUPPORTED, BINDSNAP-EXCLUDE), the checksum
  guard / untested pve-container build, cloning, and uninstalling pve-bindsnap on
  a Proxmox VE node.
---

# proxmox-bindsnap

Install, verify, configure and operate **pve-bindsnap** -- a small Perl overlay that lets
Proxmox snapshot AND clone LXC containers that carry bind/device mounts (`mpN` pointing at
host paths), which stock Proxmox greys out or refuses with `unable to clone mountpoint
'mp0' (type bind)`. It delegates to Proxmox's real snapshot/clone code (it does not fork it)
by dpkg-diverting `PVE::LXC::Config` (snapshots) and `PVE::API2::LXC` (clone). Source:
https://github.com/bitranox/pve-bindsnap

**Run on the Proxmox VE node, as root.** If you are driving the node from elsewhere, prefix
each command with `ssh root@<node>`. All `pct`/`journalctl`/`perl` commands below run on the node.

## When to use

- A container with a bind mount can't be snapshotted (the GUI button is greyed out).
- `pct clone` / GUI Clone fails: `unable to clone mountpoint 'mpN' (type bind)`.
- You need scheduled snapshots of bind-mount CTs (e.g. cv4pve-autosnap).
- You want to clone a bind-mount CT and control whether the copy inherits the bind mounts.

**Not for:** containers without bind/device mounts (they already snapshot/clone stock -- the
overlay never touches them). If you only need a rootfs snapshot and not the GUI/scheduler,
plain `zfs snapshot <pool>/subvol-<vmid>-disk-0@name` on the stopped CT is simpler and needs none of this.

## 1. Install

The model is "read the source, then install from it." Inspect first:

```
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install.sh | less
```

Then install (one node; idempotent; restarts pvedaemon/pveproxy/pvestatd):

```
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install.sh | bash
```

Or clone and run locally: `git clone https://github.com/bitranox/pve-bindsnap && cd pve-bindsnap && less install.sh && ./install.sh`.

It installs the overlay module to `/usr/local/lib/site_perl`, adds two dpkg-diverts (Config.pm
and API2/LXC.pm) with thin wrappers, pre-flights the load, and rolls back automatically (EXIT
trap) if anything fails before the daemons restart -- so a failed install leaves the node stock.

## 2. Verify

Read the activation line from the journal:

```
journalctl -u pvedaemon -b --no-pager | grep pve-bindsnap | tail -3
```

- `overlay active (... checksum-validated ...)` and `clone overlay active (... checksum-validated ...)`
  -> this pve-container build is tested; bind-mount snapshots and clones work with no keyword.
- `overlay active in TEST mode: ... is untested` -> build not in the table; bind-mount snapshots
  are refused unless opted in (section 5), and `clone overlay loaded but NOT active` -> clone stays
  stock (bind clones refused). See section 5 to get the build vetted.

Optional direct check:

```
perl -e 'require PVE::LXC::Config; require PVE::API2::LXC;
  printf "APPLIED=%d CLONE_APPLIED=%d\n", $PVE::LXC::BindSnap::APPLIED, $PVE::LXC::BindSnap::CLONE_APPLIED'
```

## 3. Decision quick reference

| Situation                                      | Do this                                                            |
|------------------------------------------------|--------------------------------------------------------------------|
| Snapshot a STOPPED bind-mount CT, tested build | Just `pct snapshot <vmid> <name>`                                  |
| Snapshot a RUNNING CT                          | Add `BINDSNAP-FORCE-RUNNING` (section 4)                           |
| Build shows TEST mode / untested               | Opt in with `BINDSNAP-UNSUPPORTED`, then get it vetted (section 5) |
| Keep a managed data disk out of the snapshot   | `BINDSNAP-EXCLUDE: mpN` in CT Notes (section 4)                    |
| Clone a bind-mount CT                          | `pct clone` works; binds are carried (section 6)                   |
| Clone must NOT inherit a bind/data mount       | `BINDSNAP-EXCLUDE: mpN` in the SOURCE CT Notes                     |

## 4. Configure: the BINDSNAP- markers

All UPPERCASE and case-sensitive. The two booleans are read BOTH from a snapshot's name or
description (per-snapshot) AND as a standing line in the CT Notes (its description). They match
as their own token: a hyphen, underscore or space delimits them; gluing onto a letter/digit or
the wrong case does not match.

- **`BINDSNAP-FORCE-RUNNING`** -- snapshot a *running* CT (a running CT is otherwise refused; the
  snapshot briefly freezes the filesystem, which can stall on FUSE/CIFS mounts). Standing form in
  the CT Notes is the opt-in for schedulers that can't set a per-snapshot keyword. No standing risk.
  Example: `pct snapshot 123 pre-change --description "BINDSNAP-FORCE-RUNNING"`.
- **`BINDSNAP-UNSUPPORTED`** -- snapshot on a pve-container build not in the tested table. Prefer
  the per-snapshot form. A **standing** `BINDSNAP-UNSUPPORTED` in the Notes is RISKY: after a PVE
  update to a future untested build it silently covers that too instead of re-gating. Do not leave
  it long-term -- get the build vetted (section 5).
- **`BINDSNAP-EXCLUDE: mp1 mp2`** -- a line in the CT Notes (write it as `#### BINDSNAP-EXCLUDE: mp1`
  so it renders small). ALWAYS needs the colon. A directive in a snapshot's own description
  overrides the Notes default; an empty `BINDSNAP-EXCLUDE:` means exclude nothing. `rootfs` is
  never excluded. NOTE the mirror behaviour: for a SNAPSHOT it drops named MANAGED volumes; for a
  CLONE it drops named BIND/DEVICE mounts.

## 5. Snapshot, and the checksum guard

Stopped CT on a tested build: `pct snapshot <vmid> <name>` (or the GUI). Each snapshot/rollback/
delete writes a summary to the task log. Only bind-mount CTs are gated; plain CTs are untouched.

**What snapshot/rollback does to a bind/device mount -- setting vs data:** only the mount
*setting* (the `mpN`/`devN` config line) is captured in the snapshot and restored on rollback.
The mount is NEVER dropped or lost. The host *data* behind it is never snapshotted, cloned, or
rolled back: a rollback rewinds the managed volumes (rootfs and `volume` disks), but the
bind/device host data stays exactly as it is now, untouched. So a rollback is not a point-in-time
restore of what a bind mount points at -- only managed-volume data is versioned. (Bind data is
host data outside Proxmox storage; stock Proxmox never versions it either.)

The guard is a content checksum of the upstream Proxmox source (two SEPARATE guards: snapshot
hashes `Config.pm`+`AbstractConfig.pm`; clone hashes `API2/LXC.pm`). On an **untested** build,
bind snapshots are refused and clone stays stock. The correct response is NOT to force forever:

1. Opt in once with `BINDSNAP-UNSUPPORTED` to TEST (the task finishes as a yellow `TASK WARNINGS`).
2. Run the test plan: https://github.com/bitranox/pve-bindsnap/blob/main/docs/testing.md
3. Report the version + combined checksum (both printed by the overlay) at
   https://github.com/bitranox/pve-bindsnap/issues so the build joins the known-good list -- after
   which it works with no keyword.

A **known-BAD** build is a hard block: `BINDSNAP-UNSUPPORTED` will NOT override it; update
pve-container or use `zfs snapshot` directly.

## 6. Clone

`pct clone <vmid> <newid>` of a bind-mount CT now works: managed volumes (rootfs and `volume`
`mpN`) clone as stock, and each bind/device mount is **carried to the clone unchanged -- pointing
at the SAME host path as the source** (not a copy). The clone task finishes as a yellow
`TASK WARNINGS` naming the carried mounts, because the two CTs then share that host data.

To stop the clone inheriting a bind/data mount, add `#### BINDSNAP-EXCLUDE: mp0` to the **source**
CT's Notes before cloning. A full clone of a RUNNING CT still needs `--snapname` (Proxmox rule):
snapshot it first with `BINDSNAP-FORCE-RUNNING`, then `pct clone <vmid> <newid> --snapname <snap>`.

## 7. Uninstall

```
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/uninstall.sh | bash
```

Reverts both diverts and restores stock Proxmox. Snapshots you already took persist as zfs
snapshots and in the CT config (`zfs list -t snapshot | grep subvol-<vmid>`).

## Troubleshooting

| Symptom                                                        | Cause / fix                                                                                                                            |
|----------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| Snapshot button greyed for a bind-mount CT                     | Not installed, or daemons not restarted. Install (section 1), verify (section 2).                                                      |
| `unable to clone mountpoint 'mpN' (type bind)`                 | Clone override not active: not installed, OR build untested (clone stays stock). Install / get the build vetted (section 5).           |
| `CT <vmid> is running ... stop ... or BINDSNAP-FORCE-RUNNING`  | Stop the CT, or add `BINDSNAP-FORCE-RUNNING` (section 4).                                                                              |
| `pve-container <ver> is ... untested ... BINDSNAP-UNSUPPORTED` | Build not in the table. Opt in to TEST and get it vetted (section 5).                                                                  |
| `on the overlay's known-BAD list ... BLOCKED`                  | Hard block; update pve-container or use `zfs snapshot`.                                                                                |
| Clone inherited a data mount it should not have                | Add `BINDSNAP-EXCLUDE: mpN` to the SOURCE CT Notes (section 6).                                                                        |
| No `pve-bindsnap:` line in the journal                         | Banner only prints from a PVE daemon (not a TTY). Check `journalctl -u pvedaemon -b`; confirm `$APPLIED`/`$CLONE_APPLIED` (section 2). |

## Further reading

Self-contained above; for depth, read these (WebFetch the URL, or read the local clone if you have it):

| Topic                                      | URL                                                                            |
|--------------------------------------------|--------------------------------------------------------------------------------|
| Overview, install, "Using it"              | https://github.com/bitranox/pve-bindsnap/blob/main/README.md                   |
| How it works, limits, mechanism            | https://github.com/bitranox/pve-bindsnap/blob/main/docs/design.md              |
| The checksum guard, adding a version       | https://github.com/bitranox/pve-bindsnap/blob/main/docs/checksum-guard.md      |
| Supported / hard-blocked / untested builds | https://github.com/bitranox/pve-bindsnap/blob/main/docs/compatible-versions.md |
| BINDSNAP-EXCLUDE in depth                  | https://github.com/bitranox/pve-bindsnap/blob/main/docs/bindsnap-exclude.md    |
| On-node test plan                          | https://github.com/bitranox/pve-bindsnap/blob/main/docs/testing.md             |
