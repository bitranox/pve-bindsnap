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

| pve-container | combined sha256                                                    | notes                                                                                  |
|---------------|--------------------------------------------------------------------|----------------------------------------------------------------------------------------|
| 6.1.10        | `1ebb1a44483bfdabed59f421c88003673a283cd83cd4009407ce39219faa6106` | tested on PVE 9.2                                                                      |
| 6.1.12        | `29dc5ce7b561e9306a837380d372c7212690dd827611d09632988def1bce914f` | tested on PVE 9.2.6, with libpve-guest-common-perl 6.0.5                               |
| 6.1.14        | `04aada64089cbf97d1598ea0b102aa61d38bfd456526be4fff5ce4289e225a77` | source-reviewed, checksum confirmed on PVE 9.2.20, with libpve-guest-common-perl 6.0.5 |

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
checksum: the sha256 of the `clone_vm` method block of `PVE/API2/LXC.pm` (from its
`__PACKAGE__->register_method({` line to its closing `});`, the code the overlay copies),
not of the whole file, so unrelated upstream changes elsewhere in `LXC.pm` keep the same
hash. The module's `%KNOWN_GOOD_CLONE_CHECKSUMS` / `%KNOWN_BAD_CLONE_CHECKSUMS` tables are
authoritative; this section mirrors them. On a non-validated build the clone override is **not**
installed and `pct clone` keeps stock behaviour (bind mounts still rejected) -- no regression.

Recompute the manual way (must equal what the overlay logs):

```
api=/usr/share/perl5/PVE/API2/LXC.pm
[ -e "$api.distrib" ] && api="$api.distrib"
awk '/^__PACKAGE__->register_method\(\{$/{buf=""} {buf=buf $0 "\n"} /^    name => .clone_vm.,$/{hit=1} hit&&/^\}\);$/{printf "%s", buf; exit}' "$api" | sha256sum | awk '{print $1}'
```

### Supported (tested-good)

On these builds, `pct clone` carries bind/device mountpoints to the new CT (and honours
`BINDSNAP-EXCLUDE`).

| pve-container | clone_vm sha256                                                    | notes                                                    |
|---------------|--------------------------------------------------------------------|----------------------------------------------------------|
| 6.1.10-6.1.14 | `7a10c90b920b56e645bba6798daefc49ca32150cf670551a81176e2658aa56c8` | tested on PVE 9.2 and 9.2.6; 6.1.14 source-reviewed      |

### Hard-blocked (known-bad)

| pve-container | clone_vm sha256 | reason |
|---------------|-----------------|--------|
| (none yet)    | -               | -      |
