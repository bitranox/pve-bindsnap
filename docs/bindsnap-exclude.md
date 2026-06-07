# BINDSNAP-EXCLUDE: leaving managed volumes out of a snapshot

By default the overlay snapshots every Proxmox-managed volume a container has, the
rootfs and any `volume`-type `mpN` data disk, and skips only the bind/device mounts.
`BINDSNAP-EXCLUDE` lets you keep a specific **managed volume** out of the snapshot too, for
example a large or throwaway data disk you don't want versioned with the rootfs.

## The directive

Put a `BINDSNAP-EXCLUDE` line in the container's **Notes** (its description):

```
#### BINDSNAP-EXCLUDE: mp1 mp2
```

- It names mountpoint keys (`mpN`), space- or comma-separated.
- The leading `####` is **optional cosmetic**: Proxmox renders the Notes as Markdown, so
  a heading makes the line small and unobtrusive. Zero to six `#` are accepted, and the
  line can sit anywhere in the Notes, on its own line.
- Only `mpN` keys are honored. **`rootfs` is never excluded** (a snapshot always keeps
  the root disk, and rollback relies on it); an unknown key like `mp9` with no `mp9` is a
  silent no-op.
- The keyword is **uppercase and case-sensitive** (like the other `BINDSNAP-` markers), and it
  always takes the colon: `BINDSNAP-EXCLUDE: ...`. A bare `BINDSNAP-EXCLUDE` with no colon is *not* a
  directive at all (so the CT default still applies); `BINDSNAP-EXCLUDE:` *with* the colon and
  no list is the explicit "exclude nothing".

In a Proxmox guest config every `#`-line is the **description** field, so a `#`-comment
line and the GUI Notes box are the same thing. That's why the directive lives there: it
is free text (never run through the strict mountpoint schema), it is ignored by other
nodes in a cluster, it survives config edits, and the overlay receives it without
patching the Proxmox web GUI, so a Proxmox update can't break it.

## Per-snapshot override

The Notes directive is the persistent default. A `BINDSNAP-EXCLUDE` line in an individual
snapshot's **own description** overrides it for that one snapshot. An empty directive
(`BINDSNAP-EXCLUDE:`) means "exclude nothing this time".

| Container Notes         | This snapshot's description | What's left out of the snapshot |
|-------------------------|-----------------------------|---------------------------------|
| `BINDSNAP-EXCLUDE: mp1` | (nothing about exclude)     | `mp1` (the standing rule)       |
| `BINDSNAP-EXCLUDE: mp1` | `BINDSNAP-EXCLUDE: mp2`     | `mp2` only (override)           |
| `BINDSNAP-EXCLUDE: mp1` | `BINDSNAP-EXCLUDE:` (empty) | nothing (override clears it)    |
| (nothing)               | `BINDSNAP-EXCLUDE: mp2`     | `mp2` (just this snapshot)      |
| (nothing)               | (nothing)                   | nothing                         |

The presence of a directive in the snapshot description, not whether it names anything,
is what triggers the override.

## Frozen into the snapshot

The effective exclude set is **frozen into the snapshot** when it's taken. This matters
for `delete` and `rollback`: those operations don't read the live container config, they
read the **snapshot's own stored config**, whose description carries the directive. So a
later edit to the container's Notes can never change what an existing snapshot rolls back
to or deletes. Each snapshot is self-describing.

Concretely: when the standing CT directive applies, the overlay writes the resolved
`#### BINDSNAP-EXCLUDE: ...` line into the snapshot's stored comment at create time; when the
override comes from the snapshot's own description, it's already there. Either way,
`rollback` rewinds (and `delete` removes) exactly the volumes the snapshot captured, and
leaves the excluded ones as they are.

## Scope

`BINDSNAP-EXCLUDE` takes effect for **bind-mount containers**, the ones the overlay engages
for. A plain container with no bind/device mounts snapshots stock and is left untouched,
so a directive on it has no effect. Bind and device mounts are always skipped regardless;
`BINDSNAP-EXCLUDE` is only about *managed volumes*.

Naming a bind or device mount in the directive is harmless: a non-`volume` mount is
dropped by its type *before* the exclude set is consulted, so the directive simply has
nothing extra to do, and a `devN` key isn't parsed into the set at all. There is no way
for an exclusion to break create, delete, or rollback.

## What you see

Each snapshot, rollback and delete writes a one-line summary to the task log (GUI task
"Output", or `pct`'s output), e.g. `kept rootfs, mp2; excluded mp1 (BINDSNAP-EXCLUDE);
skipped mp3 (bind/device)`, so you can confirm what went in and what was left out. It's
task-log only and never clutters an interactive `pct`.

## Why it's built this way

- **A directive in the Notes, not a key on the `mpN:` line.** Proxmox parses every
  `mpN:` line against a strict schema that rejects unknown keys, and that parser runs on
  *every* container operation: a stray `snapshot=1` would break the container, not just
  snapshots. The description is free text, so it's safe, and (unlike a registered schema
  property) other cluster nodes simply ignore it.
- **Override, not merge.** A per-snapshot directive replaces the CT default outright so
  the result is predictable; the empty form is the explicit "exclude nothing" escape.
- **Frozen at create.** Because delete/rollback see the snapshot's stored config rather
  than the live one, recording the decision into the snapshot is the only way to keep
  those operations consistent with what was captured.
