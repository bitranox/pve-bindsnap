# Install with apt

pve-bindsnap is also published as a Debian package, `pve-bindsnap`, in a small signed apt
repository. Installed that way it is updated together with Proxmox: the GUI's
**Node -> Updates -> Upgrade**, `apt-get upgrade` and `apt-get dist-upgrade` all pick up a
new release, and a `pve-container` upgrade is noticed by the package itself (see
[Proxmox upgrades](#proxmox-upgrades)). This is an alternative to `install.sh`, not a
replacement: both install the same files and the same two diverts.

## Install

On each node, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install-apt.sh | bash
```

`install-apt.sh` checks that it runs as root on Proxmox VE 9 (Debian trixie), then:

1. writes the repository's public key to
   `/usr/share/keyrings/pve-bindsnap-archive-keyring.asc`;
2. writes `/etc/apt/sources.list.d/pve-bindsnap.sources`, which trusts that key for this
   repository only (`Signed-By`), never system-wide;
3. runs `apt-get update` for this repository and `apt-get install -y pve-bindsnap`.

Re-running it is safe. Piped from curl, it takes its options after `bash -s --`, for example
`curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install-apt.sh | bash -s -- --remove --purge`; from a checkout, run `./install-apt.sh <options>`.
Its options:

| Command                           | Does                                                 |
|-----------------------------------|------------------------------------------------------|
| `install-apt.sh`                  | add the repository and install the package           |
| `install-apt.sh --no-install`     | only add the repository (and run `apt-get update`)   |
| `install-apt.sh --remove`         | remove the repository and its key                    |
| `install-apt.sh --remove --purge` | also purge the package, which restores stock Proxmox |
| `install-apt.sh --repo-url URL`   | use another repository (a mirror, a test repository) |

The repository is `https://github.com/bitranox/pve-bindsnap/releases/latest/download/`
(a flat repository, suite `./`), and it is signed with this key:

```
1445 C598 166A 481A C529  2FE1 A5A5 351D 2BC8 8FDC
```

The same public key is in the repository as `apt/pve-bindsnap-archive-keyring.asc`, and the
tests check that the copy embedded in `install-apt.sh` matches it and has that fingerprint.

## Install the .deb by hand

Every GitHub release carries `pve-bindsnap_<version>_all.deb`. Download it and install it with
apt, which resolves the dependencies:

```bash
apt-get install ./pve-bindsnap_<version>_all.deb
```

Installed this way it is not updated by the GUI; install the next release the same way, or add
the repository with `install-apt.sh`.

## What the package does

- **preinst** diverts `PVE/LXC/Config.pm` and `PVE/API2/LXC.pm` to `.distrib` (tagged
  `--package pve-bindsnap`, as `install.sh` does) and removes an `install.sh` copy of the
  overlay from `/usr/local/lib/site_perl`, so a node installed with the script is taken over
  as it stands.
- The payload puts the overlay and its clone variants in `/usr/share/perl5/PVE/LXC/` and the
  two thin wrappers at the diverted paths.
- **postinst** checks that both wrappers load, then runs
  `systemctl reload-or-try-restart pvedaemon pveproxy pvestatd` (the graceful form Proxmox's
  own packages use, so an upgrade started from the GUI is not cut off) and prints the guard
  state, for example `clone overlay active (... clone_vm variant v6_1_7)`. If the check fails,
  the daemons are not reloaded and the configure step fails; the wrappers fall back to stock
  on their own, so Proxmox keeps working.
- **postrm** (remove or purge) removes both diverts, which puts the upstream files back, and
  reloads the daemons.

## Proxmox upgrades

The package registers a dpkg trigger on Proxmox's container code. When an upgrade replaces it
(the new upstream file lands at the diverted `.distrib` path, the wrapper stays), the trigger
re-checks the load, reloads the daemons and prints the new guard state in the apt output: still
validated with the variant it now uses, or TEST mode and clone stock on a build that is not
vetted yet. A failed check there only warns; the upgrade itself is never failed.

## From install.sh to the package

Run `install-apt.sh` on a node installed with `install.sh`; it says it found that installation
and the package takes it over (same diverts, overlay moved to `/usr/share/perl5`). Do not run
`uninstall.sh` first, and do not use `install.sh` or `uninstall.sh` afterwards: while the
package is installed both refuse and point at `apt-get purge pve-bindsnap`.

## Remove

```bash
curl -fsSL https://raw.githubusercontent.com/bitranox/pve-bindsnap/main/install-apt.sh | bash -s -- --remove --purge
```

This purges the package (stock Proxmox is back) and removes the repository and its key.
`apt-get purge pve-bindsnap` alone removes the package and leaves the repository configured.
Snapshots you already took persist, exactly as after `uninstall.sh`.
