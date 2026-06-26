# AI transparency

The author and owner of this project is the human, [@bitranox](https://github.com/bitranox).
Every design and engineering decision is theirs, and they answer for everything published
here. An AI assistant (Claude, run through the Claude Code CLI) was used as a tool along the
way, mostly for the typing and the legwork under that direction. This page says where, plainly,
so you can weigh the work on its merits. The reasoning behind working this way is in
[ai-stance.md](ai-stance.md).

## The human's work

The shape of this software is the human's, start to finish. They set the problem, made every
call, and own the result.

- The problem is theirs: a real Proxmox cluster with a privileged container whose nine bind
  mounts blocked snapshots.
- Every design and architecture decision was the human's: loading the overlay by diverting
  `PVE::LXC::Config` so it covers the GUI, API and `pct` alike; gating on a checksum of the
  upstream source, not a version string, with a tested-good allow-list and a hard-block
  deny-list; keeping both checksum and version but deciding on the checksum alone; per-snapshot
  `BINDSNAP-FORCE-RUNNING` and `BINDSNAP-UNSUPPORTED` keywords, kept visible in the stored comment; the `BINDSNAP-EXCLUDE`
  directive for leaving managed volumes out; a verbose per-operation task-log summary; gating
  and filtering only the containers that have bind/device mounts; keeping the docs generic.
  Where there were options, the human picked.
- Clone support (release 1.1.0) was the human's call too: the design doc that scoped it, the
  decision to gate it on its own separate checksum, and -- when the AI flagged that the failing
  `clone_vm` is a `register_method` closure rather than a named sub (so the snapshot overlay's
  typeglob trick wouldn't fit) -- the human's direction to settle the override mechanism
  empirically on the node. The AI investigated and proposed; the human chose.
- Shipping an AI-agent skill was the human's call: that the repo should carry a `proxmox-bindsnap`
  Claude Code skill so an agent can install and configure pve-bindsnap, how it should be delivered
  (the repo as its own plugin/marketplace and as a copy-in skill, and mirrored into the separate
  bitranox-skills marketplace), and the skill's name. The AI wrote the skill and the manifests to
  that brief.
- The human reviewed and corrected the work at each step; what ships is what they signed off on.
- The hardware and the go-ahead are the human's: the install and the full test run were carried
  out on the human's own test node, each step authorized by the human (the development box used
  for the code is not a Proxmox node).
- Every commit went out under the human's name and authority, with no AI co-author line. The
  human is responsible for what is published.

## Where the AI was used

As a tool, under the human's direction, it did the mechanical parts: reading and tracing the
Proxmox snapshot path to find the one primitive to wrap (`foreach_volume_full`); for clone,
tracing `PVE::API2::LXC::clone_vm` to the inline bind-mount die and confirming on the node how
its registered method could be overridden in place (`map_method_by_name`); typing the module,
the two wrappers, the scripts, these docs and the unit tests to the human's design; laying out
options at each fork for the human to choose from; and grinding through the variants and the
off-node checks. On the human's own test node, with their explicit go-ahead at each step, it
also carried out the install and ran the full test matrices -- snapshot (create, rollback
verified at the file level, delete, the BINDSNAP-FORCE-RUNNING and BINDSNAP-UNSUPPORTED paths)
and clone (the baseline bind-mount failure reproduced, the carried-mount and BINDSNAP-EXCLUDE
cases, and the version-change fallback) -- and read the upstream checksums to seed the tables.
For the agent skill, it wrote the self-contained `proxmox-bindsnap` runbook and the
plugin/marketplace manifests, mirrored an identical copy into the bitranox-skills marketplace,
and pressure-tested the skill with throwaway subagents (install, clone-exclude, untested-build,
greyed-snapshot) to confirm an agent following it acts correctly and safely.
None of the decisions, and none of the accountability, were the AI's -- the human directed and
approved every action and owns the result.

## What's been checked, and what hasn't

Off the node, the module passes `perl -c`, the scripts are clean under `shellcheck` and
`shfmt`, and the unit tests (`prove -I lib t/`) cover the checksum combine (it reproduces both
the documented `sha256sum` pipeline and the real value from a cluster node), the `BINDSNAP-FORCE-RUNNING` and
`BINDSNAP-UNSUPPORTED` matching, the `BINDSNAP-EXCLUDE` directive parsing, which containers the overlay
engages for (bind/device mounts versus plain volumes), the status messages, and the clone
carry/exclude decision, summary, warning and override wiring.

On the node: it has been installed and exercised on a test node (Proxmox VE 9.2,
pve-container 6.1.10) across the full [test plan](docs/testing.md): stopped create, rollback
(verified at the file level) and delete, the running-container `BINDSNAP-FORCE-RUNNING` path, the `BINDSNAP-UNSUPPORTED`
refusal, the `BINDSNAP-EXCLUDE` cases, and the task-log summaries. Clone was verified the same
way: `pct clone` of a bind-mount container failing on stock first, then carrying the bind
mounts (and dropping a `BINDSNAP-EXCLUDE`'d one) once the override is in, plus the version-change
fallback (a perturbed upstream disables the override rather than running a stale copy). Beyond
that test node, it runs in the author's own production cluster on the same pve-container build.

## Checking it yourself

The module is a single, heavily commented file. For snapshots the only clever part is the thin
filter around `foreach_volume_full`; everything else hands off to the live Proxmox methods. The
one exception is clone: because the bind-mount die sits inline in `clone_vm` with nothing to
wrap, the overlay installs a copy of that one method with the single carry-or-exclude change.
That copy is honest about being a copy -- it is gated by its own checksum of the file it came
from, so on any build it hasn't been vetted against it simply isn't installed and `pct clone`
stays stock. It is the one place the overlay doesn't delegate, and it is fenced off accordingly.

It delegates rather than forks. The divert renames the genuine `Config.pm` aside (never edits
its contents) and the wrapper loads the real upstream from there plus the overlay; the overlay
load is eval-guarded, so a bug in it can't stop `Config.pm` from loading. On a build it doesn't
recognise, bind-mount CT snapshots are refused unless you opt one in with `BINDSNAP-UNSUPPORTED` (and a
deny-listed build is hard-blocked); containers without bind/device mounts snapshot stock
regardless. `uninstall.sh` reverts the divert and you have stock Proxmox.

The tests need no Proxmox: `prove -I lib t/`. `install.sh` installs the overlay module, diverts
`PVE::LXC::Config` (snapshots) and `PVE::API2::LXC` (clone), and puts a thin wrapper in place of
each; `uninstall.sh` takes it all back out.
The [design notes](docs/design.md) are honest about the limits (per-node only; the
bind/device data isn't versioned) and point at the plain `zfs snapshot` alternative.

## What this isn't

It isn't a Proxmox product, and Proxmox hasn't reviewed or endorsed it. It's release
1.1.0, run in production on the author's own cluster, though not widely deployed and only on
pve-container 6.1.10 so far, not other versions. And it isn't a way to avoid understanding your
own hypervisor: if you install it, read the [design notes](docs/design.md) and the module so you
know which method it wraps and why. Though the risk is low, as already described in the README.

## License and attribution

The text and code here are under the GNU Affero General Public License v3.0 (see
[`LICENSE`](LICENSE)). Anthropic's terms put ownership of model output with the user, so the
human owns this and answers for it. Under the AGPL, anyone who passes it on, including network
and server operators of modified copies, keeps the attribution and hands on the same license
with the source.
