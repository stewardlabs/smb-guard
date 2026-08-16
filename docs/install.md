# Installation and verification

## Prerequisites

**Host (macOS)**

- The workspace mounted as an **autofs direct map**
- `brew install sleepwatcher` — **do not register it as a brew service.** This repo
  deploys its own LaunchDaemon (see [decisions.md](decisions.md) for why)
- **Key-based, non-interactive** ssh to the guest

**Guest (Linux)**

- Samba, systemd
- The workspace path exists
- **A static IP**, with the guest's name resolving to that address from the host (a
  static entry in the host's `/etc/hosts` is recommended). Both the mount URL and
  the ssh alias depend on that resolution, and the wake hook's clock correction
  rides on that ssh
- **Do not install the hypervisor's guest integration tools (Parallels Tools and
  the like).** Their time synchronisation is mutually exclusive with guest NTP
  ([failure-model.md](failure-model.md) Layer 1), and in a headless setup the
  remaining features are either unnecessary or unused by this design. If they are
  already installed, removal is recommended — the rationale and procedure are in
  'The stronger remedy' under Layer 1
- **Put the share root above the workspace** (recommended —
  [failure-model.md](failure-model.md) Layer 6). Bind mount the workspace so it
  appears beneath `SMBG_EXPORT_ROOT`:

  ```bash
  sudo install -d -o <owner> -g <owner> -m 755 /srv/ws /srv/ws/<workspace name>
  echo '<workspace path> /srv/ws/<workspace name> none bind,x-systemd.requires-mounts-for=<workspace path> 0 0' \
    | sudo tee -a /etc/fstab
  sudo systemctl daemon-reload && sudo mount /srv/ws/<workspace name>
  ```

  This repo does not touch `/etc/fstab` (the same policy as not touching autofs).
  `guest/install.sh` only checks, and stops with the commands above if it is missing.

### autofs configuration — what this repo does not touch

The mount itself belongs to autofs; smb-guard operates on top of it. Get these three
files right first.

```text
# /etc/auto_master  — register the direct map
/-    auto_smb    -nosuid
```

```text
# /etc/auto_smb  (600 root)
<mount point>  -fstype=smbfs,soft,nodatacache  ://<account>:<URL-encoded password>@<guest>/<share>[/<subpath>]
```

`soft` is **mandatory.** An absent server has to fail within finite time rather than
wait forever; it is the premise on which `SMBG_TRIGGER_TIMEOUT` and the wake hook's
wait bounds rest.

`nodatacache` is **mandatory** in a setup where the Mac reads guest-local writes.
The client data cache has no way of seeing a server-local write, so cached content
goes stale indefinitely (failure-model.md Layer 7), and this option removes that
layer entirely. The measured cost is zero — for the rationale and the rejected
alternatives (nomdatacache, server-side kernel oplocks) see Layer 7. It can be
dropped for a purely consuming mount that is never written from the guest.

`<subpath>` is used in the layout with the share root above the workspace
(`SMBG_SHARE_SUBPATH`). **Check it manually once before editing the map** —
mounting a subdirectory through automountd is not as well tested as calling
`mount_smbfs` directly:

```bash
mkdir -p /private/tmp/wstest
mount_smbfs //<account>@<guest>/<share>/<subpath> /private/tmp/wstest && ls /private/tmp/wstest
umount /private/tmp/wstest
```

```ini
# /etc/autofs.conf
AUTOMOUNT_TIMEOUT=604800     # removes the expiry window (default 3600 — failure-model.md Layer 0)
AUTOMOUNTD_MNTOPTS=nosuid,nodev
AUTOMOUNTD_NOSUID=TRUE
```

**Editing the files alone does not apply them.** The values are baked in when the
trigger is regenerated, so `sudo automount -vc` is mandatory. Note that
`AUTOMOUNT_TIMEOUT` is a global setting.

---

## Installation

```bash
cp smb-guard.conf.example smb-guard.conf
$EDITOR smb-guard.conf

./install.sh --dry-run        # check the deployment plan
./install.sh                  # host (sudo) -> guest (ssh -t sudo)
```

**Run it as a normal user.** Privilege elevation happens separately at each stage —
running the whole thing under `sudo` makes ssh look at root's `~/.ssh`, so the guest
alias will not resolve.

Guest deployment **needs a terminal (TTY)** for the remote sudo password. In an
environment without one (wrapped in a script, say) it stops early and says so.

Partial runs:

```bash
./install.sh --host           # host only
./install.sh --guest          # guest only
./install.sh --guest --samba  # guest plus the Samba configuration (existing file backed up)
```

The Samba configuration is not deployed by default; the **substituted result is
printed** instead, because overwriting an existing `smb.conf` wholesale would lose
settings unrelated to this share.

## Manual placement

You do not have to use the script. But **the permissions have to be exact** — wrong
ones are silently ignored.

**Host**

| Source | Destination | Owner and permissions | If wrong |
|---|---|---|---|
| `smb-guard.conf` | `/usr/local/etc/smb-guard.conf` | `root:wheel 644` | the scripts fail at startup |
| `host/lib/common.sh` | `/usr/local/lib/smb-guard/common.sh` | `root:wheel 644` (**no exec bit**) | — |
| `host/sbin/*` | `/usr/local/sbin/` | `root:wheel 755` | group/other writable is a privilege escalation vulnerability |
| `host/LaunchDaemons/smb-guard.plist.in` | `/Library/LaunchDaemons/<prefix>.smb-guard.plist` | `root:wheel 644` | **launchd refuses to load it** |
| `host/LaunchDaemons/sleepwatcher.plist.in` | `/Library/LaunchDaemons/<prefix>.sleepwatcher.plist` | `root:wheel 644` | same |
| `host/newsyslog.d/smb.conf.in` | `/etc/newsyslog.d/<prefix>.smb.conf` | `root:wheel 644` | **silently ignored — the log grows without bound** |

The `*.in` files are templates. Replace `@LABEL_PREFIX@`, `@LOGDIR@` and
`@SLEEPWATCHER_BIN@` with the real values. **The plist filename and the `Label`
value inside it must agree.**

The sleepwatcher path differs by architecture — Apple Silicon
`/opt/homebrew/sbin/sleepwatcher`, Intel `/usr/local/sbin/sleepwatcher`.

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/<prefix>.smb-guard.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/<prefix>.sleepwatcher.plist
```

**Guest**

| Source | Destination | Owner and permissions |
|---|---|---|
| `smb-guard.conf` | `/etc/smb-guard.conf` | `root:root 644` |
| `guest/sbin/*` | `/usr/local/sbin/` | `root:root 755` |
| `guest/systemd/*.in`, `*.timer` | `/etc/systemd/system/` | `root:root 644` |
| (generated) | `/etc/sudoers.d/clockfix` | `root:root 0440` <- **sudo refuses anything else** |
| `guest/samba/smb.conf.in` | merged into `/etc/samba/smb.conf` | `root:root 644` |

```text
# /etc/sudoers.d/clockfix — the argument wildcard is there to accept the epoch value (integer or fractional)
<ssh account> ALL=(root) NOPASSWD: /usr/local/sbin/clockfix *
```

```bash
sudo visudo -c -f /etc/sudoers.d/clockfix     # check before deploying
sudo systemctl daemon-reload
sudo systemctl enable --now mac-cruft-cleanup.timer
```

---

## Verification

### Everything at once — `tools/doctor.sh`

There is a read-only inspection tool that sweeps deployment, permissions, load state
and autofs in one go. It replaces the static parts of the individual procedures
below (0, 1 and part of 3), and **right after a macOS major upgrade you run this
first.**

```bash
sudo ./tools/doctor.sh          # 0 healthy / 1 faults / 2 verdict incomplete (root-only items skipped)
```

It fixes nothing and only prints the per-item remedy (Principle 21). **Two things it
does not replace**: whether the autofs configuration has been *applied*
(`automount -vc`) and whether the mount hook is actually armed cannot be determined
read-only. Items 2, 4 and 6 below still have to be checked by hand. For the detailed
criteria see [tools/README.md](../tools/README.md).

### 0. Top priority — guest ssh in a root context

**Stop here if it fails.** Clock correction is disabled entirely.

```bash
sudo -u <owner> -H ssh -o BatchMode=yes -o ConnectTimeout=3 <guest> 'date +%s'
#  expected: an epoch number
```

### 1. Job registration state

```bash
sudo launchctl print system/<prefix>.sleepwatcher | grep -Ei 'state|last exit'
#  expected: state = running   (resident via KeepAlive)

sudo launchctl print system/<prefix>.smb-guard | grep -Ei 'state|last exit|runs'
#  expected: state = not running / last exit code = 0
```

**`not running` is the healthy state.** launchd's state only tells you "is a process
up right now"; there is no "waiting for an event" state. Zero processes is normal
for a mount hook most of the time.

> `StartOnMount` is an internal launchd key and is not exposed as an event channel
> in `print` output. **`print` cannot distinguish "registered but the hook is not
> armed" from healthy** — causing an actual mount is the only verification (item 2
> below).

### 2. Whether the hook is actually armed — check with an unrelated mount

```bash
hdiutil create -size 10m -fs APFS -volname SGTEST /tmp/sgtest.dmg
hdiutil attach /tmp/sgtest.dmg
sleep 3
sudo launchctl print system/<prefix>.smb-guard | grep -Ei 'runs|last exit'
#  expected: runs increased (= the hook is armed), last exit code = 0
tail -5 /var/log/smb/smb-guard.log
#  expected: no new entries (it stays silent for unrelated mounts)
hdiutil detach /Volumes/SGTEST && rm /tmp/sgtest.dmg
```

Because of `ThrottleInterval 5s`, a mount within 5 seconds of the previous run may
have its firing delayed.

### 3. State query and log rotation

```bash
smb-guard --state                     # expected: HEALTHY
sudo newsyslog -nv | grep /var/log/smb # expected: 3 files listed
```

If 3 do not appear, check the permissions of the `newsyslog` configuration file
(`root:wheel 644`).

### 4. Remediation behaviour — artificial hijacking

```bash
sudo umount -f <mount point>
sudo /bin/ls <mount point> > /dev/null       # induce a root-owned mount
sleep 8
mount | grep <mount point>                    # expected: mounted by <owner>
tail -5 /var/log/smb/smb-guard.log            # expected: detected -> remediation complete
```

**The reproduction can fail** — if a user process triggers first in the empty
window, hijacking never happens. That is not a fault but the normal behaviour of a
[race](failure-model.md#layer-4--root-owned-mount-hijacking). To reproduce it
reliably, first close the processes touching the workspace (editors, LSPs, file
watchers, other shells' cwd).

### 5. Creation from absent

```bash
sudo umount -f <mount point> && sudo smb-guard --ensure
smb-guard --state                            # expected: HEALTHY
```

### 6. A real sleep — hook firing

```bash
# Actually put it to sleep by closing the lid
tail -40 /var/log/smb/smb-guard.log
#  expected: one [sleep] line -> several [wakeup +Ns] -> mount HEALTHY (ls ok, Ns)
```

> **Trap**: if the gate skips with `slept for 1s`, suspect that it never slept. On AC
> power the "no sleep after screen lock" policy prevents a second sleep, so forcing
> one sleep with `pmset sleepnow` and immediately waking leaves the machine awake.
> After that, pressing a key produces no wake event and nothing more is logged —
> **the hook is not broken.**
>
> To tell: if `pmset -g log | grep -E "Entering Sleep|Wake from|DarkWake" | tail`
> shows `Entering Sleep` only once, it never slept.

### 7. Confirming the expiry window is gone

After leaving it mounted and idle for more than 65 minutes:

```bash
log show --last 2h --predicate 'process == "diskarbitrationd" AND eventMessage CONTAINS "<share name>"' \
  --info --style compact | grep -E 'created|removed'
#  expected: no removed
```

### 8. Guest

```bash
ssh <guest> 'systemctl list-timers mac-cruft-cleanup.timer'   # NEXT must be populated
ssh <guest> 'sudo -n /usr/local/sbin/clockfix $(date +%s)'    # NOPASSWD works
ssh <guest> 'testparm -s 2>/dev/null | grep -E "^\s*veto files"'   # must be 0 lines
```

Do not do the last one with `grep -i veto` — it would match
`fruit:veto_appledouble = no` because of the name, but that line is not a block; it
**lifts** one, and it must stay.

### 9. Finder copy (confirming Layer 5 is resolved)

```bash
# Terminal A
log stream --predicate 'subsystem == "com.apple.DesktopServices"' --info
# Terminal B / Finder: copy a folder you have opened in the Finder before (i.e. one containing .DS_Store)
#  expected: 0 occurrences of -8062, no dialog
```

Check the reclamation 15 minutes later. **Leave the reclamation targets in place
rather than deleting them** — the cleanup script is designed to stay silent at zero,
so quiet-because-there-was-nothing and quiet-because-it-is-broken are
indistinguishable.

```bash
ssh <guest> 'journalctl -u mac-cruft-cleanup -n 5'
```

---

## Guest clock

Continuous correction while awake belongs to the NTP daemon. The installer does not
deploy it automatically — it is system clock policy, and getting it wrong is costly.
The reference configuration and the rationale are in
[guest/chrony/](../guest/chrony/).

Two essentials:

- **Turn off the hypervisor's guest time synchronisation.** It can be mutually
  exclusive with guest NTP ([failure-model.md](failure-model.md) Layer 1).
- **Allow stepping without a count limit** (`makestep 1 -1`). On a virtual guest the
  clock stops entirely while the host sleeps, so large errors are routine.

## Rollback

```bash
sudo launchctl bootout system/<prefix>.smb-guard
sudo launchctl bootout system/<prefix>.sleepwatcher
```

Guest:

```bash
sudo systemctl disable --now mac-cruft-cleanup.timer
sudo cp -a /etc/samba/smb.conf.bak-<timestamp> /etc/samba/smb.conf && sudo systemctl restart smbd
```

**Rolling back Samba restores `-8062`** — it only makes sense once a different cause
has been established.
