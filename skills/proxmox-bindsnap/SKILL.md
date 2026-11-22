---
name: proxmox-bindsnap
description: Use when snapshotting or cloning Proxmox LXC containers that have bind/device mounts (mpN -> host paths) - the snapshot button is greyed out or pct snapshot refuses the container with "snapshot feature is not available", or pct snapshot exits 255 with "snapshot gated -- pve-container X is untested", or pct clone fails with "unable to clone mountpoint 'mpN' (type bind)" or "only allowed for root@pam", or you cannot snapshot a bind-mount container. Covers pve-bindsnap install, verify, the BINDSNAP-FORCE-RUNNING / BINDSNAP-UNSUPPORTED / BINDSNAP-EXCLUDE markers, the checksum guard for an untested pve-container build, clone, and uninstall on a Proxmox VE node.
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

- A container with a bind mount can't be snapshotted: the GUI button is greyed out, or
  `pct snapshot` fails with `snapshot feature is not available` (exit 255), running or stopped,
  and creates nothing.
- `pct clone` / GUI Clone fails: `unable to clone mountpoint 'mpN' (type bind)`.
- You need scheduled snapshots of bind-mount CTs (e.g. cv4pve-autosnap).
- You want to clone a bind-mount CT and control whether the copy inherits the bind mounts.

**Not for:** containers without bind/device mounts (they already snapshot/clone stock -- the
overlay never touches them). If you need a snapshot of a CT whose managed volumes are ALL on ZFS,
and not the GUI/scheduler, a plain `zfs snapshot` of every one of them (inside `lxc-freeze` for a
running CT) is simpler and needs none of this (how, and what it costs: section 5, "A safety
snapshot NOW").

## 1. Install

Two ways; both install the same overlay, clone variants and two diverts (the package keeps the
module in `/usr/share/perl5`, the script in `/usr/local/lib/site_perl`). **Prefer the apt package** when the node should keep
pve-bindsnap current through Proxmox's own updates (GUI Node -> Updates, or `apt-get upgrade`):

```
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install-apt.sh | bash
```

It adds the signed pve-bindsnap repository (key fingerprint
`1445 C598 166A 481A C529  2FE1 A5A5 351D 2BC8 8FDC`, trusted for that repository only) and
installs the `pve-bindsnap` package. On a node installed by `install.sh`, run it as is, WITHOUT
uninstalling first: the package takes that installation over. Options: `--no-install` (only add
the repository), `--remove` (remove the repository and its key, keep the package), `--purge`
with `--remove` (also purge the package), `--repo-url URL` (a mirror or test repository instead
of the GitHub release one); piped from curl they go after
`bash -s --` (`... install-apt.sh | bash -s -- --remove --purge`). While the package is installed,
`install.sh` and `uninstall.sh` refuse; use apt. Details:
https://github.com/bitranox/pve-bindsnap/blob/main/docs/install-apt.md

**Or the script**, updated by re-running it. The model is "read the source, then install from
it." Inspect first:

```
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install.sh | less
```

Then install (one node; idempotent; restarts pvedaemon/pveproxy/pvestatd):

```
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install.sh | bash
```

Or clone and run locally: `git clone https://github.com/bitranox/pve-bindsnap && cd pve-bindsnap && less install.sh && ./install.sh`.

It installs the overlay module and its clone variants to `/usr/local/lib/site_perl`, adds two dpkg-diverts (Config.pm
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
  are refused unless opted in (sections 4 and 5), and `clone overlay loaded but NOT active` -> clone stays
  stock (bind clones refused). See section 5 to get the build vetted.

Optional direct check:

```
perl -e 'require PVE::LXC::Config; require PVE::API2::LXC;
  printf "APPLIED=%d CLONE_APPLIED=%d\n", $PVE::LXC::BindSnap::APPLIED, $PVE::LXC::BindSnap::CLONE_APPLIED'
```

## 3. Decision quick reference

| Situation                                      | Do this                                                                                              |
|------------------------------------------------|------------------------------------------------------------------------------------------------------|
| Snapshot a STOPPED bind-mount CT, tested build | Just `pct snapshot <vmid> <name>`                                                                    |
| Snapshot a RUNNING CT                          | Add `BINDSNAP-FORCE-RUNNING` (section 4)                                                             |
| Safety net NOW, stopped CT, all volumes on ZFS | Raw `zfs snapshot` of every managed volume (section 5)                                               |
| Safety net NOW, running CT, all volumes on ZFS | `lxc-freeze`, ONE `zfs snapshot` of every managed volume, `lxc-unfreeze` (section 5)                 |
| Safety net NOW, a managed volume not on ZFS    | `vzdump <vmid> --storage <store>`, snapshot mode, `backup=1` on each `mpN` (section 5)               |
| Build shows TEST mode / untested               | Opt in with `BINDSNAP-UNSUPPORTED`, then get it vetted (section 5)                                   |
| Keep a managed data disk out of the snapshot   | `BINDSNAP-EXCLUDE: mpN` in CT Notes (section 4)                                                      |
| Clone a bind-mount CT                          | As `root@pam` (a root API token counts as another user); others need every bind excluded (section 6) |
| Clone must NOT inherit a bind/data mount       | `BINDSNAP-EXCLUDE: mpN` in the SOURCE CT Notes; for `--snapname`, there BEFORE the snapshot          |

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

**A safety snapshot NOW, on a build the guard refuses.** On an untested build `pct snapshot` of a
bind-mount CT exits 255 with `pve-bindsnap: snapshot gated -- pve-container <ver> is untested`,
then `add BINDSNAP-UNSUPPORTED or update pve-container` (a known-BAD build says
`snapshot BLOCKED`). The refusal comes before any snapshot is taken, so it leaves no ZFS snapshot
or config entry behind. The gate covers creating a snapshot only: `pct delsnapshot` (CT running
or stopped) and `pct rollback` (which stops the CT itself) of a snapshot that already exists run
on any build. Two routes run no overlay snapshot code at all; offer them before
`BINDSNAP-UNSUPPORTED`. The refusal and its exit code are the overlay's (seen on
pve-container 6.1.20 with overlay 1.4.1); the ZFS and Proxmox behaviour below is from their
documentation and source, except the running-CT script, which was run on a test node.

- **Raw ZFS snapshot: a CT whose managed volumes are all on ZFS, stopped or running.** Instant,
  and so is its rollback, which needs the CT stopped whichever way the snapshot was taken. Check
  that it applies first:
  1. `pct status <vmid>`: `stopped` takes steps 2 to 5 below by hand; `running` takes the script
     under "A RUNNING CT", which does steps 2 to 5 with the CT frozen.
  2. `pct config <vmid>`: each `rootfs` or `mpN` value starting with `/` is a bind mount and each
     `devN` a device; both are host data and in no snapshot either way (snapshot a bind source
     yourself on the host if its data must be kept too). Every other `rootfs`/`mpN` is a managed
     volume `<storage>:<volume>`, and `pvesm status` must show each such storage with type
     `zfspool`. One on `lvmthin`, `dir`, `nfs`, `rbd` or any other type is not covered by this
     route: use `vzdump`.
  3. Map each managed volume to its dataset, the same way the running-CT script does:
     `zfs list -H -o name "$(pvesm path <storage>:<volume>)"` prints it, usually
     `<pool>/subvol-<vmid>-disk-N`.
  4. Snapshot ALL of them in one command, with one name no later `pct snapshot` will use (a
     second snapshot of the same name on a dataset is refused). A rootfs-only snapshot misses
     every `mpN` volume:
     `zfs snapshot <pool>/subvol-<vmid>-disk-0@<name> <pool>/subvol-<vmid>-disk-1@<name>`
  5. Save the CT config, which no ZFS snapshot holds:
     `cp /etc/pve/lxc/<vmid>.conf /root/<vmid>.conf.<name>`

  **A RUNNING CT:** stock `pct snapshot` of a running CT freezes it (cgroup freezer), snapshots
  each volume and thaws it; for ZFS it adds no filesystem freeze. This script does the same
  without the overlay's gate. Save it on the node as `freeze-snapshot.sh` and run
  `bash freeze-snapshot.sh <vmid> <name>` there, as ONE command. From a shell inside the CT
  itself, copy the script to the node, then start it with ONE ssh call:
  `scp freeze-snapshot.sh root@<node>:`, then
  `ssh root@<node> bash freeze-snapshot.sh <vmid> <name>`. Never split the script into
  separate calls: once the CT is frozen, a session inside it cannot send the next one, and only
  the trap thaws it.

  ```bash
  #!/bin/bash
  set -euo pipefail
  vmid=${1:?usage: freeze-snapshot.sh <vmid> <name>}
  snap=${2:?usage: freeze-snapshot.sh <vmid> <name>}
  # Managed volumes only: a bind mount's source is a host path starting with '/'.
  datasets=()
  while read -r vol; do
      path=$(pvesm path "$vol")
      ds=$(zfs list -H -o name "$path") || { echo "not on ZFS: $vol" >&2; exit 2; }
      datasets+=("$ds@$snap")
  done < <(pct config "$vmid" | sed -n -E 's/^(rootfs|mp[0-9]+): ([^,]+).*/\2/p' | grep -v '^/')
  [ "${#datasets[@]}" -gt 0 ] || { echo "no managed volume found" >&2; exit 2; }
  cp "/etc/pve/lxc/$vmid.conf" "/root/$vmid.conf.$snap"
  trap 'lxc-unfreeze -n "$vmid"' EXIT
  lxc-freeze -n "$vmid"
  zfs snapshot "${datasets[@]}"
  echo "snapshot: ${datasets[*]}"
  ```

  What the freeze buys, and what it does not:
  - Every process in the CT stops between system calls, and all volumes are taken in one
    `zfs snapshot`, so they agree with each other at one instant. A program's own multi-step
    update is not made whole: on a test node a writer that truncated a file and then wrote it
    (`echo $i > file`) was caught with that file EMPTY, while one that wrote a temp file and
    renamed it was caught complete, with the same counter on both volumes. Data a program holds
    only in memory is not in the snapshot. That is crash-consistent, like a power cut; stop or
    quiesce the application first when that is not enough.
  - The freeze can stall on a CT with FUSE or CIFS mounts, the same risk as
    `BINDSNAP-FORCE-RUNNING` (section 4).
  - A name already used on any of the datasets makes `zfs snapshot` create nothing at all, and
    the trap still thaws the CT and the script exits non-zero. The config copy is written
    before the snapshot and overwrites one saved under the same name, so use a new name each
    time.
  - On the test node (pve-container 6.1.24, rootfs plus one volume `mp1`, a writer running) the
    CT read `FROZEN` during the snapshot and `RUNNING` after, the writer went on after the thaw,
    and stopping the CT, `zfs rollback` of each volume and starting it restored the snapshot
    state.

  What a raw snapshot costs, stopped or running: Proxmox does not know about it. It is not in
  `pct listsnapshot` or the GUI, and `pct rollback` / `pct delsnapshot` cannot reach it. Roll
  back with `pct stop <vmid>`, then `zfs rollback <pool>/subvol-<vmid>-disk-N@<name>` for EVERY
  dataset you snapshotted (the script prints them), copy the
  saved config back if `diff /root/<vmid>.conf.<name> /etc/pve/lxc/<vmid>.conf` shows the change
  edited it, and `pct start <vmid>`. `zfs rollback` refuses while a newer snapshot of that dataset
  exists (list them: `zfs list -H -t snapshot -o name | grep '/subvol-<vmid>-disk-'`); `-r` goes
  through by destroying them, including any a later `pct snapshot` took, whose entries then stay
  in the CT config with no data behind them. In the other direction, Proxmox rolls a ZFS volume
  back only to its most recent snapshot, so while the raw snapshot exists a `pct rollback` to an
  older Proxmox snapshot of that CT is refused. Destroy it when you are done with it:
  `zfs destroy <pool>/subvol-<vmid>-disk-N@<name>`.
- **`vzdump`: any storage, running or stopped.** See "A pre-change safety net on a build the
  guard refuses" below; it is a full backup, so going back is a restore, not an instant rollback.
  It skips every managed `mpN` that lacks `backup=1`, so check that first (same paragraph).

The guard is a content checksum of the upstream Proxmox source (two SEPARATE guards: snapshot
hashes `Config.pm`+`AbstractConfig.pm`; clone hashes `API2/LXC.pm`). On an **untested** build,
bind snapshots are refused and clone stays stock. The correct response is NOT to force forever:

1. Opt in once with `BINDSNAP-UNSUPPORTED` to TEST (the task finishes as a yellow `TASK WARNINGS`).
2. Run the test plan: https://github.com/bitranox/pve-bindsnap/blob/main/docs/testing.md
3. Report the version + combined checksum (both printed by the overlay) at
   https://github.com/bitranox/pve-bindsnap/issues so the build joins the known-good list -- after
   which it works with no keyword.

Which builds count as vetted is decided by the overlay, not from memory: the journal line in
section 2 tells you about THIS node's build, and
https://github.com/bitranox/pve-bindsnap/blob/main/docs/compatible-versions.md is the
authoritative list for both guards. Read the builds off that page, never from a range quoted
elsewhere: each row names the pve-container build(s) together with the `libpve-guest-common-perl`
version it was vetted with.
The pairing matters because the snapshot checksum also covers `AbstractConfig.pm`, which ships in
`libpve-guest-common-perl` rather than in `pve-container`, so an apt upgrade of EITHER package
can move a node into TEST mode. The reverse holds too: a build newer than the top of that list is
not untested on that ground alone. The overlay keys on the checksum of the guarded files, never on
the version, so a later build whose guarded files did not change validates as `checksum-validated`,
each guard on its own, with no new row. Judge a node from its journal line, never by comparing its
version with the list. The page can also list rows the node's INSTALLED pve-bindsnap release does
not hold yet; the node accepts only what its installed release holds, so update pve-bindsnap
(section 1: `apt-get upgrade` for the package, re-run `install.sh` for the script) to pick them up.

A **known-BAD** build is a hard block: `BINDSNAP-UNSUPPORTED` will NOT override it; update
pve-container (and libpve-guest-common-perl, whose `AbstractConfig.pm` the snapshot checksum also
covers) or use `zfs snapshot` directly.

**A pre-change safety net on a build the guard refuses:** take a stock backup,
`vzdump <vmid> --storage <store>`. The overlay passes every `vzdump` call straight to stock code
on any build, tested, untested or known-BAD, and stock `vzdump` leaves bind and device mounts out
of the archive (their data is host data, outside Proxmox storage) and backs up only the rootfs and
the `volume` mount points marked `backup=1`. That flag is OFF unless set: a managed `mpN` line in
`pct config <vmid>` without `backup=1` is not in the archive, so a backup taken as a safety net
for a data volume (a database on `mp1`) silently holds none of that data. Check every managed
`mpN` line BEFORE the backup, and set the flag on each one that must be kept by repeating its
current value exactly and adding only `backup=1`:
`pct set <vmid> -mpN <the current mpN value>,backup=1`. On a running CT that change applies at
once, because `backup` is one of the options stock code changes live; if anything else in the
value differs, the change stays pending until the CT restarts, which `pct pending <vmid>` shows.
The task log then names each volume: `including mount point mpN ('<path>') in backup` for one it
keeps, and `excluding volume mount point mpN ('<path>') from backup (disabled)` for one without
the flag (a bind mount reads `excluding bind mount point ... (not a volume)`). A volume you need
that the log excludes means no safety net for it: set the flag and run the backup again. vzdump
needs no marker and no raw `zfs snapshot`. On a running CT, `--mode snapshot` is crash-consistent,
the same as the freeze route: vzdump names its temporary snapshot `vzdump`, which the overlay hands
to stock code, and stock code freezes the CT, snapshots each volume and thaws it. If a backed-up
volume's storage cannot snapshot, vzdump falls back to `--mode suspend`. So the choice between
the two is not consistency: the freeze route is quick and rolls back in place but needs every
managed volume on ZFS; a vzdump archive is slower, covers any storage and restores with
`pct restore`. Going back to it over the same CT: `pct stop <vmid>`, then
`pct restore <vmid> <archive> --force 1`, with `<archive>` the volume ID that
`pvesm list <store> --vmid <vmid>` lists (a running CT is refused with
`can't overwrite running container`). The restore leaves the CT stopped; `pct start <vmid>`
brings it back. Keep the default `--mode snapshot`; `--mode stop` stops the container for the
backup and starts it again, which re-runs everything the container does at boot. A boot unit
that pulls and recreates its containers then performs, before you are ready, the very change the
backup was meant to precede.

## 6. Clone

`pct clone <vmid> <newid>` of a bind-mount CT now works, run as `root@pam`: managed volumes (rootfs
and `volume` `mpN`) clone as stock, and each bind/device `mpN` is **carried to the clone unchanged
-- pointing at the SAME host path as the source** (not a copy). The clone task finishes as a yellow
`TASK WARNINGS` naming the carried mounts, because the two CTs then share that host data. Otherwise
the clone behaves exactly as the node's own Proxmox clone does: the override runs that build's own
upstream `clone_vm` with only the bind-mount change applied (one shipped variant per upstream
version; the journal's `clone overlay active` line names it, e.g. `clone_vm variant v6_1_7`).
A `devN` passthrough line is copied by Proxmox's own clone code for any user, as on stock; the
overlay does not touch it and `BINDSNAP-EXCLUDE` cannot drop it.

Only `root@pam` can carry a bind/device mount, because Proxmox lets no other user set one; the
clone applies the same test as setting one, so whoever may set a bind mount may carry it. A
`root@pam` API token (`root@pam!<token>`) fails that test like any other user. Any other user's
clone, through the GUI or the API, creates nothing (no clone task starts; the error comes back
from the call itself) and stops with:

```
unable to clone mountpoint 'mp0' (type bind) -- carrying a bind/device mount to a clone is only allowed for root@pam
```

Two ways on: clone as `root@pam` (`pct clone` on the node always runs as `root@pam`), or exclude
every bind/device mount; an exclusion is honoured whoever clones (only writing it into the Notes
needs the right to edit them), so that user's clone then goes through.

A CT whose **rootfs** is a bind/device mount (`rootfs: /some/host/dir`) is never cloned, not even
by `root@pam`, active overlay or not: the clone would share the source's root filesystem. It
fails with Proxmox's own `unable to clone mountpoint 'rootfs' (type bind)`, creates nothing, and
pve-bindsnap has no route around it.

To stop the clone inheriting a bind/data mount, add `#### BINDSNAP-EXCLUDE: mp0` to the **source**
CT's Notes before cloning. A full clone of a RUNNING CT still needs `--snapname` (Proxmox rule):
snapshot it first with `BINDSNAP-FORCE-RUNNING`, then `pct clone <vmid> <newid> --snapname <snap>`.
A `--snapname` clone reads the directive frozen into THAT snapshot, not the current Notes: put
the line in the Notes BEFORE taking the snapshot, or in the description given when taking it
(it replaces the Notes default). Never add it to an existing snapshot's description: delete and
rollback read that line too. A managed `mpN` that snapshot excluded has no snapshot data, so the
clone leaves it out and says so in a `TASK WARNINGS`.

## 7. Uninstall

First delete or roll back any bind-mount CT snapshot you still need to act on: once the overlay
is gone, stock Proxmox cannot delete or roll back a snapshot that holds a bind mount (it hits the
bind path and dies). Reinstalling pve-bindsnap brings that back.

Installed with apt: `curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install-apt.sh | bash -s -- --remove --purge` (purges the package and
removes the repository), or `apt-get purge pve-bindsnap` to keep the repository. Installed with the script:

```
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/uninstall.sh | bash
```

Each of these reverts both diverts and restores stock Proxmox. Snapshots you already took persist as zfs
snapshots and in the CT config (`zfs list -t snapshot | grep subvol-<vmid>`).

## Troubleshooting

| Symptom                                                                                | Cause / fix                                                                                                                                                                                                                       |
|----------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Snapshot button greyed for a bind-mount CT                                             | Not installed, or daemons not restarted. Install (section 1), verify (section 2).                                                                                                                                                 |
| `pct snapshot`: `snapshot feature is not available`                                    | CLI form of the greyed button: not installed, or daemons not restarted. Install (section 1), verify (section 2).                                                                                                                  |
| `unable to clone mountpoint 'mpN' (type bind\|device)`, nothing after (never `rootfs`) | Clone override not active: not installed, OR build untested (clone stays stock). Install / get the build vetted (section 5).                                                                                                      |
| `... (type bind\|device) -- ... only allowed for root@pam`                             | Overlay active; the caller is not `root@pam` (a root API token counts as another user). Clone as `root@pam`, or `BINDSNAP-EXCLUDE` every bind/device mount; for `--snapname`, the directive must be in that snapshot (section 6). |
| `unable to clone mountpoint 'rootfs' (type bind)`                                      | The CT's rootfs is a host directory. Never cloned, on any build and for any user (section 6).                                                                                                                                     |
| `CT <vmid> is running ... stop ... or BINDSNAP-FORCE-RUNNING`                          | Stop the CT, or add `BINDSNAP-FORCE-RUNNING` (section 4).                                                                                                                                                                         |
| `snapshot gated -- pve-container <ver> is untested`                                    | Build not in the table. Safety net now: raw `zfs snapshot` or `vzdump` (section 5); else opt in to TEST and get it vetted.                                                                                                        |
| `on the overlay's known-BAD list ... BLOCKED`                                          | Hard block; update pve-container (and libpve-guest-common-perl) or use `zfs snapshot`.                                                                                                                                            |
| Clone inherited a data mount it should not have                                        | Add `BINDSNAP-EXCLUDE: mpN` to the SOURCE CT Notes; a `--snapname` clone needs it there before the snapshot was taken (section 6).                                                                                                |
| No `pve-bindsnap:` line in the journal                                                 | Banner only prints from a PVE daemon (not a TTY). Check `journalctl -u pvedaemon -b`; confirm `$APPLIED`/`$CLONE_APPLIED` (section 2).                                                                                            |

## Further reading

Self-contained above; for depth, read these (WebFetch the URL, or read the local clone if you have it):

| Topic                                      | URL                                                                            |
|--------------------------------------------|--------------------------------------------------------------------------------|
| Overview, install, "Using it"              | https://github.com/bitranox/pve-bindsnap/blob/main/README.md                   |
| Apt repository, package, key, migration    | https://github.com/bitranox/pve-bindsnap/blob/main/docs/install-apt.md         |
| How it works, limits, mechanism            | https://github.com/bitranox/pve-bindsnap/blob/main/docs/design.md              |
| The checksum guard, adding a version       | https://github.com/bitranox/pve-bindsnap/blob/main/docs/checksum-guard.md      |
| Supported / hard-blocked / untested builds | https://github.com/bitranox/pve-bindsnap/blob/main/docs/compatible-versions.md |
| BINDSNAP-EXCLUDE in depth                  | https://github.com/bitranox/pve-bindsnap/blob/main/docs/bindsnap-exclude.md    |
| On-node test plan                          | https://github.com/bitranox/pve-bindsnap/blob/main/docs/testing.md             |
