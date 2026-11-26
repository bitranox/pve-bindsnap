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

| pve-container              | combined sha256                                                    | notes                                                                                                                                           |
|----------------------------|--------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| 6.0.18                     | `5a7740a4a2c7e1e977740e3ce28811c23fd0f9c657bf15abf6a372c587fcfbcf` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                                                                                         |
| 6.0.19                     | `167a8689ef8a3a650c398f4870f916ee724b32bc028549bee780803c63093b37` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                                                                                         |
| 6.1.0, 6.1.1               | `9573ba8f9b60dcf6394788a05f06b66a4039b3b6944240188e87895432f865c2` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2; 6.1.0 E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                          |
| 6.1.2, 6.1.3, 6.1.4, 6.1.5 | `482996dd8c502b390dba6ba3205addf908bf27c9786af749c30c20e806a40eef` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2; 6.1.4 E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                          |
| 6.1.6                      | `77e70a3803013ba37a1f7b2a5ba6960121968e1a7a4c1df5c6be45ba94bbccd9` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.2                                                                                         |
| 6.1.7                      | `e963f8e465ca4314691a5695316878b36ba3284242f98abe6b48f54953bb0365` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.3                                                                                         |
| 6.1.8, 6.1.9               | `9edba4fe051f05bb8b2b3634e0aeb707649b8a8a987e88e443cbf58178a1e9dd` | E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.3; 6.1.8 E2E-tested on PVE 9.1.1, libpve-guest-common-perl 6.0.3                          |
| 6.1.10                     | `1ebb1a44483bfdabed59f421c88003673a283cd83cd4009407ce39219faa6106` | tested on PVE 9.2; E2E-tested on PVE 9.2.2, libpve-guest-common-perl 6.0.3                                                                      |
| 6.1.11, 6.1.12, 6.1.13     | `29dc5ce7b561e9306a837380d372c7212690dd827611d09632988def1bce914f` | 6.1.12 tested on PVE 9.2.6; 6.1.11 and 6.1.13 E2E-tested on PVE 9.2.2, 9.2.7                                                                    |
| 6.1.14                     | `04aada64089cbf97d1598ea0b102aa61d38bfd456526be4fff5ce4289e225a77` | E2E-tested on PVE 9.2.7, libpve-guest-common-perl 6.0.5                                                                                         |
| 6.1.15, 6.1.16, 6.1.18     | `3c7e8deb78600666b7462529721d00054b7a41b3b506c798c21a17351ff48998` | E2E-tested on PVE 9.2.24 and 9.2.25 (6.1.16 from pve-test), guest-common 6.0.5; 6.1.18 E2E-tested on PVE 9.2.26, libpve-guest-common-perl 6.0.6 |
| 6.1.19                     | `e8f9640cb09157559a6a346f18398db298ab901d0408c75990be86c2ef041ca3` | E2E-tested on PVE 9.2.22, libpve-guest-common-perl 6.0.7                                                                                        |
| 6.1.20                     | `9d9b831ad204db6d4cf170a0938c42adb1be209a6a34b2a27886248987a7612e` | E2E-tested on PVE 9.2.26, libpve-guest-common-perl 6.0.8                                                                                        |
| 6.1.23                     | `a76ef78dd01ce9519ebf666684bd2ce5a7d7662748411ec6f9667958cc253ac9` | E2E-tested on PVE 9.2.30, libpve-guest-common-perl 6.0.9                                                                                        |
| 6.1.24                     | `0dc137fb56fac17c2bfe71dc2d51155dbabc2383f94fbdfb940d163c9e14940e` | E2E-tested on PVE 9.2.30, libpve-guest-common-perl 6.0.10                                                                                       |
| 6.1.24                     | `b1033708527e095f14650daa0001b3eeb02ec5612576aaaf3bea6c7f32742015` | E2E-tested on PVE 9.2.30, libpve-guest-common-perl 6.0.11                                                                                       |
| 6.1.25                     | `6107126d5f13980f3dc2d7ce4f5840da6a372b4b0ecf930f8db4c76e5be47ef6` | E2E-tested on PVE 9.2.30, libpve-guest-common-perl 6.0.12                                                                                       |
| 6.1.26                     | `b6dbfe355052a818ecd0b1aed9b1c226833603e3e06e55a196b35ce032fe1353` | E2E-tested on PVE 9.2.30, libpve-guest-common-perl 6.0.12                                                                                       |
| 6.1.27                     | `5c15ad1356878f5c939ff7e7f641a8767d1c42d7690d47b839a36fc2ca7a730c` | E2E-tested on PVE 9.2.38, libpve-guest-common-perl 6.0.15                                                                                       |
| 6.1.28                     | `3c141d55950fdc319de4000a39077a8e31205a72641553d4e99493fdebc3689a` | E2E-tested on PVE 9.2.38 and 9.3.1, libpve-guest-common-perl 6.0.15                                                                             |

The checksum also covers `PVE/AbstractConfig.pm`, which ships in `libpve-guest-common-perl`, so
each row holds for the guest-common version named in it. Several builds share a row because the
guarded files did not change between them. One build can also have two rows: when a guest-common
release changes `AbstractConfig.pm` while the pve-container build stays the same, that pairing gets
its own checksum and is vetted on its own. 6.1.11 ships with guest-common 6.0.4 and 6.1.12/6.1.13
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

On these builds, `pct clone` carries bind/device mountpoints to the new CT for `root@pam`
(and honours `BINDSNAP-EXCLUDE` for every caller); a CT whose rootfs is a bind/device mount
is never cloned.

| pve-container                       | combined sha256                                                    | notes                                                                                                     |
|-------------------------------------|--------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| 6.0.18                              | `97d08a12e39ec4a561c639624e40c447e726f05bdfc46778292c30a9e35c8fd8` | E2E-tested on PVE 9.1.1 (see below)                                                                       |
| 6.0.19, 6.1.0, 6.1.1, 6.1.2         | `53656e15e33c7ffc09b5c060a203fd007a51375d7878dfe88a866b1fa121911e` | E2E-tested on PVE 9.1.1 (see below); 6.1.0 E2E-tested on PVE 9.1.1                                        |
| 6.1.3                               | `d483d5ce01afcd0634fba57c3fcbb9d2396e5447806b950d5ea450285ad14f6b` | E2E-tested on PVE 9.1.1 (see below)                                                                       |
| 6.1.4, 6.1.5, 6.1.6                 | `b63d3fdda3cb82f35e3f221f85b47b4943eb907b959f3398fdfad1b58bbb1372` | E2E-tested on PVE 9.1.1 (see below); 6.1.4 E2E-tested on PVE 9.1.1                                        |
| 6.1.7, 6.1.8, 6.1.9, 6.1.10, 6.1.11 | `8408885ec50809460948d25a9121be387ec7a01ef58c7a377403a01acf525198` | E2E-tested on PVE 9.1.1 and 9.2.2; 6.1.8 E2E-tested on PVE 9.1.1                                          |
| 6.1.12, 6.1.13                      | `1ace1c4de506b79bf165f2c5aeaa8d8c4af35b6a9d91ce1ea24e5742f7e7afc7` | tested on PVE 9.2.6, E2E-tested on 9.2.7                                                                  |
| 6.1.14                              | `2ea44bdd7dd321e593b0ede65d0a8b01126fff733bb0591da84a4656a43b635a` | E2E-tested on PVE 9.2.7                                                                                   |
| 6.1.15                              | `892c3fcda6e70abbae33ee93c01393f0f36f9899b3e74954825943525d8400dd` | E2E-tested on PVE 9.2.24                                                                                  |
| 6.1.16, 6.1.18, 6.1.19              | `ed915d4f9d205a460379a0f0746434eba6cbaf331759eeb76202e47a5caf1947` | E2E-tested on PVE 9.2.25, from pve-test; 6.1.18 E2E-tested on PVE 9.2.26; 6.1.19 E2E-tested on PVE 9.2.22 |
| 6.1.20                              | `42679514db5091382e8d567212b3198542feb31d420b17edeab2fae73a5d2d43` | E2E-tested on PVE 9.2.26                                                                                  |
| 6.1.23                              | `62001c402f1c714d59a6d67c7a4b041f3cd1bb6a8d16f855a0ea905ea4767106` | E2E-tested on PVE 9.2.30                                                                                  |
| 6.1.24                              | `e307ed89228aa05acd5b37968734ce8651c285141ea877fec440d412ed4d3b8d` | E2E-tested on PVE 9.2.30                                                                                  |
| 6.1.25, 6.1.26                      | `41ef73fa8a4cfe206e160672243395625ed06a242d93bfc49a68c7b5359a7713` | E2E-tested on PVE 9.2.30; 6.1.26 E2E-tested on PVE 9.2.30                                                 |
| 6.1.27, 6.1.28                      | `fc4aac5335b399d4513c2ab21024ea6413fd3f26f13e65794b21d83db7f4b3a5` | E2E-tested on PVE 9.2.38; 6.1.28 E2E-tested on PVE 9.2.38 and 9.3.1                                       |

**Each build runs its own `clone_vm`.** The clone override installs the build's own upstream
`clone_vm` with the bind-mount hunks applied. Upstream's method changed between builds in
this range, so pve-bindsnap ships one variant per distinct upstream text, and each clone checksum
selects the variant taken from that very build:

| clone_vm variant | pve-container builds with that upstream `clone_vm` |
|------------------|----------------------------------------------------|
| `v6_0_17`        | 6.0.17, 6.0.18                                     |
| `v6_0_19`        | 6.0.19, 6.1.0, 6.1.1, 6.1.2                        |
| `v6_1_3`         | 6.1.3, 6.1.4, 6.1.5, 6.1.6                         |
| `v6_1_7`         | 6.1.7 to 6.1.23                                    |
| `v6_1_24`        | 6.1.24                                             |
| `v6_1_25`        | 6.1.25, 6.1.26, 6.1.27, 6.1.28                     |

Each variant is the upstream text verbatim outside its marked hunks
(`lib/PVE/LXC/BindSnap/Clone/`, generated by `tools/gen-clone-variants.pl`), and the tests
prove it byte for byte against the upstream slice. So a clone on any of these builds behaves
exactly as that build's own clone does, except for the bind/device mounts.

### Hard-blocked (known-bad)

| pve-container | combined sha256 | reason |
|---------------|-----------------|--------|
| (none yet)    | -               | -      |
