# Testing

## On a node

After `install.sh`, the GUI, the API, and `pct` all go through the overlay (it diverts
`PVE::LXC::Config`, so every process that loads it is covered). Run the whole check
with plain `pct`:

```bash
# 1. baseline: snapshot a STOPPED bind-mount container
pct stop <vmid>
pct snapshot <vmid> test1
zfs list -t snapshot | grep subvol-<vmid>-disk-0     # expect @test1, rootfs only
pct listsnapshot <vmid>                              # expect test1

# 2. rollback
pct rollback <vmid> test1
pct start <vmid>

# 3. cleanup
pct delsnapshot <vmid> test1

# 4. running container: refused without a keyword, allowed with BINDSNAP-FORCE-RUNNING
pct start <vmid>
pct snapshot <vmid> nope                                 # expect: "CT <vmid> is running ... stop ... or BINDSNAP-FORCE-RUNNING"
pct snapshot <vmid> live1 --description "BINDSNAP-FORCE-RUNNING pre-change"  # proceeds (fs-freeze); stored comment stays "BINDSNAP-FORCE-RUNNING pre-change"

# 4b. standing directive (the automated-tool path, e.g. cv4pve-autosnap): a BINDSNAP-FORCE-RUNNING
#     line in the CT Notes allows a running snapshot with NO per-snapshot keyword.
pct set <vmid> --description "$(printf 'notes\n#### BINDSNAP-FORCE-RUNNING')"
pct snapshot <vmid> live2                                # running CT, no keyword -> proceeds (standing opt-in)
pct set <vmid> --description "original notes"            # remove the standing opt-in afterwards

# 5. backups still work (the vzdump path is passed straight through to stock)
vzdump <vmid> --mode snapshot --storage <store>

# 6. BINDSNAP-UNSUPPORTED path: only fires when the checksum is NOT in the table. To rehearse
#    it on a recognised node, comment out the table entry and reinstall.
pct stop <vmid>
pct snapshot <vmid> nope2                                 # expect: "pve-container <ver> is not in the tested set ... BINDSNAP-UNSUPPORTED"
pct snapshot <vmid> BINDSNAP-UNSUPPORTED-test                      # name carries the word BINDSNAP-UNSUPPORTED -> proceeds
# (or: pct snapshot <vmid> test2 --description "BINDSNAP-UNSUPPORTED")
# the snapshot succeeds, but the task ends "TASK WARNINGS" (yellow), not "TASK OK" -- it
# prints a WARN line nudging you to report the build. Confirm with: grep WARN/TASK in the
# task log, e.g. tail -1 of the newest /var/log/pve/tasks/.../UPID:*vzsnapshot* file.

# 7. BINDSNAP-EXCLUDE: keep a managed volume out of the snapshot. The CT needs an mpN
#    volume disk (e.g. mp1 -> subvol-<vmid>-disk-1). Set the standing rule in the Notes.
pct set <vmid> --description "$(printf 'notes\n#### BINDSNAP-EXCLUDE: mp1')"
pct stop <vmid>
pct snapshot <vmid> excl1
zfs list -t snapshot | grep subvol-<vmid>-disk-0          # rootfs: expect @excl1
zfs list -t snapshot | grep subvol-<vmid>-disk-1          # mp1: expect NO @excl1
pct listsnapshot <vmid>                                   # the [excl1] section carries the frozen directive
# override for one snapshot: exclude nothing this time
pct snapshot <vmid> excl2 --description "BINDSNAP-EXCLUDE:"   # mp1 IS captured in excl2
# the frozen set survives a later Notes change:
pct set <vmid> --description "notes only, no directive"
pct rollback <vmid> excl1                                 # still rolls back rootfs only, not mp1

# 8. deny-list (hard block): a build on %KNOWN_BAD_CHECKSUMS is refused, and BINDSNAP-UNSUPPORTED
#    canNOT override it. To rehearse on a recognised node, temporarily add this node's
#    combined checksum to %KNOWN_BAD_CHECKSUMS in the module, then reinstall.
pct stop <vmid>
pct snapshot <vmid> nope3                                 # expect: "on the overlay's known-BAD list ... BLOCKED"
pct snapshot <vmid> nope4 --description "BINDSNAP-UNSUPPORTED"     # STILL blocked -- the deny-list is not overridable
```

The refusal messages are worth a read in the task **Output** (GUI) or `pct`'s output: the
untested-build and known-bad refusals print, multi-line, the version, the combined
checksum, the list of tested-good builds, and a link to the
[compatible versions](compatible-versions.md) page (so you can see what to update to). The
one-line `TASK ERROR` is a short summary -- Proxmox flattens a task's error message to a
single line, so the full multi-line detail lives in the Output, with the summary at the end.

A note on the keywords: they are the uppercase tokens `BINDSNAP-UNSUPPORTED` and
`BINDSNAP-FORCE-RUNNING`, matched case-sensitively. A hyphen, an underscore or a space sets
one off: `BINDSNAP-UNSUPPORTED`, `BINDSNAP-FORCE-RUNNING_2026` and `pre-BINDSNAP-UNSUPPORTED` all
match, but gluing onto a letter or digit (`xBINDSNAP-UNSUPPORTED`) or the wrong case does
not. Both also work as a standing line in the CT's Notes; mind that a standing
`BINDSNAP-UNSUPPORTED` silently covers a *future* untested build after a PVE update (the
summary flags it). `BINDSNAP-EXCLUDE` is different: it always takes a colon and a list
(`BINDSNAP-EXCLUDE: mp1`), so it is never underscore-glued.

Confirm the GUI path too, since that's what most people use: the same keywords go in
the snapshot dialog's Name or Description field. And check that routine commands like
`pct list` print no overlay banner (it's suppressed on a terminal).

## Locally

The pure logic (the checksum combine, the keyword matching, the BINDSNAP-EXCLUDE directive
parsing, the bind/device-mount detection, the refusal messages, and the status lines) has
unit tests that run anywhere, plus a wiring test (`t/07-apply-wiring.t`) that stubs the
PVE method surface and drives the redefined snapshot methods + the bind/exclude filter
off-node. No Proxmox required:

```bash
perl -c lib/PVE/LXC/BindSnap.pm   # syntax
prove -I lib t/                          # unit tests
shellcheck install.sh uninstall.sh       # scripts
shfmt -i 4 -d install.sh uninstall.sh    # script formatting
```

CI runs the same four checks on every push (`.github/workflows/ci.yml`).

The latest verification run (off-node and on a test node) is recorded in
[test-results.md](test-results.md).
