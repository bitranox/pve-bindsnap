# Changelog

All notable changes to **pve-bindsnap** are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Versioning

`pve-bindsnap` is an installed Proxmox overlay rather than a library, so its "public API"
is the operator-facing and on-disk contract: the opt-in keywords, the install/uninstall
behaviour, and the divert/wrapper layout. For a version `MAJOR.MINOR.PATCH`:

- `MAJOR` for a breaking change to that contract, such as a renamed or removed `BINDSNAP-*`
  keyword, a changed divert or wrapper layout, or anything that needs an uninstall and
  reinstall instead of a plain reinstall.
- `MINOR` for backward-compatible additions, such as a new keyword or opt-in, or a new
  pve-container build added to the known-good allow-list (more builds work, nothing breaks).
- `PATCH` for backward-compatible fixes, such as a corrected message, a documentation fix,
  an installer or packaging fix, or a build added to the known-bad deny-list.

## [1.5.0] - 2026-11-18

### Added

- pve-container 6.1.0 with libpve-guest-common-perl 6.0.2 is vetted: snapshot checksum `9573ba8f9b60dcf6394788a05f06b66a4039b3b6944240188e87895432f865c2`, clone checksum `53656e15e33c7ffc09b5c060a203fd007a51375d7878dfe88a866b1fa121911e` (clone variant `v6_0_19`), E2E-tested on PVE 9.1.1.
- pve-container 6.1.20 with libpve-guest-common-perl 6.0.8 is vetted: snapshot checksum `9d9b831ad204db6d4cf170a0938c42adb1be209a6a34b2a27886248987a7612e`, clone checksum `42679514db5091382e8d567212b3198542feb31d420b17edeab2fae73a5d2d43` (clone variant `v6_1_7`), E2E-tested on PVE 9.2.26.
- pve-container 6.1.23 with libpve-guest-common-perl 6.0.9 is vetted: snapshot checksum `a76ef78dd01ce9519ebf666684bd2ce5a7d7662748411ec6f9667958cc253ac9`, clone checksum `62001c402f1c714d59a6d67c7a4b041f3cd1bb6a8d16f855a0ea905ea4767106` (clone variant `v6_1_7`), E2E-tested on PVE 9.2.30.

## [1.4.3] - 2026-11-18

### Added

- `tools/add-known-good.pl` adds a vetted pve-container build to both guard tables in
  `lib/PVE/LXC/BindSnap.pm` and to their mirror in `docs/compatible-versions.md`: a new checksum
  gets a new row, a checksum that already has one gets the version merged into its label. It
  refuses a checksum on a known-BAD table and a clone row that disagrees with
  `t/fixtures/clone_vm/builds.tsv`, and never writes the bad tables. Tested by
  `t/11-add-known-good.t`.
- `tools/gen-clone-variants.pl --add DIR` merges new builds into the committed `builds.tsv` and
  fixtures without dropping or renaming a row or variant: a build whose `clone_vm` body is known
  joins that body's variant, and only a new body gets a new variant. Tested by
  `t/12-clone-variants-add.t`.
- `t/13-version-sync.t` checks that `plugin.json` and the version `tools/build-deb.sh` stamps into
  the .deb both equal the module's `$VERSION`.

### Changed

- `tools/gen-clone-variants.pl` renders every variant before it writes any file, so a missing hunk
  anchor stops the run with the committed files untouched, and an unchanged file is not rewritten.
- The README, `docs/checksum-guard.md` and the `proxmox-bindsnap` skill name no vetted range: they
  point at `docs/compatible-versions.md`, and the skill says a node accepts only the rows its
  installed pve-bindsnap release holds. No change to the overlay's behaviour.

## [1.4.2] - 2026-11-17

### Changed

- The `proxmox-bindsnap` skill offers a safety snapshot on a build the guard refuses
  (`snapshot gated -- pve-container <ver> is untested`): for a STOPPED container whose managed
  volumes are all on ZFS, a raw `zfs snapshot` of every managed volume plus a copy of the CT
  config, with what it costs (not in `pct listsnapshot` or the GUI, manual rollback, and how it
  interacts with `pct rollback`); `vzdump` for every other case. Its description now names that
  refusal, so the skill loads when it appears. No code change: the overlay behaves as in 1.4.1.

## [1.4.1] - 2026-11-16

### Fixed

- The `proxmox-bindsnap` skill now says a pve-container build newer than the compatible-versions
  list is not untested on that ground alone: the overlay matches the checksum of the guarded
  files, each guard on its own, so a later build whose guarded files did not change validates
  as `checksum-validated` with no new row. Judge a node from its journal line, never by
  comparing its version with the list. No code change: the overlay behaves as in 1.4.0.

## [1.4.0] - 2026-10-31

### Added

- A Debian package, `pve-bindsnap`, and `install-apt.sh`, which adds its signed apt repository
  (key trusted for that repository only) and installs it. Installed that way pve-bindsnap is
  updated with Proxmox through the GUI or `apt-get upgrade`, and a dpkg trigger reports the new
  guard state after a `pve-container` upgrade. `install.sh` stays; the package takes over a node
  installed with it, and `install.sh` / `uninstall.sh` refuse while the package is installed. See
  [install with apt](docs/install-apt.md).
- `tools/build-deb.sh` (reproducible build) and `tools/build-apt-repo.sh` (flat signed repository).

### Changed

- Clone runs each build's own upstream `clone_vm`. 1.3.0 installed one copy, taken from 6.1.10,
  on every build, so 6.0.18 to 6.1.6 ran 6.1.10's method (a different error text, one extra
  task-log line, and the SDN IPAM call keyed on the new CT id). pve-bindsnap now ships one
  variant per distinct upstream `clone_vm` (four in 6.0.17 to 6.1.16), each verbatim outside
  its marked hunks and checked byte for byte by the tests, and the clone checksum picks the
  variant. `tools/gen-clone-variants.pl` makes them from the pve-container packages.

## [1.3.0] - 2026-10-30

### Added

- Every guard state from pve-container **6.0.18 to 6.1.16** joins both known-good tables (11
  snapshot and 9 clone checksums, up from 2 each), covering Proxmox VE 9.1 and 9.2. A guard
  state is a pve-container build with the libpve-guest-common-perl version it shipped with; the
  same build beside another guest-common version can hash differently and is then untested.
  Each state ran the full [test plan](docs/testing.md) on its own nested PVE node: 15 nodes, every case
  passing, see [test results](docs/test-results.md). A source diff against 6.1.10 came first:
  the snapshot surface differs only by two freeze/thaw log lines (guest-common 6.0.2), and the
  copied `clone_vm` is byte-identical from 6.1.7 on.
- On 6.0.18 to 6.1.6 the clone override runs the 6.1.10 `clone_vm` copy, which differs from
  those builds' own method in an error text, one task-log line and the SDN IPAM owner id (the
  new CT id, as upstream from 6.1.7). Documented in
  [compatible versions](docs/compatible-versions.md).
- A table label may name several builds (`6.1.15, 6.1.16`) when they share a checksum.

### Fixed

- The known-good list in refusal messages is ordered by version, not as a string (which put
  6.1.10 before 6.1.2).

## [1.2.4] - 2026-10-30

### Documentation

- The `proxmox-bindsnap` skill also triggers on the CLI refusal `snapshot feature is not
  available`. Overlay code unchanged.

## [1.2.3] - 2026-10-30

### Documentation

- The `proxmox-bindsnap` skill names `vzdump --mode snapshot` as the safety net on a pve-container
  build the checksum guard refuses: a backup snapshot passes through to stock and leaves the bind
  mounts out. Overlay code unchanged.

## [1.2.2] - 2026-08-27

### Documentation

- The `proxmox-bindsnap` skill attributes the `unable to clone mountpoint` error to `pct clone`, not
  `pct snapshot`. Overlay code unchanged.

## [1.2.1] - 2026-08-03

### Documentation

- The `proxmox-bindsnap` skill now names the vetted builds (pve-container 6.1.10 and 6.1.12 as
  of 1.2.0) while pointing at the journal line and
  [docs/compatible-versions.md](docs/compatible-versions.md) as the authority, and notes that
  `AbstractConfig.pm` comes from `libpve-guest-common-perl`, so an upgrade of either package can
  put a node into TEST mode. Overlay code unchanged.

## [1.2.0] - 2026-08-03

### Added

- pve-container **6.1.12** joins both known-good tables: the snapshot guard (combined
  sha256 `29dc5ce7...1bce914f`, with libpve-guest-common-perl 6.0.5) and the clone guard
  (`1ace1c4d...f7e7afc7`). Bind-mount containers on that build now snapshot and clone with
  no keyword. Validated on a PVE 9.2.6 node across the full matrix, and preceded by a
  source diff against 6.1.10 confirming the wrapped surface is unchanged (the snapshot
  helpers and the copied `clone_vm` body are byte-identical; 6.1.12 touches only
  `with_checked_volid` in the hotplug/pending paths and a permission check in `create_vm`).
  See [docs/test-results.md](docs/test-results.md).

### Documentation

- [docs/checksum-guard.md](docs/checksum-guard.md) spells out that `AbstractConfig.pm`
  ships in `libpve-guest-common-perl`, so the snapshot checksum is a pair: an update to
  that package also moves the combined hash and puts the build back into TEST mode.

## [1.1.0] - 2026-06-26

### Added

- Clone LXC containers that carry bind-/device-mounts, which stock Proxmox refuses with
  `unable to clone mountpoint '<mpN>' (type bind)`. The managed volumes (rootfs and
  `volume`-type `mpN`) clone exactly as stock; each bind/device mount is carried to the new
  container unchanged (same host path/device). A container without bind/device mounts clones
  stock on any build.
- `BINDSNAP-EXCLUDE` now also drives clone: a named bind/device mount is dropped from the
  clone instead of carried (the mirror of its snapshot behaviour, where it drops managed
  volumes). Read from the source CT Notes, or a snapshot's frozen description for a
  `--snapname` clone.
- Clone loads via a second dpkg-divert, of `PVE::API2::LXC`, with its own eval-guarded
  wrapper. The override replaces the registered `clone_vm` method's code in place (via
  `map_method_by_name`), since it is a `register_method` closure with no named sub to wrap.
- An independent clone checksum guard (`%KNOWN_GOOD_CLONE_CHECKSUMS` /
  `%KNOWN_BAD_CLONE_CHECKSUMS`, sha256 of `PVE/API2/LXC.pm`), seeded with pve-container
  6.1.10. Because the override installs a copy of `clone_vm`, it is install-gated: on an
  unvetted build it is simply not installed and `pct clone` keeps stock behaviour (bind
  clones refused), so there is no regression and no stale copy is ever run.
- A clone task-log summary (cloned / carried / excluded volumes) and a `TASK WARNINGS` when
  bind mounts are carried, noting they share the source's host paths and how to drop them.
- Test suite grows to 221 (from 195): a clone wiring test (`t/08-clone-wiring.t`) plus the
  clone summary/warning helpers. Verified live on Proxmox VE 9.2 / pve-container 6.1.10
  (baseline failure reproduced, clone carry + `BINDSNAP-EXCLUDE` + version-change fallback;
  see [docs/test-results.md](docs/test-results.md)).
- A bundled Claude Code skill, `proxmox-bindsnap` (`skills/proxmox-bindsnap/SKILL.md`), so an LLM
  agent can install, verify, configure and operate pve-bindsnap on a node. The repo is now also a
  single-plugin Claude Code marketplace (`.claude-plugin/marketplace.json` + `plugin.json`,
  `source: "."`): install via `/plugin marketplace add bitranox/pve-bindsnap` or copy
  `skills/proxmox-bindsnap` into a skills directory. Also published in the bitranox-skills
  marketplace. Adds `.gitattributes` (LF) and a CI JSON-manifest validation step.

## [1.0.1] - 2026-06-10

### Changed

- The routine "overlay active" load banner is now restricted to the long-running PVE
  daemons (`pvedaemon`/`pveproxy`/`pvestatd`). Because the install diverts
  `PVE::LXC::Config`, every process that loads it used to print the banner; on a non-PVE
  loader (a hookscript, or a third-party VM manager such as an openvmm helper) that line
  was just noise in an unrelated log. It now prints only in the daemon journal, where it
  confirms the overlay is live. The per-snapshot/rollback/delete summaries and all refusals
  and `TASK WARNINGS` are unchanged, so GUI and CLI snapshots still report fully.
- Test suite grows to 195 (from 183): coverage for the daemon-only banner gate.

## [1.0.0] - 2026-06-07

Initial release.

### Added

- Snapshot LXC containers that carry bind-/device-mounts (`mpN` -> host paths), which stock
  Proxmox greys out. Managed volumes (rootfs and `volume`-type `mpN`) are captured; bind and
  device mounts are skipped and their host data is left untouched. `vzdump` is unaffected.
- Loads by dpkg-diverting `PVE::LXC::Config` and installing a thin, eval-guarded wrapper, so
  it covers the GUI, the API and every `pct` invocation under `perl -T` (taint). It delegates
  to the live upstream methods; the only logic it owns is a thin bind/device filter around
  `foreach_volume_full`.
- A content-checksum guard (combined sha256 of `Config.pm` and `AbstractConfig.pm`) with a
  tested-good allow-list and a known-bad deny-list, seeded with pve-container 6.1.10. Only
  bind-mount containers are gated; the rest snapshot stock on any build.
- Opt-in keywords, read from the snapshot name or description (per snapshot) and from the CT
  Notes (a standing directive):
  - `BINDSNAP-FORCE-RUNNING` to snapshot a running container (it takes the brief filesystem
    freeze).
  - `BINDSNAP-UNSUPPORTED` to snapshot on an untested build. A deny-listed build is
    hard-blocked and this does not override it; a standing `BINDSNAP-UNSUPPORTED` is flagged
    risky in the task-log summary.
- A `BINDSNAP-EXCLUDE: <mpN list>` directive to keep named managed volumes out of a snapshot,
  set in the CT Notes, overridable per snapshot, and frozen into each snapshot so rollback
  and delete stay consistent.
- A multi-line summary written to the task log for every snapshot, rollback and delete
  (wrapped to stay readable in the task viewer); refusals print the full multi-line
  explanation there and exit with a short one-line status.
- A snapshot taken on an untested build (allowed by `BINDSNAP-UNSUPPORTED`, per-snapshot or
  standing) finishes as a yellow Proxmox `TASK WARNINGS` rather than a silent `TASK OK`, with
  a `WARN` line nudging you to report the build so it can join the known-good list.
- `install.sh` and `uninstall.sh` with a pre-flight load check before any daemon restart, an
  EXIT-trap rollback that restores stock on any failure after the divert, and standalone
  `curl | bash` operation.
- 183 unit tests (`perl -c`, `prove`, `shellcheck`, `shfmt`; CI runs all four), including an
  off-node wiring test that drives the redefined snapshot methods. Verified live on Proxmox
  VE 9.2 / pve-container 6.1.10 (see [docs/test-results.md](docs/test-results.md)).

[1.1.0]: https://github.com/bitranox/pve-bindsnap/releases/tag/v1.1.0
[1.0.1]: https://github.com/bitranox/pve-bindsnap/releases/tag/v1.0.1
[1.0.0]: https://github.com/bitranox/pve-bindsnap/releases/tag/v1.0.0
