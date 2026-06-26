# Compatible versions

The overlay gates bind-mount CT snapshots on a **content checksum** of the upstream
Proxmox snapshot code (combined sha256 of `PVE/LXC/Config.pm` + `PVE/AbstractConfig.pm`),
not on a version string. The module's `%KNOWN_GOOD_CHECKSUMS` and `%KNOWN_BAD_CHECKSUMS`
tables are authoritative; this page mirrors them for humans. See
[the checksum guard](checksum-guard.md) for how the value is computed and why bytes, not
versions, decide.

Containers **without** bind/device mounts snapshot stock on any build. None of this
gating applies to them.

## Supported (tested-good)

These builds snapshot bind-mount CTs with no keyword needed.

| pve-container | combined sha256                                                    | notes             |
|---------------|--------------------------------------------------------------------|-------------------|
| 6.1.10        | `1ebb1a44483bfdabed59f421c88003673a283cd83cd4009407ce39219faa6106` | tested on PVE 9.2 |

## Hard-blocked (known-bad)

These builds mishandle bind-mount snapshots. The overlay **refuses** them, and the
`BINDSNAP-UNSUPPORTED` keyword will **not** override the block. Update pve-container to a
tested-good build, or snapshot the stopped CT with `zfs snapshot` directly.

| pve-container | combined sha256 | reason |
|---------------|-----------------|--------|
| (none yet)    | -               | -      |

## Anything else

A build in neither table is **untested**. Bind-mount CT snapshots are refused unless you
opt in per snapshot with the `BINDSNAP-UNSUPPORTED` keyword (in the snapshot name or description);
see the [README](../README.md#using-it). If you test an untested build, please report the
result, **whether it works or not**, with the version and combined checksum (both
printed by the overlay) at the
[issues page](https://github.com/bitranox/pve-bindsnap/issues), so it can be
added here. A newer overlay release may already cover your build, so check this page first.

## Clone support (separate guard)

`pct clone` of a bind-mount CT is blocked by a different upstream code path
(`PVE::API2::LXC::clone_vm`), so the overlay gates the clone fix on its **own** content
checksum: the sha256 of `PVE/API2/LXC.pm` alone (the file whose `clone_vm` body the overlay
copies). The module's `%KNOWN_GOOD_CLONE_CHECKSUMS` / `%KNOWN_BAD_CLONE_CHECKSUMS` tables are
authoritative; this section mirrors them. On a non-validated build the clone override is **not**
installed and `pct clone` keeps stock behaviour (bind mounts still rejected) -- no regression.

Recompute the manual way (must equal what the overlay logs):

```
sha256sum /usr/share/perl5/PVE/API2/LXC.pm | awk '{print $1}' | sha256sum | awk '{print $1}'
```

### Supported (tested-good)

On these builds, `pct clone` carries bind/device mountpoints to the new CT (and honours
`BINDSNAP-EXCLUDE`).

| pve-container | combined sha256                                                    | notes             |
|---------------|--------------------------------------------------------------------|-------------------|
| 6.1.10        | `8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198` | tested on PVE 9.2 |

### Hard-blocked (known-bad)

| pve-container | combined sha256 | reason |
|---------------|-----------------|--------|
| (none yet)    | -               | -      |
