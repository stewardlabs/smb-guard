# Failure model

The ways a working directory mounted over SMB breaks are organised into 9 layers.
Each layer **manifests independently**, and their symptoms resemble each other
closely enough to invite misdiagnosis. The remedy differs per layer too.

Everything here rests on measurement — `fs_usage` traces, the unified log
(`log show`), the guest journal, and time correlation against the DiskArbitration
log. Items that are conjecture are marked as such.

---

## Layer 0 — The idle expiry window

**autofs expires by mount time, not by last use.** The default `AUTOMOUNT_TIMEOUT`
is 3600 seconds and the expiry check runs roughly every 120 seconds. So no matter
how actively it is being used, an hour after mounting it gets unmounted, and at that
moment **an empty window** opens.

Who touches it first in that window decides the mount's owner (Layer 4).

```ini
# /etc/autofs.conf
AUTOMOUNT_TIMEOUT=604800     # 7 days = the expiry window effectively removed
```

Editing the file alone does not apply it. **The value is baked in when the trigger
is regenerated**, so `sudo automount -vc` is mandatory.

> A finite timeout is meaningless on its own, whatever the value. Time Machine's
> `backupd` touches the share every 30 minutes, so anything above 1800 seconds
> means the window opens every time. The remedy is not shortening the window but
> eliminating it.

---

## Layer 1 — The guest clock

When the host sleeps, the virtual guest's clock stops too. Writing files with a
clock thousands of seconds off after waking puts mtimes in the future, and **build
tools that use an mtime-based fingerprint (cargo and the like) silently ignore
source changes.** Compilation succeeds while the output never changes — a
hard-to-find kind of failure.

### Hypervisor time synchronisation and guest NTP may not coexist

Parallels' `prltimesync` runs `timedatectl set-ntp 0` every time it starts,
**disabling and stopping** the guest NTP unit. It leaves its name in the journal:

```
12ms after prltoolsd starts →  comm="timedatectl set-ntp 0"
systemd-timedated: chrony.service: Disabling unit.
```

Not knowing this, a configuration believed to be "three layers of defence
(hypervisor + NTP + resume step)" is actually running on one or two layers at a
time, and then that one dies quietly. A skew of **+76482 seconds (about 21 hours)**
actually occurred in exactly that illusory state.

The clue was the asymmetry: started by hand it lived a long time, started at boot it
died within 0.36 seconds — it was not a crash but an explicit disable.

### The settled configuration

| Layer | Owner | Rationale |
|---|---|---|
| standing authority | guest NTP (chrony) | `chronyc tracking` and the journal keep the full history — **it is instrumentable** |
| resume step | `clockfix` (called over ssh by the host hook) | steps immediately to the host clock as authority |
| hypervisor synchronisation | **off** | no logs, and it lets skew through while showing a green light |

When exclusivity is forced, **keep the instrumentable one.** The structural
advantages of hypervisor synchronisation (host authority, no network needed,
immediacy) are already implemented isomorphically by `clockfix`, in an observable
form.

Turn it off with `prlctl set <VM> --time-sync off`, and follow the guidance in
[guest/chrony/](../guest/chrony/) for guest NTP.

### The stronger remedy — do not install the guest integration tools

`--time-sync off` is **one line of configuration, so it can be reverted.** A tool's
auto-update, reinstall or configuration restore turning it back on brings the
exclusivity back, and since this layer leaves no log it stays hidden until the next
skew erupts. Turning it off stops the symptom; not installing it removes the cause.

On a headless development guest, nothing the integration tools provide is left.

| Tool feature | In this setup |
|---|---|
| clipboard, drag-and-drop, display integration | there is no screen to use (headless) |
| shared folders (`prl_fs`/HGFS) | unused — this design runs the other way round (the guest is the SMB server) |
| automatic registration of the guest name in the host's `/etc/hosts` | unnecessary once the guest has a static IP (below) |
| time synchronisation | **the very thing being removed** |

**Not installing them is the default, and if they are already installed, removal is
stronger than `--time-sync off`.**

```bash
# For Parallels
sudo /usr/lib/parallels-tools/installer/install-cli.sh -r
```

A removal log full of `No such file` for X11 and display-related files means it
tried to delete components that were never there in a headless installation, and is
**not a failure.** Determine what is left over from the `prltoolsd` process, the
`prl_*` kernel modules and the `/usr/lib/parallels-tools` directory — judge by the
residue, not by the closing message (Principle 3: base determination on primary
evidence).

**suspend/resume, autostart and PMU virtualisation are unrelated to the tools.**
They are hypervisor-layer features and keep working after removal — this is not a
reason to hesitate.

### Give the guest a static IP

Both the host's mount URL (the autofs map) and the ssh alias depend on resolving the
guest's name, and the wake hook's clock correction rides on that ssh. If name
resolution wavers, Layer 1's remedy cannot even reach its target.

Removing the integration tools **leaves nothing to maintain the host's `/etc/hosts`
entry.** Replacing it with mDNS (`<host>.local`) is an option but not recommended —
re-advertisement lags right after waking, creating a window where the wake hook and
the SMB reconnection are blocked at name resolution. That is, **a static IP plus a
static `/etc/hosts` entry on the host** is the quietest combination in this system.

When using a hypervisor DHCP pool, **raise the pool's start address to leave room
for static IPs.** That way an address previously handed out by DHCP can be promoted
to static as-is, without also having to change the host-side configuration.

---

## Layer 2 — Spurious wake

If the hook fires on a darkwake during the sleep transition, or on an immediate
wake, it attempts a network wait, ssh and mount remediation when there is nothing to
recover yet.

**Remedy**: record the time of the last sleep and skip everything when the time
slept is below a threshold (30 seconds by default).

> A trap when verifying this: on AC power the "no sleep after screen lock" policy
> prevents a second sleep. Forcing one sleep with `pmset sleepnow` and immediately
> waking leaves the machine awake, and afterwards pressing a key produces no wake
> event, so nothing more is logged — **the hook is not broken.**
> Test a real sleep by closing the lid.

---

## Layer 3 — TCC probe blindness

Running `ls` in a launchd daemon context gives `Operation not permitted` (EPERM).
Reading that as "the mount failed" is a misjudgement.

**The order makes the reason obvious:**

```
open() → autofs trigger → automountd mounts with mount_smbfs under the user's credentials → mount succeeds
       → only then does readdir get denied by TCC, printing EPERM
```

What was denied is `readdir` alone, and **`open()` has already happened.** The mount
is in place.

**Remedy**: unify determination into a mount table lookup. That makes this layer
structurally disappear, and Full Disk Access (FDA) becomes unnecessary too.

> Even with the same code and the same credential switch, **the result differs
> depending on which daemon invoked it.** TCC attributes per responsible process, so
> a child of a binary that has FDA passes while a child of a daemon that does not is
> denied. An `ls` going through the very same wrapper actually succeeded on one side
> and returned EPERM on the other.
>
> Granting FDA to a shell script means granting it to the interpreter
> (`/bin/bash`), which opens sweeping privileges system-wide. **Do not.** Without
> using `ls` results for determination, it works exactly right with no FDA.

---

## Layer 4 — Root-owned mount (hijacking)

`backupd` (Time Machine) touches the share every 30 minutes. When it triggers first
while the expiry window is open, **the mount is established as root-owned and user
processes get `EACCES`.** Per-user mounts cannot coexist, so it does not heal itself.

- `tmutil disable` has no effect (measured: 7 accesses continued after disabling).
- `tmutil addexclusion` targets the wrong layer — it excludes from snapshots, it
  does not block access.
- Only a directory `open()` induces the trigger. `getattrlist`, `stat64` and `fsctl`
  do not.

**Direct evidence**: a correlation was confirmed where a root-owned smbd session
opened 2 seconds after a snapshot probe (`fs_snapshot_list ... not supported`).

### Hijacking is a race

In the empty window, **whoever triggers first becomes the owner.** A workspace has
user processes touching it constantly — editors, LSPs, file watchers, other shells'
cwd — so when the user's side wins, no hijacking happens. The competitors are not
only user applications but also system processes such as Spotlight (`mds`),
QuickLook and Finder background activity.

This is **why hijacking is intermittent.** In measurements, the time from expiry to
hijacking was once 28 minutes and once 10 seconds.

> A trap in reproduction experiments: when you try to induce a failure artificially
> but the watch daemon fixes it within 2 seconds, what you are measuring changes
> while you measure it. **When measuring a self-healing system, stop the healing
> first.**

**Remedy**: eliminate the window (Layer 0) plus immediate remediation via the mount
event hook. The moment hijacking occurs is itself a mount event, so `StartOnMount`
fires at exactly that point. Measured time to resolution: **4 seconds**.

### Layer 4b — umount refused in a daemon context (cause undetermined)

In a daemon context, `umount -f` fails with EPERM. **5 rejected hypotheses**:

| Hypothesis | Refuted by |
|---|---|
| TCC/FDA | it succeeds from Terminal.app without FDA |
| the target mount's owner | even a root-owned mount unmounts from a login session |
| kernel blocking during the sleep transition | EPERM also in manual reproduction unrelated to sleep |
| `umount` is low-level so it fails often | does not explain why it succeeds only from a terminal |
| timing (refused right after mounting) | 4 rounds of immediate umount all succeeded |

What remains is the execution context (launchd system domain vs login session), and
it cannot be reproduced from a shell. **The investigation was ended because there is
no functional impact.**

**Remedy**: put `diskutil unmount force` in stage 1. `diskutil` does not unmount by
itself but delegates to `diskarbitrationd` (a system daemon), so it **depends less
on the caller's execution context.** `umount -f` remains as the stage 2 fallback —
it is the safety net for when `diskarbitrationd` does not respond, and it does have
effect on the manual tool path that runs from a terminal.

> A side effect of reordering rather than deleting the fallback: from now on, a
> `falling back to umount` appearing in the log is **the signal that `diskutil`
> failed**, a situation never yet observed. A message that used to be normal noise
> becomes an anomaly signal and gains diagnostic value.

---

## Layer 5 — Blocking incidental files kills the primary function

When the server refuses a `.DS_Store` write, **the Finder fails the entire copy
operation** (error `-8062`). To the user it looks only like "the copy does not
work", and the dialog does not name the path that failed.

### The fatal trigger is not "creating new metadata"

Settled by a three-case controlled experiment:

| Source condition | terminal `cp -r` | Finder |
|---|---|---|
| no `.DS_Store` | fine | **fine** — succeeds even with blocking on |
| empty (0B) `.DS_Store` | that file refused, the rest copied | **succeeds without a dialog** — quietly excluded |
| **a real (non-empty) `.DS_Store`** | that file refused, the rest copied | **-8062, operation aborted** |

That is, the fatal path is **copying a `.DS_Store` already present in the source
folder as part of the payload.** Almost every folder ever opened in the Finder on a
Mac falls into that category, so as long as blocking is in place, Finder copying is
effectively impossible.

### `DSDontWriteNetworkStores` does not prevent this

**It is out of scope to begin with.** That setting only suppresses the Finder
creating a **new** `.DS_Store` on a network volume; it has nothing to do with the
path that copies a file already present in the source. Demonstrated by reproducing
-8062 on a Mac where the suppression was in effect.

### Remedy: abolish blocking and move to post-hoc cleanup

The requirement was never "block it at the SMB layer" but **"the workspace and the
history do not get polluted"**. Three layers satisfy the same requirement without
breaking the Finder.

| Layer | Means | If it fails |
|---|---|---|
| git | global ignore / `.git/info/exclude` | only the history is polluted, Finder fine |
| filesystem | `mac-cruft-cleanup.timer` (reclamation every 15 min) | cruft is left behind, Finder fine |
| client | `DSDontWriteNetworkStores` (**secondary**) | more inflow, Finder fine |

**Even if all three fail, the Finder's primary function does not die.** That is the
decisive difference from blocking.

Partial retention (unblocking only `.DS_Store`) was not chosen because there is no
predicting which item the Finder will make a premise of next — blocking `.Trashes`
already existed as a **latent bug** breaking "Move to Trash".

### Aside: `fruit:resource = stream` is forbidden

Sending resource forks through extended attributes inherits ext4's xattr size limit
(inode slack plus one block, typically 4KB) and creates **a fresh write failure of
the same shape.** The `vfs_fruit(8)` manual explicitly warns against using it
together with `streams_xattr`. Use the default `file`, and record the intent in the
file.

### Aside: `fruit:veto_appledouble = no` must stay

Despite "veto" appearing in the name, it is not part of the `veto files` family, and
the value `no` is not a block but **lifting one**. The default `yes` stops clients
from reaching the `._*` files fruit creates, and the manual lists "unpacking Mac ZIP
archives fails on Mac clients" as a side effect of that — **the same failure
structure** as `-8062`.

The verification grep must be anchored. `grep -i veto` false-matches this line:

```bash
testparm -s 2>/dev/null | grep -E '^\s*veto files'    # must be 0 lines
```

---

## Layer 6 — Share root name collision

**An existing file whose basename matches an entry name at the share root cannot be
overwritten or deleted, wherever it sits in the tree.** The failure surfaces as
`ENOENT` — the file is plainly there, and yet it reports "not found".

Measured 2026-08-15 (Samba 4.23.6-Ubuntu, macOS 26.6). Conditions were isolated with
a C harness, and an instrumented smbd with `log level = 10` was brought up on a
separate port on the guest to capture the server-side flow.

### The rule

`rename(A,B)` overwriting and `unlink(B)` are affected. **It is not specific to
rename.**

| Factor | Effect |
|---|---|
| `basename(B)` matches an entry name at the share root | **this is the only thing that matters** |
| B does not exist yet | succeeds (hence it looks like "works the first time, fails from the second") |
| the name of the source A | irrelevant — only the destination name matters |
| depth, hidden or not, `O_EXCL`, file size, open fds, process cwd | all irrelevant |
| whether the target is a file or a directory | irrelevant (both fail) |

### The cause

When deleting a file, Samba clears alternate data streams via
`close_remove_share_mode()` -> `delete_all_streams()` (`source3/smbd/close.c`). The
path that reopens the file there uses **only the basename** rather than the full
relative path, so it **resolves against the share root**:

```
delete_all_streams found 2 streams
openat_pathref_fsp: smb_fname [config]
file_name_hash: /opt/stewardlabs/config          <- the real target is tmp/…/config
delete_all_streams failed: NT_STATUS_OBJECT_NAME_NOT_FOUND
```

With a matching name at the share root it opens **the wrong object** and stream
deletion fails; without one, the ENOENT is treated as a normal completion and it
passes. The client receives this CLOSE failure and never sends the rename request at
all — a successful case records rename twice, a failing case only once.

**The streams are reported not by the client but always by the server's
`vfs_fruit`** (AFP_AfpInfo / AFP_Resource). That is why client mount options cannot
fix it — `nostreams`, `nomdatacache`, `nodatacache`, `nonotification`, `soft` and
`forcenewsession` were all measured to have no effect. The actual entries at the
share root are not damaged (inode and mtime confirmed unchanged).

### Why it is fatal — git breaks

git's `lock_file` writes to `X.lock` and then does `rename(X.lock, X)`. Since the
basename of `.git/config` is `config`, having a name `config` at the share root
means **every write from the second one onward fails, because config already
exists.** `git init` stopping at 36 bytes
(`[core]\n\trepositoryformatversion = 0\n`) is precisely this.

The main work of `commit` and `push` succeeds and only the config write fails, so
**it is easy to miss as a partial success** (upstream registration by `push -u`,
branch registration by `worktree add`). And the failed write leaves `.git/config`
half-written, so **damage accumulates** — a state with a section header and a
`remote =` and then a blank line actually occurred, killing the whole repository with
`fatal: bad config line N`. Deletion is also a config write, so the damage does not
heal itself.

### Determination

`tools/probe-rename-collision.sh` actually attempts an overwriting rename with each
entry name of the share root and extracts the contaminated set. A control runs
alongside it, so "zero failures" can be distinguished between healthy and an invalid
measurement.

### Upstream — it is a Samba regression, fixed on master

This is not specific to our environment but **a Samba regression**. `09f49fb56a4`
(smbd: Simplify delete_all_streams()) changed `delete_all_streams()` to use
`synthetic_smb_fname()` instead of `synthetic_pathref()`, which made the base_name
passed to `SMB_VFS_UNLINKAT()` relative to **dirfsp** rather than to the share root.
But `streams_xattr_unlinkat()` was still building its pathref from
`handle->conn->cwd_fsp` (= the share root) when `fsp == NULL`.

| | |
|---|---|
| regression introduced | `09f49fb56a4` — smbd: Simplify delete_all_streams() |
| fix | `2fc21d87` — s3:vfs_streams_xattr: Use dirfsp in streams_xattr_unlinkat() (master, 2026-06-16) |
| upstream bug | [16144](https://bugzilla.samba.org/show_bug.cgi?id=16144) |
| version measured | 4.23.6-Ubuntu — confirmed **not present** in the `v4-23-stable` source |

The fix commit's description matches what we observed: *"path resolution to fail for
files in subdirectories, leaving xattr streams intact after an OVERWRITE or
OVERWRITE_IF disposition."*

**It has not been backported to the release branches yet.** The upstream bug
describes the symptom as a failure of the `smb2.streams` test itself, so it does not
surface the point that this is **a user-visible failure where the client receives
ENOENT when overwriting an existing file in a subdirectory** — that is what our
observation could add upstream.

The remedy below is therefore not a temporary workaround pending a backport but
**the remedy that is valid now.** Whether to undo the layout after moving to a
version carrying the fix is reconsidered then (open-questions.md).

### Remedy: raise the share root above the workspace

The collision set is the share root's entry list. **Exporting the workspace directly
makes every name at that root the collision set** — repository directory names such
as `config`, `docs` and `web` all fall into it. Raising the share root one level and
putting only the workspace beneath it shrinks the collision set to the single
workspace name, which does not overlap git's internal filenames (`config`, `index`,
`HEAD`, `packed-refs`). The client mounts a subdirectory of the share, so the layout
it sees is unchanged.

Rejected alternative: `fruit:metadata = netatalk` + removing `streams_xattr`. It
eliminates the streams and does work, but **small-file creation is 5x slower**
(2.0s -> 10.3s for 150 files) and every file gets a `._` sidecar (150/150). Layer 5
treats `._*` as a reclamation target, so the volume of cruft grows accordingly too.

### Side effect: raising the share root raises the cruft with it

The Finder creates `.Trashes`, `.Spotlight-V100`, `.fseventsd` and `.DS_Store`
**at the root of the mounted share.** Back when the share root was the workspace,
Layer 5's cleanup sweep covered these automatically; once the share root is raised,
that place falls outside `SMBG_GUEST_ROOT` and the timer never sweeps it. It is not
a functional failure, but cruft quietly accumulates, and `.Trashes` in particular
keeps files deleted through the Finder unreclaimed.

So `mac-cruft-cleanup` sweeps the share root once more at **depth 1**
(`-maxdepth 1`, traversal cost effectively zero). **Fixing the script alone is not
enough** — the unit carries `ProtectSystem=strict`, so without the share root in
`ReadWritePaths` the deletion fails silently. The two changes are a pair.

---

## Layer 7 — Server-local writes are invisible to the client cache

**Only in the combination where the guest (server-local) writes and the Mac (SMB)
reads** does old content come back. Mac-to-Mac and Mac-to-guest are fine. A
server-local write goes straight to the filesystem without passing through smbd, so
there is nothing to push a cache invalidation to the client. This is not a Samba
bug; the pattern "write to a tree exported over SMB from the server locally as well"
is outside SMB's consistency model.

In a host-editor plus guest-toolchain setup that combination is routine — build
artefacts produced by the guest, results of git commands run on the guest, sources
modified by a guest session, all read by the Mac.

### Scale — staleness is bounded by events, not by time

Measured 2026-08-16 (macOS 26.6 client + Samba 4.23.6, polling at 0.5s):

| Read pattern | Staleness |
|---|---|
| polling the same file repeatedly (small file) | self-heals in 1.1-1.7s |
| polling a file with an old mtime repeatedly | ~29s (the attribute cache ceiling. Independent of file age, 30 days or 1 hour) |
| repeated full reads of 4MB | ~1.2s |
| **read once, then a single re-read T seconds later** | **stale for all of T=5-120s** |
| **re-reading through a held fd (the editor and tooling pattern)** | **unresolved at >=180s** |
| **repeated partial reads of 4MB (leading 64B)** | **unresolved at >=900s** |

The unresolved rows are where the measurement ceiling was reached, not resolution.
The only resolving events are unmount, cache eviction, and the state transition of
the bistability below. Real-world access (a one-shot cat, an editor re-read, a
partial read) falls exactly into the unresolved category, which is why it is
observed as "content stale for minutes". A file with no cache (a first read) takes
0.02s — staleness is entirely a problem of files whose cache was filled by an
earlier read.

### Mechanism — the lease is never broken, and staleness exists only when the cache is active

- The Mac client takes and holds an SMB2 lease `(RH)` on a file it has read. **The
  lease survives a guest-local write unchanged** (compared before and after the
  write with `smbstatus --locks`). Naturally so, since there is nobody to send a
  break.
- But holding a lease is not the same as using the cache. **Whether the client
  actually uses its data cache is itself state-dependent** (see the bistability
  below). In the cache-inactive state every read goes to the server even while
  holding a lease, so staleness is impossible in principle — measured: on a
  default-options mount, 1000 held-fd 64KB re-reads were retransmitted in full
  (64MB) (compared against the server interface's tx_bytes, byte-exact, reproduced
  across 2 comparison mounts).
- Within the cache-active state, `kernel change notify` (Samba default yes,
  inotify-based) rescues an active observer. notifyd **sees server-local writes too,
  via inotify.** Setting it to `= no` was confirmed to degrade polling-based healing
  to indefinite (fast and indefinite alternating under the same protocol — the cause
  of the alternation itself is unexplained). The indefinite staleness of one-shot,
  held-fd and partial reads was measured with notify on — a push rescues only active
  observers.
- Directory enumeration (`ls`) alone is always fresh (0.01s) regardless of state or
  notify — enumeration bypasses the cache and goes to the server.

### Bistability — what differs is whether the client cache is used at all

Both states were observed with the same smb.conf, the same smbd process (identical
PID) and the same SMB session:

- **Cache-active state (dangerous)**: one-shot, held-fd and partial reads stale
  indefinitely. Reproduced consistently for 25 minutes. That stale content is
  returned at all is itself the evidence of cache serving.
- **Cache-inactive state**: every read goes to the server — measured as 1000 held-fd
  64KB re-reads retransmitted in full (64MB). Staleness is impossible in principle,
  and the lease `(RH)` is granted in this state too. **Holding a lease != using the
  cache.**

The first version interpreted the inactive state's freshness as "healing by notify
push", but a follow-up measurement (the traffic comparison above) forced a simpler
explanation: it was not healed — **it never reads from the cache in the first
place.** The evidence for notify's effect (turning it off degrades polling-based
healing) is confined to observations within the cache-active state.

The transition coincided in time with two `smbcontrol all reload-config` calls
(causality unconfirmed). An attempt to re-induce the active state via inotify queue
overflow (a storm of 50,000 events, three times the queue limit of 16384) failed.
**What determines cache-active versus cache-inactive is unexplained** — see
[open-questions.md](open-questions.md).

Determine the cache state from traffic (timing deceives, since cache behaviour
differs by read pattern — a full sequential read is read-through even in the active
state):

```bash
# Compare the guest interface's tx_bytes before and after — retransmitted held-fd re-reads mean inactive
a=$(ssh <guest> cat /sys/class/net/<iface>/statistics/tx_bytes)
python3 -c "
f=open('<mount>/<file>','rb')
for _ in range(1000): f.seek(0); f.read(65536)"
b=$(ssh <guest> cat /sys/class/net/<iface>/statistics/tx_bytes)
echo $(( (b-a)/1024 ))KB   # ~0 = cache active, ~64000 = inactive
```

If you meet staleness (i.e. the cache-active state) again, **collect before you fix
it** (Principle 22 — stop the healing first. `reload-config` can erase the state):

```bash
sudo smbstatus --locks                      # (1) the lease the Mac holds
grep -i lease /proc/locks                   # (2) kernel leases (none is normal)
ps -ef | grep notifyd                       # (3) notifyd is alive
# (4) write on the guest and confirm reproduction with a single read 60s later on the Mac
# (5) confirm the cache is active with the traffic probe above — this is the only chance to measure nodatacache's effect
# and only then: sudo smbcontrol all reload-config
```

### Remedy: `nodatacache` on the client mount

Add `nodatacache` to the autofs map's mount options ([install.md](install.md)). Its
meaning is containment of the bistability: **it blocks entry into the cache-active
(dangerous) state itself.** In the cache-inactive state it is a no-op, so nothing is
lost, and at the moment the active state would have arrived, the possibility of
staleness is removed. Of the three candidates tested it is the only remedy that
depends on neither the state transition nor notify.

Measured cost (default vs option, A-B-B-A crossover, median of 3 each):

| Workload | Default | nodatacache |
|---|---|---|
| 20 documents read in sequence | 0.087s | 0.089s |
| git status+diff across 3 repositories | 1.35s | 1.35s |
| tree enumeration plus content reads (17.8k files) | 6.64s | 6.62s |
| enumerating 22k node_modules entries | 62.7s | 62.6s |

A caveat: this comparison was measured while **the baseline side was in the
cache-inactive state**, which makes the equality self-evident (the first version did
not know this). The valid conclusion goes only as far as "single-pass workloads (the
4 above) are outside the influence of caching" — they are shapes that gain nothing
from a cache anyway, being freshly mounted each iteration. **The cost of
re-read-intensive work relative to the cache-active state remains unmeasured.** Work
that reads the same file repeatedly turns a RAM cache hit in the active state into a
network round trip each time, but on a local hypervisor link a small-file round trip
is under a millisecond, so it is judged to have no practical impact on source and
document work.

What remains is metadata staleness (size and mtime from stat, ceiling ~29s), and
that is accepted because mtime-sensitive tools (builds) run on the guest.

### Rejected: `nomdatacache` (blocking the client metadata cache)

Unnecessary for content consistency (`nodatacache` alone suffices) and fatally
expensive: tree enumeration 6.6 -> 28.5s (4.3x), node_modules enumeration
62.7 -> 154.8s (2.5x). Every workload dominated by `stat()` round trips pays that
multiplier. Not a price worth paying to erase a metadata staleness ceiling of ~29s.

### Rejected: `kernel oplocks = yes` (server-side)

Tested on the hypothesis that "a Linux local write triggers a break via F_SETLEASE,
giving consistency with the cache left on". **That path does not hold for SMB2/3
lease clients**:

- `man smb.conf`: `smb2 leases` is effective only with `oplocks = yes` **and
  `kernel oplocks = no`**. That is, this option blocks leases entirely. Level II
  oplocks die with them.
- Measured: on an isolated share (the same path, differing only in
  `kernel oplocks = yes`) what the Mac received was `LEASE()` — **an empty lease**.
  With zero caching rights there is nothing for smbd to protect, and **no kernel
  lease is taken either** (0 entries in `/proc/locks` while a handle was held open).
- The net effect is therefore not "an added kernel break path" but **confiscation of
  caching for every client of that share**. The cost direction exceeds
  `nomdatacache` (there is no caching at all) and the unit of application is the
  whole share. `nodatacache` obtains the same consistency per client at a measured
  cost of zero, so this is strictly worse.
- Incidental confirmation: the feared break wait on a guest-local `open()`
  (`fs.lease-break-time` 45s) does not occur, for the same reason — there is no
  lease to break (measured open delay 0.0ms).
- Being an (S) parameter, per-share isolation does hold — an empty lease on the
  isolated share and a normal `LEASE(RH)` on the production share were observed at
  the same time.

---

## Layer 8 — Client permission writes are applied verbatim, with no server-side floor

**A mode the client asks for is exactly what the server applies — the masks, the
force parameters and a per-share `fruit:nfs_aces = no` all stand aside — and a
macOS client does ask for destructive ones.** The headline case: the Archive Utility kills its
own extraction target and aborts with "Error 1 - Operation not permitted", leaving
a dimmed, unusable folder.

Measured 2026-08-18 (macOS 26.6, Archive Utility 10.15/176.6.1, Samba
4.23.6-Ubuntu). The wire-level sequence was captured with `smbcontrol all debug 10`
during a live reproduction; the measurement ledger is
`history/layer8-client-permission-writes.md`.

### The Archive Utility sequence

| Step | Request (from the debug log) | Server result |
|---|---|---|
| helper and temp directories | `MS NFS chmod request ..., 0700` | 0700 — fine |
| extracted files, into the temp directory | create, then `chmod 0600` (the archive's modes) | 0600 — fine |
| the final directory | mkdir — `unix_mode(...) returning 0755` | 0755 — fine |
| **the final directory, again** | **`MS NFS chmod request ..., 0644`** | **0644 — a directory with no execute bit** |
| moving the files into place | rename source opened with DELETE (`0x10000`) | `NT_STATUS_ACCESS_DENIED`, repeatedly |

The client requests a **file** mode for a **directory** it is about to fill. From
that point the folder cannot be entered or written (`drw-r--r--`), the move phase
dies, and the utility aborts. The same archive extracts cleanly on local APFS (the
final directory ends up 0700), so the 0644 request is specific to the Archive
Utility's network-volume path. Isolated reproduction: `mv` a file into a 0644
directory over the mount fails with `Permission denied`.

### What does not stop it (all measured)

| Candidate | Result |
|---|---|
| `create mask` / `directory mask` | not applied — the masks act at creation, this mode arrives afterwards |
| `force create mode` / `force directory mode` | not applied — confirmed after a reload **and on a fresh session** |
| the `security mask` family | removed in Samba 4.11 — `Unknown parameter` in 4.23 |
| `fruit:nfs_aces = no` **set in the share section** | **a silent no-op** — the option is global-only. vfs_fruit(8) GLOBAL OPTIONS: "must be set in the global smb.conf section and won't take effect when set per share"; the module reads it with `lp_parm_bool(-1, ...)`, which consults `[global]` only (source-verified, 4.23.6). The measured acceptance of `MS NFS chmod request` was the guard never arming, not a missing guard — `check_ms_nfs()` does gate the modify path when the option is off in `[global]` |

No mask or force parameter floors a client mode write in current Samba. The chmod
channel macOS uses (mode bits carried in the security descriptor) lands verbatim.
The one switch that does reach this path is `fruit:nfs_aces = no` in `[global]` —
it disarms the whole NFS ACE channel at AAPL negotiation time, taking every
intentional Mac-side mode operation and real mode display down with it. That
collateral is unmeasured; the experiment is registered in open-questions.md.

### The recoverable and the unrecoverable

SMB is handle-based: every operation — a mode change and a rename included — first
opens the target, and the open is checked against the target's current mode. That
draws a hard line at exactly zero:

| Mode left behind | From the Mac |
|---|---|
| any owner bit set (0644, 0600, 0700, 0400, ...) | recoverable — `chmod u+rwX` opens it back up; traversal, rename and delete follow |
| exactly 0000 | **unrecoverable** — every open is denied, so chmod, rename and delete all fail. Only a `chmod` on the guest can free it |

Everyday traffic is unaffected: files and directories the guest creates with
0600/0700 (umask 077) rename, move and delete normally from the Mac (measured).
POSIX `chmod` and `unlink` need no access bits on the target itself — this trap is
SMB-specific.

### Remedy: disarm the chmod channel server-side (adopted 2026-08-19)

`fruit:nfs_aces = no` in `[global]` — where the option actually lives; the
per-share placement earlier revisions shipped was a silent no-op
(source-verified). Off, the server stops advertising the AAPL
`SUPPORTS_NFS_ACE` capability at session negotiation and the whole channel goes
down. Measured on a fresh session after the switch:

- **Every client mode write is silently ignored** — `chmod 000`/`600`/`+x` on a
  file and the killer `chmod 644` on a directory all return exit 0 on the Mac
  and change nothing on the server; modes stay what the masks made them.
- **The Archive Utility extraction that died against its own 0644 simply
  succeeds end to end** — all files present, final directory 0755, no dimmed
  folder. (Reproduced with a synthetic archive matching the captured shape —
  directory entry stored 0644, files 0600 — the original archive no longer
  exists.)
- **The unrecoverable mode-0000 class can no longer be created from the
  client.**

The collateral, measured and accepted:

- Intentional mode changes from the Mac are silent no-ops too — `chmod +x`
  included. **Mode changes are made on the guest.** The silence is the ugly
  part: the client sees success.
- The Mac's mode display is synthetic (everything `rwx------`). Enforcement
  stays server-side, so this is cosmetic — but do not read Mac `ls -l` as
  truth; that rule (guest `stat` is the determination) already stood. Execution
  is *not* display: it follows the server's real x bit (measured — a server-644
  file shows `rwx------` yet refuses to run).
- Any Mac-side rewrite of an executable file (a checkout, a pull, an editor
  save) leaves it 644 on the server — the mode it would apply rides the same
  disarmed channel. Recovery is a guest-side `git checkout -- <path>` (or
  `chmod +x` when the content change is wanted); the sweep lives in
  smb-guard-doctor (operations.md 'git on the Mac — filemode').
- git on the Mac would see a phantom `100644 => 100755` on every tracked file
  (the synthetic mode carries x). The mitigation and its clone-time trap are in
  operations.md — repo-local `core.filemode` unset plus a Mac machine-local
  `includeIf` overlay, guest unaffected.
- Anything that installs executables from the Mac inherits the same fate: a
  `pnpm install` on the mount exits 0 but lands every file 0644, and the
  `node_modules/.bin` shims will not spawn (EACCES/126). Measured; the break
  surfaces at the next fresh install, not at adoption. Remedies in
  operations.md 'Package managers writing executables (pnpm)'.

The operational remedy stays documented as the fallback for a configuration
where the channel is armed again (doctor.sh asserts the invariant; its loss is
how this layer would silently return):

- Extract with CLI tools: `ditto -xk <archive>.zip <dest>` or `unzip`.
- A dimmed folder left behind: `chmod u+rwX <folder>` from the Mac.
- A mode-0000 object: `chmod -R u+rwX` **on the guest**; detection sweep
  `find <workspace> -perm 0` on the guest.

---

## The error code map

| Symptom | Meaning | Action |
|---|---|---|
| `ls: ...: Operation not permitted` | TCC denying `readdir` (Layer 3) | **ignore — functionally fine.** `open()` has already happened |
| `umount: unmount(...): Operation not permitted` | unmount refused in a daemon context (Layer 4b) | `diskutil` is stage 1, so it does not appear from the hook. **If it does, diskutil failed first — investigate** |
| `Permission denied` (EACCES) | root-owned mount (Layer 4) | remediated automatically. Manually, `smbfix` |
| no `mounted by` in the mount line | a root mount | as above |
| `//account@host/share` in the mount line | **just the SMB authentication account, not the mount owner** | determine ownership from the `mounted by` field alone |
| the Mac reads old content for a file the guest wrote (no error) | Layer 7 — indefinite staleness of a cached file | run the collection procedure (Layer 7), then `smbcontrol all reload-config`. The permanent remedy is `nodatacache` |
| `No locks available` (ENOLCK) | automountd mount failure | check the map credentials, then the clock |
| `Too many users` (EUSERS) | wedged leftover smbfs sessions in the macOS kernel | the only known cure is rebooting the server |
| Finder `error code -8062` | an incidental file write failure aborting the whole copy (Layer 5) | use the diagnosis below to get **the failing path by name** |
| a dimmed folder with a resume arrow, files inside at 600 | the state after a -8062 abort where the CopyEngine could not apply final permissions | not a fault but the trace of something unfinished. Do not resume — `rm -rf` and copy again |
| `ENOENT` only when overwriting an existing file | share root name collision (Layer 6) | check whether that file's basename matches an entry name at the share root. Raise the share root above the workspace |
| `could not write config file .../.git/config` | as above — the case where `.git/config` is caught | check `.git/config` for damage as well (`fatal: bad config line N`) |
| `ENOENT: rename '<file>.tmp.NNN' -> '<file>'` | as above — editors and tools using atomic saves | not intermittent but deterministic. Look at the destination basename |
| Archive Utility "Error 1 - Operation not permitted", a dimmed folder left behind | the utility chmodded its own destination directory to 0644 (Layer 8) — **should no longer occur**: the chmod channel is disarmed server-side | its appearance means the `fruit:nfs_aces` invariant was lost — run doctor.sh. Recover with `chmod u+rwX` from the Mac; extract with `ditto`/`unzip` meanwhile |
| every operation on one object fails with EACCES, even as its owner | mode 0000 over SMB — every open is denied (Layer 8) — **should no longer occur**, as above | `chmod` on the guest (from the client it is unrecoverable), then run doctor.sh — the channel that wrote it is supposed to be disarmed |
| `pnpm run`/`pnpm exec` dies with `spawn <bin> EACCES`, or a `node_modules/.bin` shim exits 126, right after an install on the mount | the install's modes rode the disarmed chmod channel (Layer 8) — everything landed 0644 | restore modes on the guest, or keep node_modules off the mount — operations.md 'Package managers writing executables (pnpm)' |

**Collecting primary evidence for -8062** — the Finder dialog does not tell you the
path:

```bash
log stream --predicate 'subsystem == "com.apple.DesktopServices"' --info
# on reproduction:  Error -8062 at path: <path> on write
```

---

## How to read this model

Nine layers does not mean nine distinct symptoms. It means **the same symptoms
("the file is not there", "the copy does not work", "it will not save") come from 9
different causes.** That is why determination has to rest on primary evidence — the
mount table, error codes, the journal, the DiskArbitration log.

Related: the 29 design principles in [decisions.md](decisions.md) were all obtained
in the course of working this model out. [operations.md](operations.md) lists the
observation channel for each layer.
