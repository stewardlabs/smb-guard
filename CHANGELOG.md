# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versioning follows [Semantic Versioning](https://semver.org/).

In this project **the unit of compatibility is the configuration file**
(`smb-guard.conf`) and the deployment paths. Removing a configuration key or
changing its meaning, and moving a deployment path, are major changes.

## [1.2.0] — 2026-08-18

### Added

- **Layer 8 registered in the failure model: client permission writes are applied
  verbatim, with no server-side floor** — the Archive Utility chmods the
  destination directory it has just created to 0644 over SMB and its extraction
  dies against it ("Error 1 - Operation not permitted"), leaving a dimmed folder.
  The wire-level capture shows the client requesting a **file** mode for a
  **directory** (`MS NFS chmod request ..., 0644`); every server-side floor
  candidate was measured out — the masks act at creation only, the force
  parameters do not reach this path even on a fresh session, the `security mask`
  family was removed in 4.11, and `fruit:nfs_aces = no` does not gate the modify
  path. A mode-0000 object is unrecoverable from the client (every open is
  denied) while any surviving owner bit allows `chmod u+rwX` recovery; everyday
  0600/0700 guest artefacts are unaffected (measured). The remedy is
  operational: CLI extraction (`ditto`/`unzip`), a documented recovery, and the
  doctor section below.
  The measurement ledger is `docs/history/layer8-client-permission-writes.md`
- `tools/doctor.sh`: **'guest samba invariants' section** — asserts, against the
  *running* guest configuration (`testparm` over ssh), the invariants whose loss
  silently reopens settled layers: no `veto files` (Layer 5), the `vfs objects`
  chain, `fruit:metadata = stream`, `fruit:veto_appledouble = no`,
  `fruit:resource = file`, `store dos attributes` not overridden to `No`, and
  the share path (Layer 6). Invariants rather than a whole-file diff, because
  the guest Samba configuration is deliberately merge-deployed

### Changed

- `guest/samba/smb.conf.in`: the `fruit:nfs_aces` comment corrected — it promised
  protection against the Finder's chmod misbehaviour that the option does not
  deliver on the modify path (measured, 4.23.6). Registered in open-questions.md
  with its resume condition. Nothing functional changes
- Layer count references updated to 9 (README, CLAUDE.md, failure-model.md)

### Fixed

- The closing sentence of failure-model.md said "Eight layers does not mean seven
  distinct symptoms" — a miscount, now nine against nine

## [1.1.0] — 2026-08-17

### Added

- **The share root can now sit above the workspace** (`SMBG_EXPORT_ROOT`,
  `SMBG_SHARE_SUBPATH`) — because of a Samba defect where deleting a file clears
  streams and resolves the basename relative to the share root, **an existing file
  whose basename matched an entry name at the share root could not be overwritten
  or deleted anywhere in the tree.** `.git/config` was caught by this, `git init`
  stopped at 36 bytes and damage to `.git/config` accumulated.
  Raising the share root one level shrinks the collision set to the single
  workspace name, and since the client mounts a subdirectory of the share the
  visible layout is unchanged.
  Registered in the failure model as **Layer 6** (with measurements)
- `tools/probe-rename-collision.sh` — determination and regression check for
  Layer 6. It actually attempts an overwriting rename with each entry name of the
  share root and extracts the **contaminated basename set**.
  Reclamation happens on the guest (an `rm -rf` from the Mac would catch the
  cleanup itself in the same defect)
- **Two prerequisites made explicit: the guest integration tools are not installed,
  and the guest has a static IP.** `--time-sync off` is a setting, so an
  auto-update, a reinstall or a configuration restore can revert it, and a reverted
  state leaves no log and stays hidden until the next skew — turning it off stops
  the symptom, not installing it removes the cause. On a headless development guest
  everything else the tools provide (clipboard, display, shared folders, automatic
  host hosts registration) is either unnecessary or used in the opposite direction
  by this design, so the cost is zero. Removing the tools leaves nothing to
  maintain the host's `/etc/hosts` entry, so **a static IP and a static hosts entry
  are a pair**, and replacing them with mDNS is not recommended because
  re-advertisement lags right after waking. Added the 'The stronger remedy' and
  'Give the guest a static IP' sections to Layer 1, and registered **'Do not
  install the guest integration tools'** in the decision log
- `tools/doctor.sh` — survival check of the host (macOS) configuration
  (read-only). A macOS major upgrade can revert the autofs trio, which the
  installer does not manage, to defaults, or a BTM approval reset can leave a
  LaunchDaemon **"file present but not loaded"**, so the verdict comes from the
  actual load state, contents, ownership, permissions and drift against the repo
  rather than from file existence.
  It never remediates automatically and only prints the per-item remedy
  (Principle 21). Exit codes 0/1/2 distinguish healthy, faulty and
  verdict-incomplete (root-only items skipped) (Principle 25).
  Registered **'Separate inspection from installation'** in the decision log — the
  basis for the separation is that there are faults a reinstall does not fix
  (reversion of the autofs trio, which is outside the installer's remit). Entry
  points were placed in README, install and operations so that this tool is run
  first both right after installation and right after an OS upgrade
- The cruft cleanup (`mac-cruft-cleanup`) now **sweeps the share root once more at
  depth 1** — the Finder creates cruft at the root of the mounted share, so once
  the share root is raised a workspace-only sweep no longer reaches it. Adding the
  share root to the systemd unit's `ReadWritePaths` is the matching half (under
  `ProtectSystem=strict`, deletion in a path not listed there fails silently)

- **Layer 7 registered in the failure model: server-local writes are invisible to
  the client cache** — in the combination where the guest writes and the Mac reads,
  cached content goes stale indefinitely (measured: one-shot read stale at T=120s,
  held-fd >=180s, partial read >=900s). The lease is never broken (measured with
  `smbstatus`) and the only healing is a change notify push, whose channel was
  observed wedging silently in a bistable manner. The remedy added `nodatacache` to
  the autofs map (measured cost zero across 4 workloads). Server-side
  `kernel oplocks` was rejected, having proved to be a caching confiscation that
  hands SMB2/3 clients an empty lease. **Principle 28** (a push is an accelerator,
  not a guarantee) registered.
  The measurement ledger is `docs/history/layer7-cache-coherency.md`

### Changed

- **`tools/probe-layer4b.sh` and `tools/cleanup.sh` no longer hardcode the account
  and paths.** Both predated configuration externalisation and still carried a
  personal account name and workspace path in variables at the top, so anyone else
  running them would have targeted the wrong account and path.
  `probe-layer4b.sh` now resolves the configuration exactly as `doctor.sh` does
  (deployed copy, then the repo's, with `--config` to override) and derives the
  LaunchDaemon label from `SMBG_LABEL_PREFIX` using the same assembly rule as
  `host/install.sh`. `cleanup.sh` takes `--owner <account>`, falling back to
  `SMBG_OWNER` from the configuration; the configuration is deliberately **not**
  required there, because the users who need that tool are migrating from a v13
  deployment and predate configuration externalisation entirely.
  Also removed the `|| echo 501` fallback on the UID lookup in `cleanup.sh` — a
  leftover of the pattern dropped in 1.0.0 under 'Removed the account lookup
  fallback'. That UID selects the launchd domain to `bootout`, so a guessed value
  would target an unrelated user's domain.

- **The project language is now English** — code comments, user-facing output (log
  lines, errors, help text), documentation, commit messages and pull requests. This
  repository is published so that people running the same setup do not have to
  rediscover these failures, but its inbound traffic is essentially all search, and
  a Korean surface reached none of it. Machine translation does not solve this: what
  is never found never gets translated either.
  `docs/history/` stays in Korean. It is the session handoff ledger — raw
  measurement logs and reasoning as it happened — roughly half of all documentation
  by volume, lowest in external value, and where a translation would most easily
  degrade the one thing that makes it worth keeping: which hypothesis was refuted by
  which measurement. Its findings are already distilled into the failure model and
  the decision log. `docs/history/README.md` states this in place.
  Git history is not rewritten (the repository is already public and the PR numbers
  in those subjects would stop matching their GitHub pages), so this file is the
  English-language record.
  A side effect: **Principle 29's trigger is removed at the source.** It existed
  because a variable expansion followed by Korean made macOS bash 3.2 fold the
  multibyte character's first byte into the variable name, killing the collision
  probe right before its verdict. The braces and the regression check are kept, since
  the principle still applies to anyone printing non-ASCII, and its wording is now
  past tense.
  Log strings changed with everything else, so `./install.sh` has to be re-run for
  the deployed copies to carry the new messages — until then `tools/doctor.sh` will
  correctly report drift against the repo.

### Fixed

- **Guest transfer no longer floods the output with tar warnings.** `install.sh`
  passed `--no-xattrs` to suppress them, but BSD file flags come from `chflags`
  rather than from extended attributes, so they survived and the guest's GNU tar
  still emitted one `Ignoring unknown extended header keyword 'SCHILY.fflags'` per
  entry — the exact noise that option existed to prevent, and the kind that buries a
  real error. Added `--no-fflags`.

- **Corrected the interpretation of the Layer 7 bistability: what differs is not
  notify delivery but whether the client data cache is used at all** — while
  verifying the nodatacache change, a default-options mount was also measured
  retransmitting all 1000 held-fd 64KB re-reads (64MB) (compared against the
  server's tx_bytes). The freshness of the inactive state, previously interpreted
  as "notify push heals it in 40ms", was corrected to "it never reads from the
  cache in the first place". A caveat was added to the measured-cost-zero
  conclusion (the baseline side was a comparison in the cache-inactive state), and
  a traffic probe for determining the cache state was added to the collection
  procedure

- **The probe died right before its verdict under a UTF-8 locale.** A variable was
  followed by Korean text without braces, so macOS's bash 3.2 folded the first byte
  of the multibyte character into the variable name. The measurement was already
  finished, so the `FAIL` list appeared but the summary and the verdict were lost —
  when a diagnostic tool dies right before its verdict, a successful measurement is
  useless. It was not reproducible under `LC_ALL=C`, so it passed in the author's
  shell. Registered as **Principle 29**
- **The probe returned exit 1 in a healthy state.** In a layout with the share root
  raised, the workspace's own name necessarily remains, and that was being reported
  as contamination. The expected residue is now distinguished, so healthy exits 0
  and only other contamination exits 1 (Principle 23)

### Documentation

- **Settled the upstream identity of Layer 6.** It is not specific to our
  environment but a Samba regression (introduced by `09f49fb56a4`, fixed on master
  by `2fc21d87`, upstream bug 16144), not yet backported to the release branches.
  The open item narrowed from "has it been fixed" to "when will it be backported"

### Compatibility

**A 1.0.0 configuration file still works unchanged — this is a minor release.**
Both new configuration keys are optional and fall back to the previous behaviour
when unset (`SMBG_EXPORT_ROOT` -> `SMBG_GUEST_ROOT`, `SMBG_SHARE_SUBPATH` -> none).
The second argument of `mac-cruft-cleanup` is optional too, and the shallow sweep
is skipped when it equals the first.

Two changes fall outside the compatibility unit (the configuration file and the
deployment paths) but are worth knowing about before upgrading:

- **Log strings are now English.** Anything parsing `/var/log/smb/smb-guard.log`
  by its message text needs updating. The tags (`[watch]`, `[ensure]`,
  `[wakeup +Ns]`, `[smbfix]`) and the `state=` values (`HEALTHY`, `ABSENT`,
  `FOREIGN`) are unchanged. Re-run `./install.sh` for the deployed copies to carry
  the new strings; until then `tools/doctor.sh` correctly reports drift against the
  repo.
- **`tools/cleanup.sh` now requires an owner account**, via `--owner <account>` or
  `SMBG_OWNER` in the configuration. It is not a deployment target and exists only
  to migrate away from a v13 layout, so this affects no installed system.

---

## [1.0.0] — 2026-08-15

First public release. It is based on the state after real operation and
verification on macOS 26 + Parallels + Ubuntu 26.04 prior to publication (see the
lineage below).

### Added

- Mount ownership watch and remediation (`smb-guard`) — fires immediately via the
  mount event hook, 4 modes (`watch`/`--ensure`/`--remount`/`--state`)
- Sleep and wake hooks (`smb-guard-sleep`, `smb-guard-wakeup`) — spurious-wake
  gate, network wait, clock correction, mount assurance, liveness probe
- Manual recovery tool (`smbfix`)
- Guest clock step (`clockfix`) — fractional epoch, immediate return of NTP sources
- Guest cruft cleanup (`mac-cruft-cleanup` + a systemd timer) — the replacement for
  server-side blocking
- Configuration externalisation (`smb-guard.conf`) and template substitution at
  deployment time
- Unified host/guest install orchestrator
  (`--host`/`--guest`/`--dry-run`/`--samba`)
- Documentation: the 6-layer failure model, 27 design principles, the decision log,
  operations and diagnostics guides

### Changes made for the public release

- **Configuration externalisation** — the account, mount point, guest alias, share
  name and Label prefix were separated out of the code
- **`host/` and `guest/` structural split** — previously the host and guest files
  were mixed in one directory
- **Removed the hardcoded IP fallback** — when the `/etc/hosts` lookup fails, the
  hostname is used as-is
- **Fixed `/etc/hosts` parsing** — from looking only at the second field to scanning
  every field. It was failing to match the form where aliases follow the canonical
  name (`10.0.0.4  host.domain  host`)
- **Fixed the remote diagnostic path** — the `find` sent to the guest was using the
  host mount path. It now uses the guest path (`SMBG_GUEST_ROOT`)
- **Separated the SMB authentication account** (`SMBG_SMB_USER`) — it may differ
  from the local owner account
- **Removed the account lookup fallback** — a failed UID lookup now fails instead of
  falling through to a default. A fallback would touch the mount under an unrelated
  user's credentials
- **Generalised the wake user hook** (`SMBG_WAKE_USER_HOOK`) — from a hardcoded
  application path to an optional hook

---

## Pre-release lineage

Development before publication was carried forward through handoff documents. The
full text is in [docs/history/](docs/history/).

| Lineage | Summary |
|---|---|
| v13 | Clarified the failure model (Layers 0-4), removed the expiry window, introduced the mount event hook. Went into operation |
| v14 series | Unified deployment into the system domain. Unified and rotated the logs, split out the shared library. **Fixed 2 bugs in the v13 logic** (false lock success, ghost lock) |
| v15 | All verification items passed, settled. Wake performance 15s -> **4s** |
| v16 | Restructured the clock layers. Clarified and removed the hypervisor synchronisation that was killing guest NTP. Fractional epoch for `clockfix` |
| v17 | Resolved the Finder copy blockage (`-8062`). Abolished server-side blocking, moved to post-hoc cleanup |

Bugs fixed and hypotheses rejected in the v14 series:

- **False success on lock failure** — when `--ensure` could not take the lock it did
  nothing and returned success. The caller believed the mount was assured and moved
  on to the next stage
- **Ghost lock** — a `SIGKILL` left the lock behind forever, and from then on
  everything went silent. An asymptomatic failure that left nothing in the log
  either
- **Text parsing of a plist** — a `grep` pattern matched the Label value and aborted
  a perfectly good installation
- **Silent exit under `set -e`** — a failed assignment from a command substitution
  killed the shell without a word, leaving a partially deleted state
- **EXIT trap false positive** — the return value of an AND list in the last
  statement became the exit code and reported a normal completion as an error. When
  the mechanism that announces failure false-positives, the next real failure gets
  ignored too
- **6 rejected hypotheses** — 5 about the unmount EPERM (TCC/FDA, the mount's owner,
  kernel blocking during the sleep transition, low-level characteristics, timing) +
  darkwake session disconnection
