# smb-guard

Keeps a working directory mounted over SMB on a macOS host from **breaking
silently**. It watches and remediates mount ownership on top of an automounter
(autofs), rolls a virtual guest's clock back right after wake, and reclaims the
cruft the Finder leaves behind, server-side and after the fact.

It targets setups where you develop on a macOS host but the files live on a Linux
VM (or a file server) — that is, **an environment where the host's editor and the
guest's toolchain must see the same tree**.

## What goes wrong

An SMB mount is not simply either "broken" or "attached". In between there are
**asymptomatic failures**.

- **Ownership hijacking** — when a root process such as Time Machine's `backupd`
  touches the automount first, the mount is established as root-owned. From then on
  user processes get `EACCES`. Per-user mounts cannot coexist, so it does not heal
  itself.
- **The idle expiry window** — autofs expires by **mount time**, not by last use.
  The default is one hour, so the hijacking window opens every hour.
- **The guest clock stops** — when the host sleeps, so does the guest's clock.
  Writing files with a clock thousands of seconds off after waking puts mtimes in
  the future, and mtime-based build tools (cargo and the like) **silently ignore**
  source changes.
- **Server-local writes are invisible to the client cache** — when the Mac reads a
  file the guest wrote through the cache, one-shot reads, editor re-reads and
  partial reads return the old content **indefinitely**. There is no error, so
  nothing shows up in the logs either. The remedy is the mount option
  `nodatacache` (measured cost: zero).
- **Blocking incidental files kills the primary function** — blocking `.DS_Store`
  writes at the server makes the Finder's CopyEngine fail the **entire** copy
  operation (error `-8062`). The dialog does not name the path that failed, which
  makes it easy to misdiagnose as a permissions or capacity problem.

- **The Archive Utility kills its own extraction target** — on an SMB volume it
  chmods the destination directory it has just created to 0644 (no execute bit)
  and then cannot move the extracted files into it: "Error 1 - Operation not
  permitted", and a dead dimmed folder is left behind. No Samba parameter floors
  a client mode write. Extract with `ditto`/`unzip` instead; recover with
  `chmod u+rwX`.

All of them are the kind you cannot see without reading the logs. For the causal
detail and the measurements see
[docs/failure-model.md](docs/failure-model.md) — organised into 9 layers.

## What it does

| Component | Where | Trigger | Role |
|---|---|---|---|
| `smb-guard` | host | mount event (`StartOnMount`) | ownership determination, immediate remediation of hijacking — **the sole remediation agent** |
| `smb-guard-sleep` | host | just before sleep | records the time of the last sleep (nothing else) |
| `smb-guard-wakeup` | host | wake | wait for network -> correct the clock -> assure the mount -> check liveness |
| `smbfix` | host | a human | the manual tool for when automatic recovery has failed |
| `clockfix` | guest | called over ssh by the host hook | clock step right after resume |
| `mac-cruft-cleanup` | guest | systemd timer (15 min) | post-hoc reclamation of macOS cruft |

Three design contracts hold this system up.

- **Determination reads the mount table only.** Path access (`ls`/`stat`) is never
  used for it — that itself fires the automounter and changes what is being
  measured, and in a daemon context TCC denies `readdir`, producing a false
  "mount failed".
- **There is a single remediation agent.** Neither the wake hook nor the manual
  tool carries its own mount logic; both delegate to `smb-guard`.
- **Cleanliness comes from cleanup, not from blocking.** Cleanup breaks nothing
  when it fails, whereas what fails when blocking fails is someone else's feature.

## Requirements

- **Host**: macOS, [sleepwatcher](https://www.bernhard-baehr.de/)
  (`brew install sleepwatcher` — do not register it as a brew service; this repo
  deploys its own LaunchDaemon)
- **Guest**: Linux + Samba, systemd, key-based ssh login from the host
- The workspace mounted on the host as an **autofs direct map**
- The guest on a **static IP**, with that address resolvable by name from the host
  (a static `/etc/hosts` entry is recommended)

On a virtual guest, **do not install the hypervisor's guest integration tools.**
Their time synchronisation forcibly disables guest NTP (Layer 1), and in a headless
setup none of the remaining features are used.

It works on a physical Linux server too. There `clockfix` and the chrony
configuration are unnecessary — a stopping clock is specific to virtual guests.

## Quick start

```bash
git clone https://github.com/stewardlabs/smb-guard.git
cd smb-guard
cp smb-guard.conf.example smb-guard.conf
$EDITOR smb-guard.conf          # account, mount point, guest alias, share name

./install.sh --dry-run          # see what goes where first
./install.sh                    # host (sudo) -> guest (ssh -t sudo)
```

Run `install.sh` **as a normal user.** Privilege elevation happens separately at
each stage — running the whole thing under `sudo` makes ssh look at root's `~/.ssh`,
so the guest alias will not resolve.

Once installed, **check this first.** If it fails, clock correction is disabled
entirely:

```bash
sudo -u <owner> -H ssh -o BatchMode=yes -o ConnectTimeout=3 <guest> 'date +%s'
```

To sweep deployment, permissions, load state and autofs in one go, use the
read-only inspection tool. **Run this first after a major OS upgrade as well** — an
upgrade can revert the autofs configuration or reset Background Items approval,
producing a state where the files are intact but the jobs are dead.

```bash
sudo ./tools/doctor.sh
```

You can place everything by hand instead of using the install script —
[docs/install.md](docs/install.md) has a table of files, destinations, owners and
permissions. But **the permissions have to be exact.** The dominant failure mode of
this system is "wrong permissions are silently ignored": a `newsyslog`
configuration that is not `root:wheel 644` is ignored without a word, and a
LaunchDaemon plist that is not will be refused by launchd.

## Documentation

| Document | Contents |
|---|---|
| [docs/failure-model.md](docs/failure-model.md) | the 9-layer failure model and the error code map — **read this first** |
| [docs/architecture.md](docs/architecture.md) | full composition, role split, design contracts |
| [docs/install.md](docs/install.md) | installation and verification procedures, manual placement table |
| [docs/operations.md](docs/operations.md) | what to observe, and the diagnostic tools |
| [docs/decisions.md](docs/decisions.md) | the decision log and 29 design principles |
| [docs/open-questions.md](docs/open-questions.md) | open items and latent risks |
| [docs/history/](docs/history/) | development ledger — **written in Korean**, see below |

The value of this project is less in the scripts than in **the failure model and
the record of rejected hypotheses**. The point is to spare someone with the same
symptoms from re-testing a hypothesis that has already been refuted.

> **A note on language.** Everything here is in English except `docs/history/`,
> which is the development ledger — session-to-session handoffs holding raw
> measurement logs and the reasoning as it happened. It stays in Korean because
> translating it accurately is costly and its findings are already distilled into
> [failure-model.md](docs/failure-model.md) and
> [decisions.md](docs/decisions.md). Nothing you need in order to use, install or
> debug this is only in there.

## License

[MIT](LICENSE)
