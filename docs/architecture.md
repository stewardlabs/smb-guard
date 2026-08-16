# Architecture

Each component does **only what it alone can do, with information only it has.**
Every component is event-driven or a resident daemon; there is no periodic polling —
except the guest's cruft cleanup, which is a timer (because what it reclaims
generates no events).

## Role split

| Component | Trigger | Responsibility | Does not do |
|---|---|---|---|
| `smb-guard` (watch) | mount event | immediate remediation of ownership faults | creating mounts, the clock |
| `smb-guard-sleep` | just before sleep | records the sleep time plus one state line | unmounting |
| `smb-guard-wakeup` | wake | gate -> network wait -> clock -> mount assurance -> liveness | ownership determination and remediation (-> guard) |
| `smbfix` | a human | clock correction + forced remount + diagnosis | its own mount logic (-> guard) |
| guest NTP | continuous | clock correction while awake | — |
| `clockfix` | wakeup / smbfix | immediate step right after resume | — |
| `mac-cruft-cleanup` | timer (15 min) | cruft reclamation | blocking |

### Why the sleep hook does not unmount

The time macOS grants a `-s` hook is short and not guaranteed. Attempting network
I/O or an `umount` there can be cut off by sleep proceeding, and **an interrupted
unmount leaves an even worse intermediate state.** On top of that, unmounting
reopens the hijacking window.

This system's recovery strategy is **repair on the wake side.** The sleep side
records only the facts the wake side needs for its decision (the time of the last
sleep, and the state at that moment).

## The `smb-guard` contract

It has four modes.

| Mode | Caller | Behaviour |
|---|---|---|
| (default) `watch` | LaunchDaemon (`StartOnMount`) | remediates faults only. **Never creates a mount** |
| `--ensure` | `smb-guard-wakeup` | includes creation when absent |
| `--remount` | `smbfix` | forced remount regardless of state |
| `--state` | humans and scripts | prints the determination only. No side effects, no root |

**The contract:**

- Determination reads the mount table only (presence of `mounted by <owner>`). Path
  access is never used for it.
- The only trigger is one directory `open` (i.e. `ls`) with the owner's
  credentials. **The exit code of `ls` is ignored**; success is determined by
  re-reading the mount table.
- The new mount event produced by watch's remediation re-fires the script itself,
  but the re-fired instance sees a healthy state and exits silently, so the loop
  terminates. A `mkdir` lock plus `ThrottleInterval 5s` are the two lines of
  defence.
- **`--ensure` and `--remount` wait on lock contention and return failure if they
  never get it.** These are the paths whose result the caller trusts, so silent
  success is forbidden. `watch`, by contrast, backs off immediately when it cannot
  take the lock — that means another instance is already handling it, which makes
  backing off the correct behaviour.
- **The lock has an expiry.** When an instance dies from `SIGKILL` the EXIT trap
  never runs, the lock survives forever, and from then on everything goes silent —
  an asymptomatic failure that leaves nothing in the log either. A lock past the
  threshold (120 seconds) is treated as cruft, removed, and its removal is logged.
- The impossibility of triggering without a GUI session is stated explicitly in the
  log. `launchctl asuser` fails at the logout state, and passing that over silently
  would make it look like a remediation failure of unknown cause.

### The unmount fallback chain

```
stage 1  diskutil unmount force   -> delegates to DiskArbitration. Less dependent on the caller's context
stage 2  umount -f                -> direct kernel call. The safety net for a diskarbitrationd failure
```

In the hook context stage 1 effectively always finishes the job. Stage 2 appearing
in the log is **the signal that stage 1 failed**, a situation never yet observed —
investigate it.

## Privilege domains

Every component runs in the launchd **system domain** (root). Four points need user
credentials, and switch to them explicitly.

| Call | Why user credentials are needed | Means of switching |
|---|---|---|
| `ssh <guest>` | the alias and key in `~/.ssh/config` belong to the owner | `sudo -u <owner> -H` |
| user hook `open` | needs a GUI session (Aqua) | `launchctl asuser` |
| trigger and liveness `ls` | accessibility from the owner's viewpoint is what is being measured | `launchctl asuser` |
| the manual tool's `mount_smbfs` probe | **SMB credentials in the login keychain** | `launchctl asuser` |

The last one matters most. In a root context the login keychain is locked and
cannot be read, which produces **a misdiagnosis of authentication failure unrelated
to the actual cause.**

The wrappers are written to hold in both domains — if already the owner they run
directly without `sudo`; as root they run directly, otherwise via `sudo -n`.
**Moving back to the user domain (a LaunchAgent) would work without code changes.**

> **Top-priority check after installation**: `sudo -u <owner> -H ssh` does not
> inherit `SSH_AUTH_SOCK`. If the key has a passphrase and relies on ssh-agent,
> `BatchMode=yes` fails and **clock correction is disabled entirely.**
>
> If it fails, the options are: (1) point the owner's `~/.ssh/config` at a
> dedicated key without a passphrase, or (2) keep sleepwatcher as a user-domain
> LaunchAgent.

## Logging

Unified into a single `$SMBG_LOGDIR/smb-guard.log`, distinguished by tags.

```
2026-08-08 14:23:01 [wakeup +12s] network up
2026-08-08 12:19:18 [watch] FOREIGN detected — starting remediation
2026-08-08 12:19:19 [watch] diskutil unmount force succeeded → state=ABSENT
2026-08-08 12:19:20 [watch] trigger ls EPERM (expected — Layer 3, open already happened) → state=HEALTHY
2026-08-08 12:19:20 [watch] remediation complete → HEALTHY
```

**The state transitions have to be reconstructable from the log alone.** Letting
subcommand output flow through verbatim inserts untagged lines between tagged ones,
which makes an expected failure (the one that induces the fallback)
indistinguishable from a real one. The original text is not discarded but squashed
onto one line and carried inside the tag, and expected failures are marked
"(expected)".

Hook scripts absorb stdout as well with `exec >>"$LOG" 2>&1` — **an untagged line
is itself the signal that something leaked**, which helps diagnosis. The plist's
`StandardOutPath` and `StandardErrorPath` point at the same file so that failures
before the script reaches its `exec` (a bad shebang, for instance) are caught too.

## Configuration

Environment-specific values come from the configuration file, not from the code.

```
host   /usr/local/etc/smb-guard.conf
guest  /etc/smb-guard.conf
```

Anything that has to be baked in at deployment time (the LaunchDaemon Label,
systemd's `ConditionPathIsDirectory` and `ReadWritePaths`, the newsyslog paths, the
Samba share definition) is generated by the installer substituting a `*.in`
template — systemd does not expand environment variables in those fields.

**The configuration file must be a real file.** If a symlink pointed it at a
canonical copy inside the workspace, the means of recovery would vanish the moment
the very mount this system recovers went away.

## The guest side

| Component | Role |
|---|---|
| the Samba share | `vfs_fruit` + `streams_xattr`. **No blocking (`veto files`)** |
| `clockfix` + sudoers | the host hook calls it non-interactively, so NOPASSWD is required |
| `mac-cruft-cleanup` + timer | cruft reclamation every 15 minutes. Leaves the removal count in journald |
| the NTP daemon | standing authority while awake |

The cleanup timer is **monotonic** (`OnBootSec` + `OnUnitActiveSec`). `Persistent=`
is for `OnCalendar` only; on a monotonic timer it is silently ignored, leaving
nothing but the false impression that "missed runs are caught up" — so it is not
set. One run happens 5 minutes after boot, which already covers downtime.

The cleanup script **prints nothing when the count is zero.** That means a quiet
log is the healthy state, but the price is that "quiet because there was nothing to
do" and "quiet because it is broken" are indistinguishable in the output — when
demonstrating it, run it with reclamation targets deliberately left in place.
