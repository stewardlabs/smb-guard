# Decision log and design principles

**When the rationale is gone, the policy is up for review too.** That is why each
decision is recorded with its rationale and with the options that were rejected. The
purpose of this document is to keep the next person from walking a road that has
already been refuted.

---

## Decision log

### Eliminate the expiry window rather than shorten it

`AUTOMOUNT_TIMEOUT=604800` (7 days). `backupd` touches the share every 30 minutes,
so **no finite timeout above 1800 seconds means anything on its own**. The problem
is the window's existence, not its length.

### Give up on blocking `backupd`

`tmutil disable` had no effect (measured: 7 accesses continued after disabling).
`addexclusion` targets the wrong layer — it excludes from snapshots, it does not
block access. **When blocking is impossible, eliminate the window and remediate
immediately.**

### Remediate immediately via the mount event hook

`StartOnMount`, not periodic polling. The moment hijacking occurs is itself a mount
event, so it fires at exactly that point. The absence of self-healing while awake was
what prompted this decision.

It also fires for unrelated mounts (a USB stick, say), but the cost is one mount
table lookup.

### Keep a single remediation agent

Neither the wake hook nor the manual tool carries its own mount logic; both delegate
to `smb-guard`. Diverging determination criteria are the most dangerous class of bug
in this system.

**The boundary of the shared library**: only read-only material is shared
(constants, logging, state determination, credential switching), while code that
changes state (`force_umount`, `trigger`, retries) stays inside `smb-guard`. The
invariant being protected is "there is one remediation agent", not "the code lives in
one file" — sharing the determination logic actually strengthens that invariant.

### Do not use path access for determination

Read the `mount` table only. Path access (i) itself triggers the automounter and
changes what is being measured, and (ii) produces a TCC misjudgement in a daemon
context. This one decision makes Layer 3 structurally disappear and renders FDA
unnecessary.

### Unify deployment into the system domain

A structure where two hooks touch the same mount under different UIDs is a breeding
ground for permission and race problems, and the log paths inevitably diverge too.
The price is four points that need user credentials (ssh, the GUI `open`, the trigger
`ls`, the keychain probe), and those can be absorbed by explicit wrappers.

Covering sleep and wake at the logout/login window is an incidental gain.

### Detach sleepwatcher from the brew service

Homebrew generates the plist from the formula's service DSL, so a hand edit is lost
on `brew upgrade`. If the `-s`/`-w` path arguments vanish, sleepwatcher looks for its
defaults (`~/.sleep`, `~/.wakeup`), and when those files do not exist **the hooks
fail silently.**

### Prefix executable names with the family name

Never use a name like `/usr/local/sbin/sleep`. `/usr/local/sbin` comes **before**
`/bin` on the default PATH, so a `sleep 5` in a root shell or a script would execute
the hook — an extraordinarily hard accident to debug.

### Unify the logs into one file and rotate with newsyslog

wake -> guard firing -> manual intervention are causally entangled, so with separate
files every trace means correlating timestamps by hand. The tags
(`[watch] [ensure] [wakeup +Ns] [smbfix]`) distinguish them well enough.

Rotation uses the OS's `newsyslog` rather than self-truncation. Emptying with
`: > file` on a size overflow is not rolling but **total loss**, and it loses the log
right after an incident, of all times.

> A resident process keeps holding the fd of a rotated log. That is why `-V`
> (verbose) is not enabled on sleepwatcher — with almost no output there is no
> practical impact.

### Keep observational code off the critical path

`pmset -g log` parses the entire power log and takes **a measured 11 seconds**. Back
when this call sat right after the gate, purely observational code pushed the network
wait, clock correction and mount assurance all 11 seconds later — the only reason the
performance target was missed.

**The observation was moved, not removed.** The wake type is primary evidence for
Layer 2 determination and has real diagnostic value. Collected after the mount is
usable, the data is equally valid. wake+15s -> **wake+4s**.

### Do not parse structured data as text

Read plists with `PlistBuddy`/`plutil`. `grep`/`awk` (i) match fields you did not
intend and (ii) fail wholesale when the format changes (XML -> binary). A
`/sleepwatcher</` pattern actually matched the Label **value** and aborted a
perfectly good installation.

### Exclude hypervisor synchronisation from the clock layers

Exclusivity was forced, not chosen — details in [failure-model.md](failure-model.md)
Layer 1. When coexistence is impossible, **keep the instrumentable one.**

Why `clockfix` uses a fractional epoch: integer truncation (up to 1 second) was the
dominant error term. macOS `date` lacking `%N` is worked around with
`perl -MTime::HiRes`. RTT/2 compensation was **rejected** — anything below that is
the NTP daemon's remit, and putting precision logic into a coarse correction step
violates the role split.

### Do not install the guest integration tools

A follow-on from the decision above. `--time-sync off` **turns** the exclusivity off;
not installing **removes** it. A setting can be reverted by an auto-update, a
reinstall or a configuration restore, and the reverted state leaves no log, so it
goes undetected until the next skew — a defence that can be reverted is not a defence
but a reprieve.

That the cost is zero makes this decision easy. On a headless development guest the
tools' remaining features (clipboard, display, shared folders, automatic host hosts
registration) are either unnecessary or used in the opposite direction by this
design. The rationale table and the removal procedure are in
[failure-model.md](failure-model.md) Layer 1.

**A static guest IP is the matching half.** Giving up automatic `/etc/hosts`
registration on the host means using a static entry, and not replacing it with mDNS
(re-advertisement lag right after waking blocks the wake hook).

### Separate inspection from installation

All `install.sh` can restore on a re-run is what it deployed itself. But among the
premises this system rests on, **the autofs trio is deliberately outside install's
remit** (the same logic as 'Do not deploy the guest Samba configuration
automatically' below), and a macOS major upgrade reverts precisely those files to
defaults. Since there are faults a reinstall does not fix, **the inspection has to be
a tool separate from the install.**

`tools/doctor.sh` is read-only and never remediates automatically (Principle 21).
The key point is that its verdict comes from **the actual load state** rather than
from file existence — when Background Items approval is reset, the plist is intact
while the job is dead, and `ls` cannot tell those apart.

Splitting the exit code into 0 (healthy), 1 (faults) and 2 (**verdict incomplete** —
root-only items were skipped) is an application of Principle 25. Reading the silence
of a skipped item as healthy would make the inspection tool itself fall into the
"silence means two different things" trap.

### Abolish blocking and replace it with post-hoc cleanup

The requirement was not "block it" but "it does not remain". The detail and the
demonstration are in [failure-model.md](failure-model.md) Layer 5.

**Operational contract**: if cruft becomes a problem again, **fix the cleanup side.**
Restoring blocking is a reintroduction of `-8062`.

### Give `.Trashes` a 7-day grace period rather than deleting immediately

A trash you cannot undo is not a trash. If the Finder's "Move to Trash" becomes an
effective immediate delete, the user cannot trust it. That untracked files (build
artefacts, local configuration) can end up in there is another reason.

### Exclude build artefacts from the cleanup sweep

In a measured sample, **97% of the swept entries were under `target/` or
`node_modules/`**. Leaving the cruft inside them costs effectively nothing — build
artefacts are already covered by git ignore, so they do not pollute history, and they
disappear along with a build cache clean. It was a sweep with cost and no benefit.

`find`'s `-name` matches on **the name**, not the path, so it is independent of
depth — even when a workspace holds several repositories with `.git` scattered at
various depths, they are all excluded automatically.

### Do not deploy the configuration file as a symlink

What this system recovers is the workspace mount, so linking the configuration to a
canonical copy inside that mount would make **the means of recovery vanish the moment
the mount goes away.** It is a circular dependency. Copy it as a real file.

### Keep the install script

The documentation carries a placement table so manual deployment is possible too
([install.md](install.md)), but the script is not going away. The reason is that this
system's dominant failure mode is **"wrong permissions are silently ignored"**:

- a `newsyslog` configuration that is not `root:wheel 644` -> ignored without a word
  (the log grows without bound, no symptom)
- a LaunchDaemon plist that is not -> launchd refuses to load it
- group/other write bits on a script in `/usr/local/sbin` -> a root privilege
  escalation vulnerability
- sudoers that is not 0440 -> `visudo` warns

### Do not deploy the guest Samba configuration automatically

Overwriting an existing `smb.conf` wholesale would lose settings unrelated to this
share. The default behaviour is to print the substituted result for a human to merge;
`--samba` must be given explicitly to deploy it, and even then the existing file is
backed up.

### Put the share root above the workspace, not at it

Samba has a defect where deleting a file clears its streams while resolving the
basename relative to the share root, so **an existing file whose basename matches an
entry name at the share root cannot be overwritten or deleted anywhere in the tree.**
Exporting the workspace directly makes every name at that root the collision set —
`.git/config` gets caught by it and git breaks. The detail and the demonstration are
in [failure-model.md](failure-model.md) Layer 6.

Raising the share root one level shrinks the collision set to the single workspace
name, and since the client mounts a subdirectory of the share, **the visible layout
does not change.**

The alternative of turning the streams off (`fruit:metadata = netatalk` + removing
`streams_xattr`) also works, but small-file creation is 5x slower and every file
gets a `._` sidecar, so it was not chosen. Client mount options (`nostreams` and the
like) have no effect, because the server is what reports the streams.

**Operational contract**: put nothing but the workspace at the share root. Any name
that appears there becomes an "irreplaceable basename across the whole tree".

### Sweep the share root at depth 1 during cruft cleanup

The Finder creates its cruft **at the root of the mounted share.** The decision above
moved the share root outside the workspace, so a workspace-only sweep no longer
reaches it — and `.Trashes` in particular keeps files deleted through the Finder
unreclaimed.

At depth 1 the traversal cost is effectively zero. **The script and the systemd unit
have to be fixed together** — under `ProtectSystem=strict` a path not in
`ReadWritePaths` is read-only, and the deletion failure is silent. Fixing only one of
the two produces a state that "looks like it is cleaning while deleting nothing".

### Make the Layer 7 remedy a client cache block, not server-side oplocks

Three candidates were measured against the staleness of guest-local writes
(Layer 7): server-side `kernel oplocks`, client-side `nodatacache`/`nomdatacache`,
and doing nothing. `nodatacache` was chosen.

There are two decision axes. **First, state independence** — staleness exists only
while the client data cache is active, and the essence of Layer 7 is that active
versus inactive transitions silently (an interpretation corrected by a follow-up
measurement — see 'Bistability' in Layer 7). `nodatacache` contains entry into the
dangerous state itself and depends on neither the state transition nor notify. It is
the only candidate that does. **Second, cost** — no regression was measured across 4
single-pass workloads (A-B-B-A crossover), and the metadata cache stays alive so
`stat()`-dominated work is unharmed. The cost of re-read-intensive work relative to
the cache-active state is unmeasured, but a small-file round trip is under a
millisecond, so it was accepted.

`kernel oplocks` was rejected when its hypothesis ("a kernel break gives consistency
with the cache left on") collapsed under measurement — an SMB2/3 client is handed an
empty lease, so there is nothing to break, and the net effect is confiscation of
caching for the whole share. `nomdatacache` was rejected at 2.5-4.3x on
enumeration-dominated work. The detail is in failure-model.md Layer 7, and the
conditions for reconsidering in open-questions.md.

---

### Remedy client permission writes operationally, not in the Samba configuration

The Archive Utility chmods the destination directory it has just created to 0644
over SMB and its extraction dies against it (failure-model.md Layer 8). Every
server-side candidate for flooring such a write was measured out: the masks act at
creation only, the force parameters do not reach the security-descriptor path
(confirmed on a fresh session), the `security mask` family no longer exists
(removed in 4.11), and `fruit:nfs_aces = no` — whose comment in this repository's
own template promised exactly this protection — does not gate the modify path.

The remedy adopted is operational: archives are extracted with CLI tools
(`ditto`/`unzip`), recovery is a documented `chmod` (client-side while any owner
bit remains, guest-side for the 0000 class), and doctor.sh asserts the guest Samba
invariants so a drifted configuration cannot silently reopen the settled layers.
`nt acl support = no` — the one candidate that would cut the channel itself — was
deliberately not adopted: it would also take down every intentional mode change
from the Mac (`chmod +x` included), and that collateral has not been measured. It
stays in open-questions.md with its resume condition.

---

## Design principles

These were all obtained in the course of working out the failure model. The order is
by theme, not by discovery.

### Determination and observation

1. **Prefer the hypervisor (or any higher layer), but verify the assumption that it
   is "working" by measurement too.** A process being alive is not the feature
   working. A 21-hour skew went through while the light was green.
2. **Suspect the privilege boundary of your monitoring channel.** A launchd context
   is not a user's terminal.
3. **Base determination on primary evidence.** The mount table, error codes, the
   journal. Not a dialog's message.
4. Include a cache flush and an ownership check in the intervention loop.
5. **Record a policy together with its rationale.** When the rationale is gone, the
   policy is up for review too.
6. **First verify that a setting was actually applied.** This principle caught three
   things: an unapplied timeout value, an unexecuted clock correction, and wrong
   sudoers permissions. The lesson of the third pointed the other way —
   **a warning did not mean it was void.** Verification was not reading the warning
   but querying what was actually in effect (`sudo -l`).
7. Diversify the triggers of self-healing.
8. **Do not let the act of determination change its subject.**

### Expressing failure

9. **Confirm that something actually happened before returning success.** Silent
   success is worse than silent failure — the caller stacks subsequent judgements on
   top of it. Distinguish, by the caller's intent, the paths where backing off is
   correct from the paths where failing is correct.
10. **Design an expiry alongside any exclusive resource such as a lock or a flag.**
    A path where the cleanup code does not run (SIGKILL, a panic) always exists, and
    without an expiry the system dies **asymptomatically** from that moment on.
11. **An executable's name must be unique across the whole PATH.**
12. **Do not put observational code on the critical path.** The more diagnostic value
    a call has, the more expensive it tends to be. The time-axis version of
    Principle 8.
13. **Do not parse structured data as text.**
14. **A layer prefix is attached in exactly one place.** When a lower tool already
    identifies itself, the layer above does not add to it.
15. **Write "expected" on an expected failure.** When a fallback chain and errors
    designed to be ignored are indistinguishable from real failures, normal operation
    reads as a fault. Do not let subcommand output flow through verbatim; carry it
    inside the tag, and record the state after each stage as well, so that **the
    causality is reconstructable from the log alone**.
16. **Do not assume that a privilege verified in one component holds in another.**
    TCC attributes per responsible process.

### Designing intervention

17. **For work that needs privilege, delegate to a system daemon that has it rather
    than doing it yourself.** `diskutil` (-> `diskarbitrationd`) is more reliable
    than `umount` (a direct syscall) because it depends less on the caller's
    execution context.
18. **Do not delete a fallback; reorder it.** The correct remedy for "stage 1 always
    fails" is demotion, not deletion. Deleting it leaves no alternative when the
    remaining stage fails; demoting it removes only the noise. As a side effect,
    **that message reappearing becomes an anomaly signal** in itself.
19. **A refuted hypothesis does not necessarily invalidate the decisions built on
    it.** Distinguish whether the decision's basis was "an observed fact" or "an
    explanation of that fact". The reordering rested on the fact that "it always
    fails from a daemon", so it holds even though the causal hypothesis (TCC) was
    rejected.
20. **A script that does destructive work must never die silently.** For work where
    partial execution is itself damage, such as installation or cleanup, leave the
    fact of the abort and the recovery path via an EXIT trap.
    (Under `set -e`, a failed assignment from a command substitution exits the shell
    silently.)
21. **Do not let a cleanup become a privilege escalation.** "Fixing" a configuration
    file that has been ignored because its permissions were wrong means newly opening
    a privilege that was never granted. Audit, but do not remediate automatically —
    let a human decide what they want.

### Experiment and observation

22. **When measuring a self-healing system, stop the healing first.** If you induce a
    failure to observe it and the system fixes it immediately, what you are measuring
    changes while you measure it. The operational version of the observer effect, and
    the reverse direction of Principle 8.
23. **Verify your alarms on the healthy path too.** If the mechanism that announces
    failure false-positives, the next real failure gets ignored as well. Having added
    an EXIT trap, always confirm that it stays silent on the success case.
24. **A failed reproduction is data too.** When an attempt to induce a failure fails,
    do not write it off as "the environment is odd" — ask why it failed. The failure
    to reproduce hijacking revealed that it is **a race**, and that became the
    explanation for its intermittency.
25. **Before an experiment, confirm that your observation channel records that
    event.** The watch daemon logs only fault states, so expiry and recycling never
    appear in its own log — while 5 events occurred, the observer concluded "nothing
    is happening". Telling "no event" from "outside the channel" means looking at the
    event source. The observation version of Principle 6.

### Choosing a layer

26. **Blocking (deny) and cleanup are remedies at different layers for the same
    requirement, and are not interchangeable.** Blocking, at the server, an
    incidental action that the client was designed to treat as "abort everything on
    failure" kills that client's primary function. If what you want is **cleanliness
    of the resulting state**, the remedy is post-hoc cleanup — cleanup breaks nothing
    when it fails, whereas what fails when blocking fails is someone else's feature.
    Rewriting the requirement from "what should I block" to **"what do I want not to
    remain"** decides the layer.
27. **Do not assume a client-side suppression setting covers every path of that
    client.** Making the fact that a suppression is on a premise of your server-side
    defence means the feature dies the moment a path outside that premise opens. A
    suppression reduces inflow; it is a secondary aid, not a guarantee — the settings
    version of Principle 1.
28. **Do not make correctness depend on a push channel — a push is an accelerator,
    not a guarantee.** Turning off cache invalidation notify degraded polling-based
    healing into indefinite staleness — it was freshness that only held while the
    push was alive (Layer 7). And the cache state that is the precondition for that
    push having any effect was itself measured transitioning silently (Layer 7
    bistability). A lost push is not an error but an **absence**, so it appears in no
    log at all. Design what needs correctness as a pull (revalidation) or as no
    cache, and use a push only to shorten the latency on top of that — the same
    structure as Principle 27, repeated on the time axis.

### Shell and locale

29. **Brace a variable expansion when a non-ASCII character follows it immediately.**
    macOS's bash 3.2 folds the first byte of a following multibyte character into the
    variable name under a UTF-8 locale. Meeting `set -u` it dies as an unbound
    variable; without it, it silently becomes an empty string.

    What is dangerous is not the failure itself but **that the conditions for
    reproducing it live in the environment.** It is not reproducible under `LC_ALL=C`,
    so when the author's shell differs from the user's, code that passed verification
    blows up only on the other person's terminal.

    Until this repository switched to English, every script printed Korean, which
    made it a structural risk — and a diagnostic tool did die right before its
    verdict, making a successful measurement useless. English output removes the
    trigger at the source here, but the principle still applies to anyone printing
    non-ASCII, and the braces are kept.

    The regression check is one line:

    ```bash
    perl -ne 'while (/\$([A-Za-z_]\w*)(?=[\x80-\xFF])/g){print "$ARGV:$.\n"}' $(git ls-files)
    ```
