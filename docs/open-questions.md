# Open questions and latent risks

What is settled is kept apart from what is not. **Rejected hypotheses are not
here** — they are in [failure-model.md](failure-model.md) and [history/](history/),
and the point of recording them is that they need no re-testing.

## Latent risks (no symptom, but with grounds)

### Names other than the workspace appearing at the share root

The remedy for Layer 6 (share root name collision) is to raise the share root above
the workspace, **shrinking the collision set to the single workspace name**. That
one remains — creating a file inside the workspace whose name matches an entry name
at the share root makes that file impossible to overwrite or delete.

It does not overlap git's internal filenames (`config`, `index`, `HEAD`,
`packed-refs`, `ORIG_HEAD`, `COMMIT_EDITMSG`), so the practical risk is low. The
containment condition for this risk is that the set does not grow **as long as the
share root is a dedicated directory with nothing else in it.**

Resume condition: if something ever needs to be added at the share root, first check
that its name does not appear as a filename anywhere in the workspace.

### The client-side effect of `case sensitive = yes`

git is case-sensitive, so the server was configured to be as well. But **the macOS
Finder operates on the premise that case is ignored**, and where those two premises
collide an intermittent "file not found" could appear.

This has not been demonstrated. Until a symptom appears it is registered only as a
latent risk. Should it manifest, a comparison against `case sensitive = auto` would
be the first experiment.

### Mistaken deletion of the `._*` files that `fruit:resource = file` creates

The cleanup tool treats `._*` as macOS cruft and reclaims it. But **a `._*` holding
a genuine resource fork** entering the workspace would be deleted too.

This risk was accepted on the judgement that it does not arise in a source code
tree. To keep files that use resource forks (older Mac documents, some fonts and
archives) on this share, remove `._*` from `mac-cruft-cleanup`'s file list.

This is the price of the decision not to use `fruit:resource = stream` — `stream`
would create a fresh write failure of the same shape as
[Layer 5](failure-model.md#layer-5--blocking-incidental-files-kills-the-primary-function)
because of the xattr size limit.

### Layer 7 bistability — what determines whether the cache is active

The indefinite staleness of Layer 7 is not permanent but **a state** — in the same
configuration, process and session, both a cache-active state (one-shot reads stale
indefinitely) and a cache-inactive state (every read goes to the server; all 1000
held-fd 64KB re-reads measured as retransmitted) were observed. What the first
version interpreted as a "notify push wedge" was corrected by the follow-up traffic
measurement — what differs is not push delivery but **whether the client uses its
data cache at all**. The lease `(RH)` is granted identically in both states.

What determines active versus inactive is unknown. The candidates are session
resumption across Mac sleep/wake, the guest clock step (Layer 1), and lease epoch
renewal from an smbd reload; inotify queue overflow is close to rejected on its own,
having failed to re-induce the state with a storm of 50,000 events.

The `nodatacache` remedy (Layer 7) blocks entry into the dangerous state regardless
of this trigger, so this item is a question of **model completeness**, not a
premise of the remedy.

Resume condition: resume immediately if staleness is observed again with
`nodatacache` applied — that would also be a refutation of the remedy. On
encountering a cache-active state, run the Layer 7 collection procedure (including
the traffic probe) **before reloading.**

### The effect of `nodatacache` is unverified against a cache-active state

The effect of `nodatacache` only shows up behaviourally in the cache-active
(dangerous) state, and the client was in the cache-inactive state when it was
applied, so **behavioural verification was impossible in principle** — a
default-options comparison mount matched byte for byte across all three channels
(repeated-read timing, open-dominated traffic, held-fd traffic). Delivery of the
option itself was confirmed (the `/etc/auto_smb` map line, remounted after
`automount -vc`).

The argument for its effect rests on the mechanism (with no data cache there is no
cache to go stale) and on the manual's semantics. The condition for verification is
the reappearance of a cache-active state: if a temporary default-options mount is
then stale while the production mount is fresh, that demonstrates it; if the
production mount is stale too, that refutes it.

## Unconfirmed

### `fruit:nfs_aces` in `[global]` — the collateral of disarming the NFS ACE channel

The predecessor of this item ("`fruit:nfs_aces = no` does not gate the modify
path") was **resolved 2026-08-19 by reading the 4.23.6 source** — its resume
condition, executed. `check_ms_nfs()` in `source3/modules/vfs_fruit.c` does guard
the modify path: with the option off it returns early and no chmod happens. But
the module reads the option with `lp_parm_bool(-1, ...)`, which consults the
`[global]` section only, exactly as the manual's GLOBAL OPTIONS section says:
"must be set in the global smb.conf section and won't take effect when set per
share". This repository's template carried the option **inside the share
section**, where it is a silent no-op — the measured acceptance of
`MS NFS chmod request` was the guard never arming, not a defect. Nothing to
report upstream. The same flag also drives the query side (`fruit_fget_nt_acl()`,
the AAPL `SUPPORTS_NFS_ACE` capability advertisement, and the UNIX mode in
enriched enumeration), so the old comment's "kept for the query side" was wrong
too — per share, the line did nothing at all.

What remains unmeasured is the switch actually thrown. Off in `[global]`, the
server stops advertising the capability at AAPL negotiation, and the whole
channel goes down with it: the Archive Utility's self-destructive 0644 would be
neutralised, but **every intentional mode operation from the Mac (`chmod +x`
included) rides the same channel**, and mode display on the client goes
synthetic — which may make git on the Mac see phantom executable-bit changes.

Resume condition (needs sudo on the guest, and a fresh SMB session from the Mac —
AAPL capabilities are negotiated once per session):
1. Move the option to `[global]` and restart smbd —
   `tools/experiment-layer8-nfs-aces.sh` is the reviewed switch, with `--revert`.
2. On a probe mount, measure the collateral: `ls -l` mode display, intentional
   `chmod` (loud failure, silent no-op, or locally faked?), and `git status`
   against a tree with executable bits.
3. Re-run the Archive Utility end-to-end: with its chmod ignored, the extraction
   may simply succeed — which upgrades Layer 8's remedy from operational
   avoidance to a server-side fix (the template's commented-out `[global]` entry
   then becomes active).

### When the Layer 6 fix gets backported

The identity of the defect and the fixing commit are settled (failure-model.md
Layer 6, 'Upstream'). What remains is **when it lands on a release branch**, and
that is not ours to decide.

The time to check is when upgrading Samba. If both of the following hold, whether to
undo the raised share root can be reconsidered — there is no **obligation** to undo
it. Putting the share root above the workspace is defensive in its own right, even
without this defect.

```bash
# Whether the installed version carries the fix — using dirfsp means it is fixed
grep -n -A12 'streams_xattr_unlinkat' source3/modules/vfs_streams_xattr.c | grep -n 'cwd_fsp\|dirfsp'
# The empirical check is tools/probe-rename-collision.sh (temporarily lower the share root and judge)
```

### Cross-domain inheritance of Full Disk Access (FDA)

Whether the FDA granted to the sleepwatcher binary **also holds when executed in the
system domain (as a LaunchDaemon)** was never confirmed. Being a path-based grant it
is **presumed** to persist, but this was not measured.

There is no functional impact — the design deliberately avoids using `ls` results
for determination. This item matters only when interpreting how often EPERM appears
in the log.

### The execution-context factor in Layer 4b

Five hypotheses were rejected, and the one that remains (launchd system domain vs
login session) **cannot be reproduced from a shell.** Testing it would require a
one-off LaunchDaemon.

The investigation was ended because there is no functional impact (`diskutil` is
stage 1). **The resume condition is built into the log** — the appearance of
`falling back to umount` is the signal.

### Cold-start behaviour of hypervisor time synchronisation

It remains to confirm that the behaviour which kills guest NTP is **also absent on a
cold start (power off then on)**. Every check so far was a warm reboot.

```bash
journalctl -b | grep -iE "set-ntp|Disabling unit"   # must be 0
systemctl is-enabled chrony && systemctl is-active chrony
```

### The single cause of `No locks available` (ENOLCK)

It was observed with a missing map credential and a clock skew present **at the same
time**, so the causes could not be separated. Restoring the credential resolved it,
but which of the two was the cause is undetermined.

If it recurs, determine it with the clock in a healthy state.

## Improvement candidates

- **Hypervisor pause/resume hooks** — only host sleep is handled today. A clock step
  is needed when the guest itself is paused and resumed too.
- **Observing the cleanup tool's sweep cost** — as the workspace grows, a `find`
  every 15 minutes could become a burden. Excluding build artefacts currently
  removes 97% of the traversal.
- **Considering `nt acl support = no`** — for cases where POSIX ACLs (`+`)
  accumulate through SMB. Against Layer 8's client permission writes it is now the
  **second** candidate: `fruit:nfs_aces = no` in `[global]` cuts the same chmod
  channel more narrowly (see 'fruit:nfs_aces' under Unconfirmed), while this one
  takes the whole NT ACL surface down with it.

---

When contributing: please record the **symptom, the grounds and the resume
condition** together when adding an item here. An item that says only "needs
checking" gives the next person nothing to judge with.
