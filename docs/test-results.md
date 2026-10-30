# Test results

Verification of the current module, off the node and on a test node. This page reflects
the latest run; the test plan that produces it is in [testing.md](testing.md).

## Off the node

`perl -c` clean (both `BindSnap.pm` and `API2/LXC.wrapper.pm`), `prove -I lib t/` =
**225 tests pass**, `shellcheck` and `shfmt` clean.
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
`29dc5ce7...1bce914f`, clone checksum `1ace1c4d...f7e7afc7`). A throwaway unprivileged CT
carried one bind mount (`mp0` -> a host dir) and one managed volume (`mp1` ->
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

## pve-container 6.0.18 to 6.1.16 (1.3.0)

Validation run that added every guard state from pve-container 6.0.18 to 6.1.16 to both
known-good tables. Each state got its own nested Proxmox VE node holding stock PVE with exactly
that pve-container and its libpve-guest-common-perl (15 nodes: 9 on PVE 9.1.1, 6 on PVE 9.2), a
stopped unprivileged CT with one bind mount (`mp0` -> a host dir), and no pve-bindsnap installed.
Every run started and ended with a rollback of the node to that clean state.

**Source review first.** The extracted packages of every build were diffed against 6.1.10:

- Snapshot surface (`has_feature`, `__snapshot_*`, `snapshot_create`/`delete`/`rollback`,
  `foreach_volume_full`): unchanged on every build, except that guest-common 6.0.2 lacks two
  `print` lines (`freeze guest filesystem` / `thaw guest filesystem`) in `snapshot_create`.
- `clone_vm`: byte-identical to the copied 6.1.10 body from 6.1.7 to 6.1.16. On 6.0.18 to 6.1.6
  it differs in the error text for a full clone of a running CT, one `creating a clone ...` log
  line, and the SDN IPAM owner id passed to `create_ifaces_ipams_ips` (the source id there, the
  new CT id from 6.1.7). Every function the copied body calls has the same signature on those
  builds, so they were vetted with the 6.1.10 behaviour; see
  [compatible versions](compatible-versions.md).

**Per node**, scripted (`pct`, `zfs`, `pvesh` task status), first against the release module,
in which the build read as untested, then against a module with the node's own checksums added:

| phase                 | cases                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
|-----------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| stock (not installed) | bind clone dies `unable to clone mountpoint`; bind snapshot refused                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| untested build        | banners `TEST mode` and `clone overlay loaded but NOT active`; snapshot refused without a keyword; `BINDSNAP-UNSUPPORTED` proceeds as `TASK WARNINGS`; delete; clone stays stock                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| validated build       | both banners `checksum-validated`; with a managed `mp1` added: stopped snapshot `TASK OK` capturing rootfs + mp1; data-level rollback (rootfs and mp1 back to `v1`, the bind file keeps `v2`); delete leaves no zfs snapshot; running CT refused without a keyword, allowed with `BINDSNAP-FORCE-RUNNING` and with the standing Notes directive; `vzdump --mode snapshot`; `BINDSNAP-EXCLUDE: mp1` keeps mp1 out and the empty override puts it back; delete honours the frozen directive; clone gets a new rootfs and mp1, carries `mp0` with the yellow carry warning; `BINDSNAP-EXCLUDE: mp0` drops mp0 from the clone |
| known-bad             | the node's checksum on the deny-list: refused, and `BINDSNAP-UNSUPPORTED` cannot override it; no zfs snapshot left                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| uninstall             | diverts gone, `dpkg --verify` silent, stock refusal again                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

All 15 nodes passed every case (29 to 33 per node; the three builds already in the tables skip
the untested phase). The release module was then run once more on all 15 nodes: both banners
read `checksum-validated` on each, and every case passed again.

| pve-container | guest-common | PVE    | snapshot checksum     | clone checksum        |
|---------------|--------------|--------|-----------------------|-----------------------|
| 6.0.18        | 6.0.2        | 9.1.1  | `5a7740a4...87fcfbcf` | `97d08a12...e35c8fd8` |
| 6.0.19        | 6.0.2        | 9.1.1  | `167a8689...63093b37` | `53656e15...a121911e` |
| 6.1.1         | 6.0.2        | 9.1.1  | `9573ba8f...32f865c2` | `53656e15...a121911e` |
| 6.1.2         | 6.0.2        | 9.1.1  | `482996dd...06a40eef` | `53656e15...a121911e` |
| 6.1.3         | 6.0.2        | 9.1.1  | `482996dd...06a40eef` | `d483d5ce...5ad14f6b` |
| 6.1.5         | 6.0.2        | 9.1.1  | `482996dd...06a40eef` | `b63d3fdd...8bbb1372` |
| 6.1.6         | 6.0.2        | 9.1.1  | `77e70a38...94bbccd9` | `b63d3fdd...8bbb1372` |
| 6.1.7         | 6.0.3        | 9.1.1  | `e963f8e4...53bb0365` | `8408885e...cf525198` |
| 6.1.9         | 6.0.3        | 9.1.1  | `9edba4fe...78a1e9dd` | `8408885e...cf525198` |
| 6.1.10        | 6.0.3        | 9.2.2  | `1ebb1a44...9faa6106` | `8408885e...cf525198` |
| 6.1.11        | 6.0.4        | 9.2.2  | `29dc5ce7...1bce914f` | `8408885e...cf525198` |
| 6.1.13        | 6.0.5        | 9.2.7  | `29dc5ce7...1bce914f` | `1ace1c4d...f7e7afc7` |
| 6.1.14        | 6.0.5        | 9.2.7  | `04aada64...9e225a77` | `2ea44bdd...a43b635a` |
| 6.1.15        | 6.0.5        | 9.2.24 | `3c7e8deb...1ff48998` | `892c3fcd...5d8400dd` |
| 6.1.16        | 6.0.5        | 9.2.25 | `3c7e8deb...1ff48998` | `ed915d4f...5caf1947` |

## Aftermath

The test CT was restored to its original config (rootfs only, original Notes, no test
snapshots/datasets/bind dirs); module swaps used to simulate the untested and known-bad
paths were reverted immediately after each test. The node was left in validated mode with
the real module installed and all daemons active.
