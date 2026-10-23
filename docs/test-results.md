# Test results

Verification of the current module, off the node and on a test node. This page reflects
the latest run; the test plan that produces it is in [testing.md](testing.md).

## Off the node

`perl -c` clean (both `BindSnap.pm` and `API2/LXC.wrapper.pm`), `prove -I lib t/` =
**285 tests pass**, `shellcheck` and `shfmt` clean.
The unit tests cover the pure logic: the checksum combine (it reproduces both the
documented `sha256sum` pipeline and the real value from a node), the `BINDSNAP-FORCE-RUNNING`/
`BINDSNAP-UNSUPPORTED` matching (case-sensitive, underscore-glue tolerant, read from the
snapshot fields *and* as a standing CT-Notes directive), the `BINDSNAP-EXCLUDE` parsing (the
undef-vs-empty override semantics, the colon requirement, and the mpN-only / rootfs-never
rules), the bind/device-mount detection and categorisation, the refusal messages, and the
task-log summaries (including the standing-`BINDSNAP-UNSUPPORTED` risk note). A wiring test
(`t/07-apply-wiring.t`) stubs the PVE method surface and drives the redefined
`snapshot_create`/`delete`/`rollback`/`has_feature` and the `_make_filter` closure
off-node, so the typeglob wiring, the gates, and the bind/exclude filtering are covered
in CI, not only on a live node. A clone wiring test (`t/08-clone-wiring.t`) covers the
pure carry/exclude decision (`_clone_disposition`), the `apply_clone` idempotency and
TEST-mode fall-through (no override on an unvalidated build), and the `map_method_by_name`
override mechanism.

## On a test node

Proxmox VE 9.2, pve-container **6.1.10** (combined checksum `1ebb1a44...faa6106`, in the
known-good table -> **validated mode**). The complete install lifecycle was exercised:
`uninstall.sh` restored stock cleanly (divert reverted, `dpkg --verify pve-container`
silent), then `install.sh` pre-flighted the load and reinstalled, with the activation
banner reading `running CT => stop or BINDSNAP-FORCE-RUNNING`.

**Installer rollback** was fault-injected (a forced failure right after the divert, the
window between `dpkg-divert` and the pre-flight): the EXIT-trap rollback restored stock,
divert reverted, the genuine `Config.pm` back, the module removed, `PVE::LXC::Config`
loads, and the daemons were never touched (same PID). A clean first install and an
idempotent re-run both completed without any spurious rollback. **PASS.**

A throwaway, privileged CT was given managed volumes (`mp1`->`disk-1` `/data1`,
`mp2`->`disk-2` `/data2`) and bind mounts (`mp3`->`/bind3`, `mp4`->`/bind4`), then restored
to its original rootfs-only config afterward. Disk legend: **0** = rootfs, **1** = mp1,
**2** = mp2. A successful snapshot of this CT also proves the bind mounts were dropped
(stock Proxmox would have refused them).

### Create / rollback / delete (stopped)

Snapshot captured **0 1 2** (zfs `@base1` on disk-0/1/2) and skipped the binds; the
task-log summary read `kept rootfs, mp1, mp2; skipped mp3, mp4 (bind/device)`. Rollback
reverted 0 1 2 and left the binds untouched; delete removed 0 1 2; the CT was clean
afterward. **PASS.**

### Running CT: `BINDSNAP-FORCE-RUNNING`

| case                                                       | result                                                                              |
|------------------------------------------------------------|-------------------------------------------------------------------------------------|
| running, no marker                                         | **refused**, full multi-line block in the task Output, one-line `TASK ERROR` (PASS) |
| `--description "BINDSNAP-FORCE-RUNNING ..."`               | proceeds (fs-freeze); summary `: used`; keyword kept in the stored comment (PASS)   |
| `--description "auto_BINDSNAP-FORCE-RUNNING_2026"`         | proceeds, underscore-glued keyword matches (PASS)                                   |
| standing `#### BINDSNAP-FORCE-RUNNING` in Notes, no marker | proceeds; summary `: standing`, the automated-tool (cv4pve-autosnap) path (PASS)    |

### `BINDSNAP-EXCLUDE` resolution

All cases matched expectation and `delsnapshot` succeeded for each (delete honours the
frozen directive; it round-trips through Proxmox's URL-encoding, `BINDSNAP-EXCLUDE%3A mp1`).

| CT Notes directive               | snapshot description    | captured | result                 |
|----------------------------------|-------------------------|----------|------------------------|
| (none)                           | (none)                  | 0 1 2    | PASS                   |
| `BINDSNAP-EXCLUDE: mp1`          | (none)                  | 0 2      | PASS                   |
| `BINDSNAP-EXCLUDE: mp1 mp2`      | (none)                  | 0        | PASS                   |
| `BINDSNAP-EXCLUDE: mp1`          | `BINDSNAP-EXCLUDE: mp2` | 0 1      | PASS                   |
| `BINDSNAP-EXCLUDE: mp1`          | `BINDSNAP-EXCLUDE:`     | 0 1 2    | PASS                   |
| (none)                           | `BINDSNAP-EXCLUDE: mp2` | 0 1      | PASS                   |
| `BINDSNAP-EXCLUDE: rootfs mp1`   | (none)                  | 0 2      | PASS                   |
| `BINDSNAP-EXCLUDE_ mp1` (no `:`) | (none)                  | 0 1 2    | PASS (not a directive) |
| `BINDSNAP-EXCLUDE: mp1`          | `BINDSNAP-EXCLUDE:_`    | 0 1 2    | PASS (empty override)  |

### `BINDSNAP-UNSUPPORTED` (untested build, simulated by emptying the known-good table)

| case                                            | result                                                                                |
|-------------------------------------------------|---------------------------------------------------------------------------------------|
| no marker                                       | **refused**, version, checksum, tested-good list, compat link (PASS)                  |
| per-snapshot `BINDSNAP-UNSUPPORTED`             | proceeds; summary `: used` (PASS)                                                     |
| standing `BINDSNAP-UNSUPPORTED`, build untested | proceeds; summary `: STANDING (risky)` warns it covers a future untested build (PASS) |
| standing `BINDSNAP-UNSUPPORTED`, build tested   | summary `: not needed now ... consider removing it` (dormant latent risk) (PASS)      |

### Known-BAD (deny-list, hard block)

Simulated by adding the node's checksum to `%KNOWN_BAD_CHECKSUMS`. No marker -> **BLOCKED**
(version, checksum, reason, tested-good builds); with `BINDSNAP-UNSUPPORTED` -> **still
BLOCKED** (the deny-list is not overridable); no zfs snapshot leaked. **PASS.**

### Rollback (data level)

Wrote `v1` into the rootfs, `/data1` (mp1, managed) and `/bind3` (mp3, bind); snapshotted;
changed every marker to `v2`; rolled back; re-read:

| volume                 | after rollback | result |
|------------------------|----------------|--------|
| rootfs                 | `v1`           | PASS   |
| mp1 `/data1` (managed) | `v1`           | PASS   |
| mp3 `/bind3` (bind)    | `v2`           | PASS   |

The captured managed volumes revert; the bind (never captured) keeps its later change.

### vzdump, normal CT, banner

- `vzdump --mode snapshot` ran straight through to stock and **finished successfully**
  (stock excluded the bind mounts from the backup). The backup path is untouched. **PASS.**
- A **normal CT** (managed volumes, no bind/device mounts) got the summary
  `no bind/device mounts -- overlay made no change` with the gates `n/a`: the overlay did
  not engage and delegated to stock. **PASS.**
- The routine load **banner is suppressed on a TTY** (0 lines via an interactive `pct`)
  and present on the non-TTY journal path. **PASS.**

## Clone support

On proxmox06 (PVE 9.2, pve-container **6.1.10**; `API2/LXC.pm` combined checksum
`8408885e...525198`, in the clone known-good table -> the clone override is **active**),
verified the full `pct clone` matrix with a throwaway alpine CT (1G rootfs on local-zfs,
two bind mounts: `mp0`->`/data`, `mp1`->`/extra`):

- **Baseline (override not yet installed):** `pct clone` died with
  `unable to clone mountpoint 'mp0' (type bind)` (exit 2) -- the bug. **Reproduced.**
- After `install.sh` (second divert of `API2/LXC.pm` added; both pre-flights passed; the
  journal banner read `clone overlay active (... checksum-validated ...)`):
  - **Carry:** `pct clone 9001 9002` succeeded. The clone got a NEW full-clone rootfs
    (`subvol-9002-disk-0`) and **both bind mounts carried unchanged** (same host paths).
    **PASS.**
  - **Boots + binds functional:** the clone runs (booted without networking, since the
    test host lacks veth support -- the *source* CT fails to boot identically, confirming
    that limitation is environmental, not the clone). Inside the clone, `/data/marker.txt`
    read back the host file and `/extra` was present, so the carried binds mount. A write
    to the clone's rootfs confirmed it is the independent cloned volume. **PASS.**
  - **`BINDSNAP-EXCLUDE`:** with `#### BINDSNAP-EXCLUDE: mp1` in the source CT Notes,
    `pct clone 9001 9003` carried `mp0` but **dropped `mp1`**. **PASS.**
- The clone override is gated by its own checksum: on a non-validated build it is not
  installed and `pct clone` keeps stock behaviour (binds rejected), so there is no
  regression. Confirmed in-process under `perl -T`: `apply_clone` installs the override
  only when the `API2/LXC.pm` checksum matches.

## pve-container 6.1.12

Validation run that added `6.1.12` to both known-good tables, on a Proxmox VE 9.2.6 node
(pve-container **6.1.12**, libpve-guest-common-perl 6.0.5; snapshot combined checksum
`29dc5ce7...1bce914f`, clone checksum `1ace1c4d...f7e7afc7` (the whole-file hash used
through 1.3.0; from 1.4.0 the clone guard hashes the `clone_vm` block,
`7a10c90b...58aa56c8`, identical for 6.1.10-6.1.14)). A throwaway unprivileged CT carried
one bind mount (`mp0` -> a host dir) and one managed volume (`mp1` ->
`subvol-<vmid>-disk-1`).

**Source review first.** Diffing the 6.1.10 and 6.1.12 package files showed the wrapped
surface is unchanged: in `LXC/Config.pm` the only changes are the new `with_checked_volid`
helper and its use in `vmconfig_hotplug_pending`/`vmconfig_apply_pending`/
`apply_pending_mountpoint` plus `calculate_memory_constraints`, none of them on the
snapshot path (`foreach_volume_full`, `snapshot_create`/`delete`/`rollback`, `has_feature`);
in `API2/LXC.pm` the single change is an added `VM.PowerMgmt` check in `create_vm`, so the
`clone_vm` body the overlay copies is byte-identical to 6.1.10.

**Before the tables were extended** (the build read as untested): a bind-mount snapshot was
refused with the full multi-line block; `BINDSNAP-UNSUPPORTED` let it through as
`TASK WARNINGS`; `BINDSNAP-FORCE-RUNNING` was still required for the running CT; and
`pct clone` fell back to the stock `unable to clone mountpoint 'mp0' (type bind)`, since the
clone override is not installed on an unvalidated build. **PASS.**

**After both checksums were added** (both banners read `checksum-validated`), with no
keyword anywhere except where one is by design:

| case                                                     | result                                                                           |
|----------------------------------------------------------|----------------------------------------------------------------------------------|
| stopped bind CT, no keyword                              | snapshot captured rootfs + mp1, skipped mp0, `TASK OK` (PASS)                    |
| rollback, data level                                     | rootfs marker reverted, bind host file kept its post-snapshot change (PASS)      |
| delete                                                   | removed rootfs + mp1, bind untouched, no zfs snapshot left (PASS)                |
| running CT, no keyword                                   | refused, one-line `TASK ERROR` plus the full block (PASS)                        |
| running CT, `BINDSNAP-FORCE-RUNNING`                     | proceeds with freeze/thaw; summary `: used` (PASS)                               |
| running CT, standing directive in Notes                  | proceeds; summary `: standing` (PASS)                                            |
| `BINDSNAP-EXCLUDE: mp1` in Notes                         | rootfs captured, `subvol-...-disk-1@excl1` absent (PASS)                         |
| snapshot description `BINDSNAP-EXCLUDE:`                 | empty override, mp1 captured again (PASS)                                        |
| `pct clone` of the stopped bind CT                       | rootfs + mp1 full-cloned, mp0 carried, yellow carry warning (PASS)               |
| `pct clone` with `BINDSNAP-EXCLUDE: mp0` in source Notes | mp0 absent from the clone config (PASS)                                          |
| snapshot of a CT without bind mounts                     | summary `no bind/device mounts -- stock snapshot, overlay made no change` (PASS) |
| `vzdump --mode snapshot`                                 | ran through to stock and finished successfully (PASS)                            |

The test CT and both clones were destroyed afterward, with no leftover datasets, zfs
snapshots, dump files or bind directories.

## pve-container 6.1.14

Source review that added `6.1.14` to both known-good tables (pve-container **6.1.14**,
libpve-guest-common-perl 6.0.5; snapshot combined checksum `04aada64...9e225a77`, clone
checksum `2ea44bdd...a43b635a` (the whole-file hash used through 1.3.0; from 1.4.0 the clone
guard hashes the `clone_vm` block, `7a10c90b...58aa56c8`, identical for 6.1.10-6.1.14)).

**Checksum provenance.** The values were computed from the published
`pve-container_6.1.14_all.deb` and `libpve-guest-common-perl_6.0.5_all.deb` on
`download.proxmox.com` (trixie, pve-no-subscription), with the same pipelines the overlay
logs. Run over the published `pve-container_6.1.12_all.deb`, that method reproduces the
6.1.12 entries exactly (`29dc5ce7...1bce914f` and `1ace1c4d...f7e7afc7`, the 1.3.0
whole-file clone hash), so it matches what a node computes. libpve-guest-common-perl is
still at 6.0.5, so `AbstractConfig.pm` is the same `70432cce...61871494` as in the 6.1.12
pair.

**Source diff 6.1.12 -> 6.1.14.** The wrapped surface is unchanged:

- `LXC/Config.pm`: the `entrypoint` and `env` option patterns gain a `\z`
  anchor, and `write_pct_config` rejects CR as well as LF in rendered values, now also in
  the `env` entries and raw `lxc.*` keys. None of it is on the snapshot path
  (`foreach_volume_full`, `snapshot_create`/`delete`/`rollback`, `has_feature`). The
  description, where the overlay freezes a `BINDSNAP-EXCLUDE` line into the snapshot
  comment, is still written as encoded `#` comment lines and is not subject to the new check.
- `API2/LXC.pm`: the single change is an added `check_protection` on the target CT in
  `move_volume` (upstream fix #7148). The `clone_vm` method definition is byte-identical to
  6.1.12 (418 lines, `cmp` clean), so the body the overlay copies still matches.

**On the node.** On a three-node Proxmox VE 9.2.20 cluster (pve-container 6.1.14,
libpve-guest-common-perl 6.0.5), every node computes both entries from its installed files:
the combined snapshot checksum `04aada64...9e225a77` and the clone checksum
`2ea44bdd...a43b635a`, plus the `clone_vm` block checksum `7a10c90b...58aa56c8` that 1.4.0
uses. The 1.4.0 run on that cluster is below.

## 1.4.0 on a live cluster (pve-container 6.1.14)

Three Proxmox VE 9.2.20 nodes (pve-container 6.1.14, libpve-guest-common-perl 6.0.5), in
production, 47 CTs. Disk legend as before: a CT's `rootfs` and managed `mpN` are captured, its
bind/device `mpN` are skipped.

**Install.** `install.sh` ran from a checkout of the release on each node in turn and exited 0.
On every node: both banners read `checksum-validated`, `dpkg-divert --list` shows the two
pve-bindsnap diverts, the module loads under `perl -T` with `APPLIED=1 CLONE_APPLIED=1`,
pvedaemon, pveproxy and pvestatd are active, the API lists the node's CTs, the GUI answers, and
the cluster stays quorate. **PASS.**

**Snapshot traffic.** In the first 70 minutes, two runs of the cluster's hourly snapshot job (an
API token, with its own retention deletes) and one manual `pct snapshot` produced 141
snapshot and delete tasks across the three nodes. All finished `TASK OK`.

| case                                                                                        | result                                                                                          |
|---------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| running bind-mount CT, standing `BINDSNAP-FORCE-RUNNING`, hourly job (10 CTs, 1-5 binds each) | kept rootfs, skipped every bind, freeze/thaw, summary `: standing`, checksum `validated` (PASS) |
| running bind-mount CT, `pct snapshot` as root with `BINDSNAP-FORCE-RUNNING` in the description | kept rootfs, skipped `mp0, mp1`, freeze/thaw, summary `: used` (PASS)                           |
| delete of that snapshot                                                                     | `removed rootfs; bind/device mp0, mp1 untouched` (PASS)                                         |
| CT without bind mounts (rootfs only, or rootfs + a managed `mp0`)                           | summary `no bind/device mounts -- stock snapshot, overlay made no change` (PASS)                |
| retention delete on a CT without bind mounts                                                | `removed rootfs` (plus `mp0` where managed) (PASS)                                              |

Not covered by this run: clone (the `root@pam` gate, the bind-`rootfs` refusal, a
`--snapname` clone that leaves out excluded volumes), rollback, `BINDSNAP-EXCLUDE`, and the
untested-build and known-bad paths. Those are steps 1-9g of the [test plan](testing.md).

## Aftermath

The test CT was restored to its original config (rootfs only, original Notes, no test
snapshots/datasets/bind dirs); module swaps used to simulate the untested and known-bad
paths were reverted immediately after each test. The node was left in validated mode with
the real module installed and all daemons active.
