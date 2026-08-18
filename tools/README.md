# Diagnostic and historical tools

**Not deployment targets.** The installer does not place them; run them from this
directory.

Two kinds are mixed here. **`doctor.sh` and `probe-rename-collision.sh` are in
active use** — worth re-running whenever the configuration changes. The rest have
finished their job; they are kept because the documentation cites their output as
evidence, and deleting them would cut that evidence off.

## `doctor.sh` (active)

Survival check of the host (macOS) configuration. **Read-only** — it fixes nothing
and only prints the remedy command for each item (Principle 21 — audit, but never
remediate automatically).

Its main use is **detecting reversion right after a macOS major upgrade**. An
upgrade can undermine this system's premises from two directions:

- `/etc/auto_master` and `/etc/autofs.conf` are Apple-distributed files and can
  revert to defaults. The autofs trio is exactly the area the installer does not
  manage, so a single reinstall does not restore it — which is why the check is a
  tool separate from the install.
- When Background Items approval (BTM) is reset, a LaunchDaemon ends up **"file
  present but not loaded"**. The verdict comes from `launchctl`'s actual load
  state, not from file existence.

Beyond that it looks at ownership and permissions of the deployed files (wrong
ones are silently ignored), content drift against the repo, newsyslog
registration, guest ssh in a root context (the top-priority check), and the mount
state.

```bash
sudo ./doctor.sh                  # complete verdict (root)
./doctor.sh                       # root-only items are marked as skipped
```

| Exit code | Meaning |
|---|---|
| 0 | everything within the checked scope is fine (WARNs may be present) |
| 1 | one or more faults |
| 2 | no faults, but root-only items were skipped — verdict incomplete |

Why 0 and 2 are distinguished: the silence of a skipped item must not be read as
healthy (Principle 25). Limits — for autofs it only reads file contents (whether
`automount -vc` has been applied cannot be determined read-only). Whether the
StartOnMount hook is actually armed cannot be distinguished via `launchctl print`,
so verification that includes mount behaviour follows the 'Verification' procedure
in [install.md](../docs/install.md).

## `probe-rename-collision.sh` (active)

Determination and regression check for
[Layer 6, share root name collision](../docs/failure-model.md#layer-6--share-root-name-collision).
It fetches the share root's entry
names from the guest and actually attempts an overwriting rename with each of them
on the mount. **The names that fail are exactly the contaminated basename set** —
existing files with those names cannot be overwritten or deleted anywhere in the
tree.

```bash
./probe-rename-collision.sh                 # reads /usr/local/etc/smb-guard.conf
./probe-rename-collision.sh --config ./smb-guard.conf
```

What counts as a pass depends on the layout.

| Layout | Expected result | Exit code |
|---|---|---|
| share root = workspace (unremediated) | **nearly every name at the root fails** — the state in which `.git/config` breaks | 1 |
| share root = above the workspace (remedy applied) | **only the workspace name fails**, shown as `expected residue` | **0** |
| raised layout but other names fail too | something other than the workspace appeared at the share root | 1 |

**The expected residue is not counted as contamination.** In a raised layout the
workspace's own name remaining is normal, and reporting it as contamination would
make the healthy state raise an alarm every time, so real faults would get ignored
along with it (Principle 23).

No root needed, and it deletes nothing. **The measurement is only valid if the
control succeeds** — if even the control fails, the problem is the mount or
permissions, not this defect (Principle 25).

Reclamation happens on the guest. The temporary directory contains contaminated
basenames, so **an `rm -rf` from the Mac would catch the cleanup itself in the same
defect** — a case this tool demonstrated on itself.

## `experiment-layer8-nfs-aces.sh` (pending experiment)

The guest-side switch for the
[Layer 8](../docs/failure-model.md#layer-8--client-permission-writes-are-applied-verbatim-with-no-server-side-floor)
blocking experiment (docs/open-questions.md, 'fruit:nfs_aces in [global]').
`fruit:nfs_aces` is a global-only option and the per-share `no` this repository
shipped was a silent no-op; this tool arms it where it actually lives.

Run **on the guest, as root** — unlike the probes, it changes the running Samba
configuration, which is exactly why it exists as a reviewed script rather than ad
hoc commands. `--apply` backs up `smb.conf`, comments out any per-share line,
inserts the option into `[global]`, validates with testparm before touching the
live file, and restarts smbd. `--revert` restores the backup. Both remind you of
the trap that invalidates the measurement: AAPL capabilities are negotiated once
per session, so the Mac must unmount everything and reconnect before any
observation counts.

```bash
sudo ./experiment-layer8-nfs-aces.sh --apply
sudo ./experiment-layer8-nfs-aces.sh --revert
```

## `probe-layer4b.sh`

A one-off tool for narrowing down the cause of
[Layer 4b](../docs/failure-model.md#layer-4b--umount-refused-in-a-daemon-context-cause-undetermined),
where `umount -f` returned EPERM only in a daemon context. It stops the watch daemon, creates
an ownership fault artificially, and then attempts an unmount in two rounds
(delayed, then immediate).

With this tool 2 of 5 hypotheses were rejected (the mount's owner, and timing), and
as a by-product it revealed **that hijacking is a race** — when a user process
triggered first in the empty window right after an unmount, the ownership fault was
never created at all. A case where a failed reproduction became the explanation for
the intermittency.

The hazards of a reproduction experiment are still there (stopping the watch,
unmounting artificially), so use it only when investigating a recurrence. It
restores the daemon and the mount via an EXIT trap.

It reads `smb-guard.conf` the same way `doctor.sh` does — the deployed copy first,
then the repo's, with `--config <path>` to override. Since it stops a deployed
launchd job and calls the deployed `smb-guard`, its target is always an
already-deployed environment, so a missing configuration is a hard failure rather
than something to guess around.

## `cleanup.sh`

A migration tool that reclaims the old deployment scattered around the home
directory (user-domain hooks, the brew service, the split logs). That migration is
finished, so **a fresh installation never needs it.**

It is kept because it is the source of two lessons.

- **Under `set -e`, an assignment from a command substitution exits the shell
  silently.** A cleanup script that dies without a word leaves a partially deleted
  state — the worst failure mode there is. -> Principle 20
- **The EXIT trap false-positived.** When the last statement is `[ cond ] && cmd`
  and cond is false, that 1 becomes the script's exit code and a normal completion
  is reported as an error. If the mechanism that announces failure
  false-positives, the next real failure gets ignored too. -> Principle 23

The design of **auditing sudoers without remediating it** came from here as well.
"Fixing" a file that has been ignored because its permissions were wrong means
newly opening a privilege that was never granted (Principle 21).

```bash
sudo ./cleanup.sh --owner <account>              # dry-run
sudo ./cleanup.sh --owner <account> --apply      # actually delete (backs up first)
```

The owner account comes from `--owner`, or from `SMBG_OWNER` in `smb-guard.conf`
when that is available. **Unlike the other tools, the configuration file is not
required here** — the people who need this tool are migrating from a v13
deployment, and configuration externalisation only arrived in v1.0.0, so requiring
it would lock out exactly the users it exists for.

It is dry-run by default; `--apply` is required to actually delete, and it backs
things up before deletion. A failed account lookup is a hard failure with no
fallback UID: the account's UID selects the launchd domain to `bootout`, and a
guessed one would target an unrelated user.
