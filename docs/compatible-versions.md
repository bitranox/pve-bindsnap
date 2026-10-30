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

| pve-container          | combined sha256                                                    | notes                                                                          |
|------------------------|--------------------------------------------------------------------|--------------------------------------------------------------------------------|
| 6.0.18                 | `5a7740a4a2c7e1e977740e3ce28811c23fd0f9c657bf15abf6a372c587fcfbcf` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                        |
| 6.0.19                 | `167a8689ef8a3a650c398f4870f916ee724b32bc028549bee780803c63093b37` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                        |
| 6.1.1                  | `9573ba8f9b60dcf6394788a05f06b66a4039b3b6944240188e87895432f865c2` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                        |
| 6.1.2, 6.1.3, 6.1.5    | `482996dd8c502b390dba6ba3205addf908bf27c9786af749c30c20e806a40eef` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                        |
| 6.1.6                  | `77e70a3803013ba37a1f7b2a5ba6960121968e1a7a4c1df5c6be45ba94bbccd9` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                        |
| 6.1.7                  | `e963f8e465ca4314691a5695316878b36ba3284242f98abe6b48f54953bb0365` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.3                        |
| 6.1.9                  | `9edba4fe051f05bb8b2b3634e0aeb707649b8a8a987e88e443cbf58178a1e9dd` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.3                        |
| 6.1.10                 | `1ebb1a44483bfdabed59f421c88003673a283cd83cd4009407ce39219faa6106` | tested on PVE 9.2; E2E-tested on PVE 9.2.2, libpve-guest-common-perl 6.0.3     |
| 6.1.11, 6.1.12, 6.1.13 | `29dc5ce7b561e9306a837380d372c7212690dd827611d09632988def1bce914f` | 6.1.12 tested on PVE 9.2.6; 6.1.11 and 6.1.13 E2E-tested on PVE 9.2.2, 9.2.7   |
| 6.1.14                 | `04aada64089cbf97d1598ea0b102aa61d38bfd456526be4fff5ce4289e225a77` | E2E-tested on PVE 9.2.7, libpve-guest-common-perl 6.0.5                        |
| 6.1.15, 6.1.16         | `3c7e8deb78600666b7462529721d00054b7a41b3b506c798c21a17351ff48998` | E2E-tested on PVE 9.2.24 and 9.2.25 (6.1.16 from pve-test), guest-common 6.0.5 |

The checksum also covers `PVE/AbstractConfig.pm`, which ships in `libpve-guest-common-perl`, so
each row holds for the guest-common version named in it. Several builds share a row because the
guarded files did not change between them. 6.1.11 ships with guest-common 6.0.4 and 6.1.12/6.1.13
with 6.0.5; those two guest-common versions carry an identical `AbstractConfig.pm`.

A build not named in a table is still accepted when its guarded files are byte-identical to a
listed one (several unlisted builds are); the overlay's journal line says which way THIS node
went.

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

| pve-container                | combined sha256                                                    | notes                                    |
|------------------------------|--------------------------------------------------------------------|------------------------------------------|
| 6.0.18                       | `97d08a12e39ec4a561c639624e40c447e726f05bdfc46778292c30a9e35c8fd8` | E2E-tested on PVE 9.1.1 (see below)      |
| 6.0.19, 6.1.1, 6.1.2         | `53656e15e33c7ffc09b5c060a203fd007a51375d7878dfe88a866b1fa121911e` | E2E-tested on PVE 9.1.1 (see below)      |
| 6.1.3                        | `d483d5ce01afcd0634fba57c3fcbb9d2396e5447806b950d5ea450285ad14f6b` | E2E-tested on PVE 9.1.1 (see below)      |
| 6.1.5, 6.1.6                 | `b63d3fdda3cb82f35e3f221f85b47b4943eb907b959f3398fdfad1b58bbb1372` | E2E-tested on PVE 9.1.1 (see below)      |
| 6.1.7, 6.1.9, 6.1.10, 6.1.11 | `8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198` | E2E-tested on PVE 9.1.1 and 9.2.2        |
| 6.1.12, 6.1.13               | `1ace1c4de506b79bf165f2c5aeaa8d8c4af35b6a9d91ce1ea24e5742f7e7afc7` | tested on PVE 9.2.6, E2E-tested on 9.2.7 |
| 6.1.14                       | `2ea44bdd7dd321e593b0ede65d0a8b01126fff733bb0591da84a4656a43b635a` | E2E-tested on PVE 9.2.7                  |
| 6.1.15                       | `892c3fcda6e70abbae33ee93c01393f0f36f9899b3e74954825943525d8400dd` | E2E-tested on PVE 9.2.24                 |
| 6.1.16                       | `ed915d4f9d205a460379a0f0746434eba6cbaf331759eeb76202e47a5caf1947` | E2E-tested on PVE 9.2.25, from pve-test  |

**Builds before 6.1.7.** The override replaces `clone_vm` with a copy of the 6.1.10 method,
and on 6.0.18 to 6.1.6 that copy differs from the build's own method in three places: the error
text for a full clone of a running CT, one extra `creating a clone of container ...` task-log
line, and the SDN IPAM call, which registers the clone's addresses under the NEW CT id, as
upstream does from 6.1.7 on (the older builds pass the source id). Every function the copy calls
has the same signature on those builds. So on these builds every `pct clone`, with or without
bind mounts, behaves like 6.1.7 and later. The IPAM difference only matters with SDN IPAM, and
the E2E runs did not exercise it.

### Hard-blocked (known-bad)

| pve-container | combined sha256 | reason |
|---------------|-----------------|--------|
| (none yet)    | -               | -      |
