# Operations — observation and diagnosis

## What to observe

Distinguish the items that are **quiet** when healthy from the items where quiet is
**itself the anomaly**. Failing to tell "no event" from "outside the channel" is the
single most common misjudgement in this system.

| Item | Check | Healthy |
|---|---|---|
| remediation firing rate | `grep 'detected' /var/log/smb/smb-guard.log` | **converging on 0.** Non-zero signals an unmount path other than expiry |
| remediation failures | `remediation failed` in the same log | 0. Investigate immediately if present |
| ghost lock removal | `grep 'stale lock'` | 0. Its appearance means instances are terminating abnormally |
| no GUI session | `grep 'no GUI session'` | normal for a wake in the logout state. **If it appears while logged in**, the `launchctl asuser` path is broken |
| reconnection delay after wake | the `(ls ok, Ns)` in `grep 'mount HEALTHY'` | N in single-digit seconds |
| `falling back to umount` appearing | the same log | **0.** Its appearance means `diskutil` failed — a situation never yet observed |
| log rotation | `ls -la /var/log/smb/` | `.0.bz2` generations appear. If not, check the newsyslog configuration's permissions |
| cruft inflow | `journalctl -u mac-cruft-cleanup --since -7d` | a large count every time signals that client-side suppression is not in effect (not a fault — the cleanup is absorbing it) |
| timer liveness | `systemctl list-timers mac-cruft-cleanup.timer` | `NEXT` is populated |
| guest clock | `chronyc tracking` | System time in milliseconds, Frequency in single-digit ppm |
| steps while awake | `journalctl -u chrony \| grep -i stepped` | **0.** Its appearance means the resume step was late |
| host clock health | `sntp time.apple.com`, monthly | tens of milliseconds. Being off by seconds means setting the guest wrong |
| SMB session leaks | `sudo smbstatus -b` on the guest, once or twice a week | the session count is not monotonically increasing |
| configuration survival | `sudo ./tools/doctor.sh` **right after a major OS upgrade** | exit code 0. An upgrade can revert the autofs trio to defaults, or reset BTM approval and leave a job "file present but not loaded" |

### When you have to look at the event source

The watch daemon **logs only fault states.** Healthy and absent are silent, so
events such as expiry and recycling never appear in its own log. There was an
actual case where an observer concluded "nothing is happening" while 5 events
occurred.

The event source for expiry and recycling is the DiskArbitration log. It **allows
exhaustive retrospective queries, including across a sleep period**, and it records
the mount owner directly as `?owner=UID` (0 = root, anything else = a user).

```bash
log show --last 24h \
  --predicate 'process == "diskarbitrationd" AND eventMessage CONTAINS "<share name>"' \
  --info --style compact | grep -E 'created disk|removed disk'
```

> **Do not read the order of this log at face value.** DiskArbitration's
> asynchronous delivery lag can record `created` after `removed`. Reconstruct the
> sequence from the owner and the surrounding context.

---

## Diagnostic tools

### Host

```bash
sudo ./tools/doctor.sh     # configuration survival check — read-only, sweeps everything at once
smb-guard --state          # side-effect-free state query (no root needed)
mount | grep <mount point> # ownership is determined by the `mounted by` field alone
tail -50 /var/log/smb/smb-guard.log
smbfix                     # when automatic recovery has failed
smbutil statshares -a
```

**The `//account@host/share` notation is a trap** — it is the SMB authentication
account, not the mount owner.

```bash
# The automount layer
log show --last 10m --predicate 'process == "automountd" OR process == "mount_smbfs"' --info

# Power events (primary evidence for Layer 2 determination)
pmset -g log | grep -E "Entering Sleep|Wake from|DarkWake" | tail

# Job residency and last exit code
launchctl print system/<prefix>.sleepwatcher

# Real-time file access tracing
sudo fs_usage -w -f filesys | grep '<mount point>'
```

When using `fs_usage`, **close the Time Machine pane in System Settings.** Left
open, its 64-second polling takes over 90% of the log.

`does not support SMB FullFSync` is the trace of a Time Machine family probe.

### Finder copy failures (-8062)

**The Finder dialog does not tell you which path failed.** Without this channel you
will misdiagnose it as a permissions or capacity problem.

```bash
log stream --predicate 'subsystem == "com.apple.DesktopServices"' --info
#  on reproduction:  Error -8062 at path: <path> on write

# Retrospective query
log show --last 30m --predicate 'subsystem == "com.apple.DesktopServices"' --info \
  --style compact | grep -E '8062|on write'
```

Checking whether the client-side suppression is in effect:

```bash
defaults read /Library/Preferences/com.apple.desktopservices DSDontWriteNetworkStores  # system
defaults read com.apple.desktopservices DSDontWriteNetworkStores                       # user
```

**Even with one of them set to 1, the CopyEngine can still write `.DS_Store`.** Do
not use it as grounds for "it is set, so they will not appear" — a file already
present in the source is outside the suppression's remit.

### Archive extraction failures (Error 1) and permission wreckage

The Archive Utility chmods its own destination directory to 0644 on an SMB volume
and aborts (Layer 8). Do not use it on the mount — `ditto -xk <archive> <dest>`
and `unzip` extract correctly.

```bash
# a dimmed folder it left behind — recover from the Mac
chmod u+rwX '<folder>'
```

The mode-0000 class (every open denied — Layer 8) is recoverable only on the
guest: `find <workspace> -perm 0` to detect, `chmod -R u+rwX` to free. The chmod
channel itself is visible at `log level = 10` in the smbd log as
`MS NFS chmod request`.

### Guest

```bash
journalctl -o short-iso --since "<t1>" --until "<t2>"
#   `Clock change detected` = the moment of the step,  smbd pam_unix = session open/close
sudo smbstatus -b
chronyc tracking
journalctl -u mac-cruft-cleanup -n 20
sudo /usr/local/sbin/mac-cruft-cleanup <path>     # one manual run (idempotent)
testparm -s 2>/dev/null | grep -E '^\s*veto files'   # must be 0 lines
```

**Three traps:**

- Journal timestamps are **on the guest's clock** during a skew. Take care when
  correlating with host logs.
- Give `--since` an explicit date (the midnight trap).
- `pmset sleepnow` may not lead to an actual sleep — confirm afterwards with
  `pmset -g log`.

### Determining time synchronisation

`systemctl status prltoolsd` and `ss --vsock` are **not indicators of anything
guaranteed.** A 21-hour skew went through while they showed a green light.

The primary indicators are `journalctl | grep 'Clock change'` and
`chronyc tracking` on the guest, and the direct comparison is running `date` on the
host and the guest.

---

## Notes

The `sudo` authentication cache is 5 minutes per tty (the `timestamp_timeout`
default). Not being asked for a password during back-to-back tests is that cache,
not proof that a rule is in effect. Expire it immediately with `sudo -k`.

The permission criteria of the `sudo` runtime and of `visudo -c` differ. `visudo`
demands 0440, but sudo's actual check is whether the file is group/other writable —
there was a case where a 0640 file worked fine. **Reading the warning as "the rule
is void" is a misjudgement.** Query what is actually in effect with
`sudo -l -U <account>`.
