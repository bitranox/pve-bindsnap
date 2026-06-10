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

[1.0.1]: https://github.com/bitranox/pve-bindsnap/releases/tag/v1.0.1
[1.0.0]: https://github.com/bitranox/pve-bindsnap/releases/tag/v1.0.0
