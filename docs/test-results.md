# Test results

Verification of the current module, off the node and on a test node. This page reflects
the latest run; the test plan that produces it is in [testing.md](testing.md).

## Off the node

`perl -c` clean, `prove -I lib t/` = **166 tests pass**, `shellcheck` and `shfmt` clean.
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
in CI, not only on a live node.

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

## Aftermath

The test CT was restored to its original config (rootfs only, original Notes, no test
snapshots/datasets/bind dirs); module swaps used to simulate the untested and known-bad
paths were reverted immediately after each test. The node was left in validated mode with
the real module installed and all daemons active.
