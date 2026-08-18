#!/bin/bash
# doctor.sh — survival check of the host (macOS) configuration. Read-only: it
# fixes nothing.
#
# Why a separate tool: a macOS major upgrade can undermine this system's premises
# from two directions, and neither is decidable from "does the file exist".
#   - /etc/auto_master and /etc/autofs.conf are Apple-distributed files, so an
#     upgrade can revert them to defaults (repeatedly reported by the community;
#     undocumented by Apple). The autofs trio is exactly the area install.sh does
#     not manage (docs/install.md 'autofs configuration — what this repo does not
#     touch'), so a single reinstall does not restore it — which is why the check
#     has to be a tool separate from the install.
#   - When Background Items approval (BTM, macOS 13+) is reset, a LaunchDaemon
#     ends up "file present but not loaded". Only launchctl's view of the actual
#     load state distinguishes that.
#
# It never remediates automatically (Principle 21): "fixing" a file that has been
# ignored because its permissions were wrong means newly opening a privilege that
# was never granted. Each item only prints the remedy command; a human decides
# whether to run it. The blanket remedy for anything in the install-managed area
# is to re-run install.sh.
#
# Limits — what this tool cannot determine:
#   - For autofs it only reads file contents. Even with correct files, the runtime
#     still holds the old values until they are applied (sudo automount -vc) —
#     and whether they were applied cannot be known read-only.
#   - Whether the StartOnMount hook is actually armed cannot be distinguished via
#     launchctl print (see the caution in docs/install.md 'Verification' 1).
#     Verification that includes actual mount behaviour follows the install.md
#     'Verification' procedure.
#
# Verdict (exit codes):
#   0 = everything within the checked scope is fine (WARNs may be present)
#   1 = one or more faults
#   2 = no faults, but root-only items were skipped — rerun under sudo for a
#       complete verdict
#       (distinguished from 0 so that the "silence" of skipped items is not read
#       as healthy — Principle 25)
#
# usage: sudo smb-guard-doctor [--config <path>]     # deployed copy (host/install.sh)
#        sudo ./doctor.sh      [--config <path>]     # in place, from the repo
# Some items are skipped when not root. The deployed copy exists so that the
# mount's own doctor does not live on the mount it diagnoses; run it when the
# workspace mount itself is in question.

set -u

CONF=""
[ "${1:-}" = "--config" ] && { CONF="${2:?--config requires a path}"; shift 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Prefer the deployed configuration — the values the runtime actually reads must
# be what the verdict is based on. When there is no deployed copy (not installed,
# or lost), fall back to the repo's configuration and continue the rest of the
# checks.
DEPLOY_CONF="/usr/local/etc/smb-guard.conf"
if [ -z "$CONF" ]; then
    if   [ -r "$DEPLOY_CONF" ];         then CONF="$DEPLOY_CONF"
    elif [ -r "$ROOT/smb-guard.conf" ]; then CONF="$ROOT/smb-guard.conf"
    else
        echo "configuration not found: $DEPLOY_CONF, $ROOT/smb-guard.conf" >&2
        exit 78   # EX_CONFIG
    fi
fi
[ -r "$CONF" ] || { echo "configuration not readable: $CONF" >&2; exit 78; }
# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_OWNER:?$CONF: SMBG_OWNER is not set}"
: "${SMBG_MP:?$CONF: SMBG_MP is not set}"
: "${SMBG_HOST:?$CONF: SMBG_HOST is not set}"
: "${SMBG_SHARE:?$CONF: SMBG_SHARE is not set}"
: "${SMBG_SHARE_SUBPATH:=}"
: "${SMBG_LABEL_PREFIX:=io.stewardlabs}"
: "${SMBG_LOGDIR:=/var/log/smb}"
: "${SMBG_GUEST_ROOT:=}"
: "${SMBG_EXPORT_ROOT:=}"
: "${SMBG_REPO:=}"
SMBG_SHARE_PATH="$SMBG_SHARE${SMBG_SHARE_SUBPATH:+/$SMBG_SHARE_SUBPATH}"

GUARD_LABEL="$SMBG_LABEL_PREFIX.smb-guard"
WATCH_LABEL="$SMBG_LABEL_PREFIX.sleepwatcher"
GUARD_PLIST="/Library/LaunchDaemons/$GUARD_LABEL.plist"
WATCH_PLIST="/Library/LaunchDaemons/$WATCH_LABEL.plist"
NEWSYSLOG="/etc/newsyslog.d/$SMBG_LABEL_PREFIX.smb.conf"

OWNER_UID="$(id -u "$SMBG_OWNER" 2>/dev/null)" || {
    echo "account '$SMBG_OWNER' does not exist ($CONF)" >&2; exit 78; }
OWNER_HOME="$(dscl . -read "/Users/$SMBG_OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
: "${OWNER_HOME:=/Users/$SMBG_OWNER}"

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# Repo location — this tool runs from two places: in place from the repo
# (tools/doctor.sh) and deployed (/usr/local/sbin/smb-guard-doctor, so that the
# mount's own doctor does not live on the mount it diagnoses). $0 wins when it
# points inside a repo checkout; otherwise SMBG_REPO from the configuration.
# The repo normally lives on the guarded mount, so an unreachable repo must not
# read as a fault — repo-dependent items (the drift comparisons) skip instead
# (Principle 25: a skip is not a pass). REPOD is a never-readable stand-in that
# makes drift()'s own source check do the skipping.
if [ -e "$ROOT/tools/doctor.sh" ] && [ -d "$ROOT/host/sbin" ]; then
    REPO="$ROOT"
elif [ -n "$SMBG_REPO" ] && [ -d "$SMBG_REPO/host/sbin" ]; then
    REPO="$SMBG_REPO"
else
    REPO=""
fi
REPOD="${REPO:-/var/empty/smb-guard-repo-unresolved}"

# ── Verdict output ─────────────────────────────────────────────────────────
# skip means "not checked", not "healthy" — the exit code separates 0 from 2.
N_OK=0; N_FAIL=0; N_WARN=0; N_SKIP=0
section() { printf '\n== %s ==\n' "$1"; }
hint()    { [ -n "${1:-}" ] && printf '        -> %s\n' "$1"; return 0; }
ok()      { N_OK=$((N_OK + 1));     printf '  ok    %s\n' "$1"; }
warn()    { N_WARN=$((N_WARN + 1)); printf '  WARN  %s\n' "$1"; hint "${2:-}"; }
fail()    { N_FAIL=$((N_FAIL + 1)); printf '  FAIL  %s\n' "$1"; hint "${2:-}"; }
skip()    { N_SKIP=$((N_SKIP + 1)); printf '  skip  %s\n' "$1"; hint "${2:-}"; }

# check_file <path> <owner:group> <octal perms> — existence, ownership and
# permissions in one verdict.
# The dominant failure mode is "wrong permissions are silently ignored" (see the
# host/install.sh header), so checking existence alone is only half a verdict.
check_file() {
    local p="$1" og="$2" perm="$3" st
    if [ ! -e "$p" ]; then
        fail "$p missing" "re-run sudo ./host/install.sh"
        return 1
    fi
    st="$(stat -f '%Su:%Sg %Lp' "$p" 2>/dev/null)" || { fail "$p stat failed"; return 1; }
    if [ "$st" = "$og $perm" ]; then
        ok "$p ($st)"
    else
        fail "$p wrong owner/permissions: $st (expected $og $perm)" \
             "sudo chown $og '$p' && sudo chmod $perm '$p'  (or re-run install.sh)"
        return 1
    fi
    return 0
}

# drift <deployed> <repo source> — content comparison. Skipped when run outside
# the repo (no source present).
# WARN rather than FAIL because content alone cannot tell which side is newer — if
# the repo is ahead it means "reinstall needed", if the deployed copy is ahead it
# means "fold back into the repo".
drift() {
    local deployed="$1" src="$2"
    [ -r "$src" ] || { skip "drift: $deployed (no repo source)"; return 0; }
    [ -r "$deployed" ] || return 0   # absence was already reported as FAIL by check_file
    if cmp -s "$deployed" "$src"; then
        ok "no drift: $deployed"
    else
        warn "content differs from the repo: $deployed" \
             "check the direction with diff '$src' '$deployed', then re-run install.sh or fold back into the repo"
    fi
}

echo "smb-guard doctor — configuration $CONF"
[ "$IS_ROOT" -eq 1 ] || echo "(not root — some items are skipped. For a complete verdict: sudo $0)"

# ── 1. autofs — not install-managed, highest risk of upgrade reversion ─────
section "autofs (docs/install.md 'autofs configuration')"

if grep -Eq '^/-[[:space:]]+auto_smb([[:space:]]|$)' /etc/auto_master 2>/dev/null; then
    ok "/etc/auto_master direct map line"
else
    fail "/etc/auto_master has no auto_smb direct map line — suspect upgrade reversion" \
         "add '/-    auto_smb    -nosuid' then sudo automount -vc"
fi

if [ ! -e /etc/auto_smb ]; then
    fail "/etc/auto_smb missing" "recreate via the docs/install.md 'autofs configuration' procedure"
else
    st="$(stat -f '%Su %Lp' /etc/auto_smb 2>/dev/null)"
    if [ "$st" = "root 600" ]; then
        ok "/etc/auto_smb (root 600)"
    else
        # The URL contains credentials — readable by another user means leaked.
        fail "/etc/auto_smb wrong owner/permissions: $st (expected root 600 — the file contains credentials)" \
             "sudo chown root /etc/auto_smb && sudo chmod 600 /etc/auto_smb"
    fi
    if [ -r /etc/auto_smb ]; then
        map_line="$(awk -v mp="$SMBG_MP" '$1 == mp {print; exit}' /etc/auto_smb)"
        if [ -z "$map_line" ]; then
            fail "/etc/auto_smb has no entry for $SMBG_MP"
        else
            opts="$(printf '%s\n' "$map_line" | awk '{print $2}')"
            url="$(printf '%s\n' "$map_line" | awk '{print $3}')"
            case "$opts" in
                *-fstype=smbfs*) ok "map: fstype=smbfs" ;;
                *) fail "map: fstype is not smbfs ($opts)" ;;
            esac
            # soft is mandatory — a missing server must fail within finite time for
            # SMBG_TRIGGER_TIMEOUT and the wake hook's wait bounds to hold
            # (docs/install.md).
            case ",$opts," in
                *,soft,*) ok "map: soft" ;;
                *) fail "map: no soft option — infinite wait when the server is absent, hook wait bounds collapse" ;;
            esac
            # nodatacache is mandatory in a layout where the Mac reads guest-local
            # writes (Layer 7). A purely consuming mount does not need it, so this
            # is a WARN rather than a FAIL.
            case ",$opts," in
                *,nodatacache,*) ok "map: nodatacache" ;;
                *) warn "map: no nodatacache" \
                        "mandatory if this layout reads guest-local writes (failure-model.md Layer 7)" ;;
            esac
            case "$url" in
                *"@$SMBG_HOST/$SMBG_SHARE_PATH") ok "map: URL …@$SMBG_HOST/$SMBG_SHARE_PATH" ;;
                *) fail "map: URL does not match the configuration (expected …@$SMBG_HOST/$SMBG_SHARE_PATH)" ;;
            esac
        fi
    else
        skip "/etc/auto_smb content check (needs root)"
    fi
fi

tmo="$(sed -n 's/^AUTOMOUNT_TIMEOUT=//p' /etc/autofs.conf 2>/dev/null | tail -1)"
case "$tmo" in
    '')       fail "AUTOMOUNT_TIMEOUT not set — Apple's default 3600 = the expiry window is back (Layer 0)" \
                   "set AUTOMOUNT_TIMEOUT=604800 in /etc/autofs.conf then sudo automount -vc" ;;
    *[!0-9]*) warn "AUTOMOUNT_TIMEOUT='$tmo' — not a number" ;;
    *) if [ "$tmo" -lt 86400 ]; then
           warn "AUTOMOUNT_TIMEOUT=$tmo — the expiry window is under a day" \
                "confirm this is intended (the docs recommend 604800)"
       else
           ok "AUTOMOUNT_TIMEOUT=$tmo"
       fi ;;
esac

# ── 2. Deployed files — install-managed, blanket remedy is a reinstall ─────
section "deployed files (the host/install.sh managed area)"

check_file "$DEPLOY_CONF"                     root:wheel 644 && drift "$DEPLOY_CONF" "$REPOD/smb-guard.conf"
check_file /usr/local/lib/smb-guard/common.sh root:wheel 644 && drift /usr/local/lib/smb-guard/common.sh "$REPOD/host/lib/common.sh"
for f in smb-guard smb-guard-sleep smb-guard-wakeup smbfix; do
    check_file "/usr/local/sbin/$f" root:wheel 755 && drift "/usr/local/sbin/$f" "$REPOD/host/sbin/$f"
done
# The doctor's own deployed copy. Missing is a WARN, not a FAIL — its absence
# does not degrade the guarded system's function, it only means the next mount
# failure has to be diagnosed from the repo copy on that same mount.
if [ -e /usr/local/sbin/smb-guard-doctor ]; then
    check_file /usr/local/sbin/smb-guard-doctor root:wheel 755 && drift /usr/local/sbin/smb-guard-doctor "$REPOD/tools/doctor.sh"
else
    warn "smb-guard-doctor not deployed" \
         "re-run sudo ./host/install.sh (deploys tools/doctor.sh as /usr/local/sbin/smb-guard-doctor)"
fi
check_file "$GUARD_PLIST" root:wheel 644
check_file "$WATCH_PLIST" root:wheel 644
check_file "$NEWSYSLOG"   root:wheel 644
check_file "$SMBG_LOGDIR" root:wheel 755

# The sleepwatcher binary — can vanish through a brew migration or reinstall. Look
# at the actual path the deployed plist points to (the substituted value of the
# template's @SLEEPWATCHER_BIN@).
SW="$(plutil -extract ProgramArguments.0 raw -o - "$WATCH_PLIST" 2>/dev/null)" || SW=""
if [ -z "$SW" ]; then
    skip "sleepwatcher binary (could not read the path from the plist)"
elif [ -x "$SW" ]; then
    ok "sleepwatcher binary: $SW"
else
    fail "sleepwatcher binary missing: $SW" \
         "brew install sleepwatcher, then re-run sudo ./host/install.sh (the path may have changed)"
fi

# Drift of rendered artefacts — a template and a deployed file cannot be compared
# directly, so re-render with the same rules install.sh uses and compare. When the
# substitution value (SW) could not be obtained, treat it as unmeasurable.
if [ -n "$SW" ] && [ -r "$REPOD/host/LaunchDaemons/smb-guard.plist.in" ]; then
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smb-guard-doctor.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    render() {
        sed -e "s|@LABEL_PREFIX@|$SMBG_LABEL_PREFIX|g" \
            -e "s|@LOGDIR@|$SMBG_LOGDIR|g" \
            -e "s|@SLEEPWATCHER_BIN@|$SW|g" \
            "$1" > "$2"
    }
    render "$REPOD/host/LaunchDaemons/smb-guard.plist.in"    "$STAGE/guard.plist"
    render "$REPOD/host/LaunchDaemons/sleepwatcher.plist.in" "$STAGE/watch.plist"
    render "$REPOD/host/newsyslog.d/smb.conf.in"             "$STAGE/newsyslog.conf"
    drift "$GUARD_PLIST" "$STAGE/guard.plist"
    drift "$WATCH_PLIST" "$STAGE/watch.plist"
    drift "$NEWSYSLOG"   "$STAGE/newsyslog.conf"
else
    skip "rendered artefact drift (no repo template or no substitution value)"
fi

# ── 3. launchd load state — the detection point for a BTM reset ────────────
section "launchd (system domain — needs root)"

if [ "$IS_ROOT" -eq 1 ]; then
    if launchctl print "system/$GUARD_LABEL" >/dev/null 2>&1; then
        ok "$GUARD_LABEL loaded (state 'not running' is normal — it is an event hook)"
    elif [ -e "$GUARD_PLIST" ]; then
        fail "$GUARD_LABEL: plist present but not loaded — suspect a BTM approval reset" \
             "check System Settings > General > Login Items, then sudo launchctl bootstrap system $GUARD_PLIST"
    else
        fail "$GUARD_LABEL not installed" "sudo ./host/install.sh"
    fi
    watch_pr="$(launchctl print "system/$WATCH_LABEL" 2>/dev/null)"
    if [ -z "$watch_pr" ]; then
        if [ -e "$WATCH_PLIST" ]; then
            fail "$WATCH_LABEL: plist present but not loaded — suspect a BTM approval reset" \
                 "check System Settings > General > Login Items, then sudo launchctl bootstrap system $WATCH_PLIST"
        else
            fail "$WATCH_LABEL not installed" "sudo ./host/install.sh"
        fi
    elif printf '%s' "$watch_pr" | grep -q 'state = running'; then
        ok "$WATCH_LABEL resident (state = running)"
    else
        fail "$WATCH_LABEL loaded but not resident — the sleep/wake hooks are dead" \
             "check the log: $SMBG_LOGDIR/sleepwatcher.launchd.log"
    fi
else
    skip "$GUARD_LABEL load state (needs root)"
    skip "$WATCH_LABEL residency (needs root)"
fi

# A leftover user-domain agent created by brew makes the hooks fire twice
# (install.sh stage 1).
if launchctl print "gui/$OWNER_UID/homebrew.mxcl.sleepwatcher" >/dev/null 2>&1; then
    fail "the brew user-domain sleepwatcher is loaded — hooks will fire twice" \
         "brew services stop sleepwatcher"
else
    ok "no duplicate brew agent"
fi
if [ -e "$OWNER_HOME/Library/LaunchAgents/homebrew.mxcl.sleepwatcher.plist" ]; then
    warn "leftover brew sleepwatcher plist: $OWNER_HOME/Library/LaunchAgents/" \
         "not loaded, but it can be re-loaded at login — brew services stop sleepwatcher"
fi

# ── 4. Log rotation — wrong permissions are silently ignored ───────────────
section "newsyslog"

ns_out="$(newsyslog -nv 2>/dev/null)"
if [ -z "$ns_out" ]; then
    skip "cannot run newsyslog -nv (may need root)"
else
    n="$(printf '%s\n' "$ns_out" | grep -Fc "$SMBG_LOGDIR/")"
    if [ "$n" -eq 3 ]; then
        ok "3 rotation targets registered"
    else
        fail "${n} rotation target(s) (expected 3) — the configuration is being silently ignored" \
             "check root:wheel 644 with ls -l $NEWSYSLOG"
    fi
fi

# ── 5. Guest ssh — top priority (its failure kills clock correction) ───────
section "guest ssh"

ssh_out=""; ssh_ctx=""
if [ "$IS_ROOT" -eq 1 ]; then
    # The root context is the real check — the launchd hook reaches the guest by
    # exactly this path (sudo -u owner -H). Without -H it would see root's ~/.ssh
    # and the alias would not resolve.
    ssh_ctx="root->owner"
    ssh_out="$(sudo -u "$SMBG_OWNER" -H ssh -o BatchMode=yes -o ConnectTimeout=3 "$SMBG_HOST" 'date +%s' 2>/dev/null)"
elif [ "$(id -u)" -eq "$OWNER_UID" ]; then
    ssh_ctx="owner"
    ssh_out="$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$SMBG_HOST" 'date +%s' 2>/dev/null)"
else
    skip "guest ssh (neither owner nor root)"
fi
if [ -n "$ssh_ctx" ]; then
    case "$ssh_out" in
        ''|*[!0-9]*)
            fail "guest ssh failed ($ssh_ctx context): $SMBG_HOST" \
                 "docs/install.md 'Verification 0' — if this is dead, all clock correction is disabled" ;;
        *)
            if [ "$ssh_ctx" = "root->owner" ]; then
                ok "guest ssh OK (root context)"
            else
                ok "guest ssh OK (owner context — the root context is checked when run under sudo)"
            fi ;;
    esac
fi

# ── 5b. Guest Samba invariants — drift here reopens settled layers ─────────
# The guest smb.conf is deliberately merge-deployed (decision 'Do not deploy the
# guest Samba configuration automatically'), so a whole-file diff would flag
# legitimate manual merges. Instead, the invariants whose loss silently reopens a
# documented failure layer are asserted against the *running* configuration
# (testparm on the guest). Value spelling follows testparm's normalisation
# (module parameters echo verbatim and lowercase; parameters left at their
# default are omitted, which is why 'store dos attributes' is checked as a
# forbidden negative rather than a required positive).
section "guest samba invariants (testparm on $SMBG_HOST)"

TP=""
if [ -z "$ssh_ctx" ]; then
    skip "guest samba invariants (no ssh context)"
elif [ -z "$ssh_out" ]; then
    skip "guest samba invariants (guest ssh failed above)"
else
    if [ "$ssh_ctx" = "root->owner" ]; then
        TP="$(sudo -u "$SMBG_OWNER" -H ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" 'testparm -s 2>/dev/null')"
    else
        TP="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" 'testparm -s 2>/dev/null')"
    fi
    if [ -z "$TP" ]; then
        skip "guest samba invariants (testparm produced no output on the guest)"
    elif ! printf '%s\n' "$TP" | grep -q "^\[$SMBG_SHARE\]"; then
        fail "share [$SMBG_SHARE] missing from the running guest configuration" \
             "sudo ./guest/install.sh --samba, or merge guest/samba/smb.conf.in"
    else
        ok "share [$SMBG_SHARE] present"
        inv_require() {   # <exact configuration line> <what breaks without it>
            if printf '%s\n' "$TP" | grep -qF "$1"; then
                ok "$1"
            else
                fail "'$1' missing from the running guest configuration — $2" \
                     "merge guest/samba/smb.conf.in or re-run sudo ./guest/install.sh --samba"
            fi
        }
        inv_require "vfs objects = catia fruit streams_xattr" \
                    "macOS metadata falls back to ._* files and Finder interop degrades"
        inv_require "fruit:metadata = stream" "FinderInfo falls back to ._* files"
        inv_require "fruit:veto_appledouble = no" \
                    "unpacking Mac ZIP archives fails on Mac clients (vfs_fruit(8))"
        inv_require "fruit:resource = file" \
                    "= stream would turn large resource forks into Layer 5-shaped write failures (ext4 xattr limit)"
        exp_path="${SMBG_EXPORT_ROOT:-$SMBG_GUEST_ROOT}"
        if [ -z "$exp_path" ]; then
            skip "share path (no SMBG_EXPORT_ROOT/SMBG_GUEST_ROOT in the configuration)"
        elif printf '%s\n' "$TP" | grep -qF "path = $exp_path"; then
            ok "path = $exp_path"
        else
            fail "share path is not $exp_path — if it reverted to the workspace itself, Layer 6 name collisions return" \
                 "check [$SMBG_SHARE] in the guest /etc/samba/smb.conf"
        fi
        if printf '%s\n' "$TP" | grep -qE '^[[:space:]]*veto files'; then
            fail "veto files present — every Finder copy fails with -8062 (Layer 5)" \
                 "remove it; cleanliness is mac-cruft-cleanup's job (guest/samba/smb.conf.in header)"
        else
            ok "no veto files"
        fi
        if printf '%s\n' "$TP" | grep -qF "store dos attributes = No"; then
            fail "store dos attributes = No — DOS attributes get mapped onto the execute bits and pollute them" \
                 "remove the override; the default (yes) is what the template intends"
        else
            ok "store dos attributes not overridden to No"
        fi
        # Scoped to [global] on purpose: fruit:nfs_aces is a global-only option
        # and a per-share line is a silent no-op (Layer 8). A whole-output grep
        # would false-pass exactly the misplacement that hid Layer 8.
        if printf '%s\n' "$TP" | awk '/^\[/ { ing = ($0 == "[global]") } ing && /^[[:space:]]*fruit:nfs_aces = no$/ { found = 1 } END { exit !found }'; then
            ok "fruit:nfs_aces = no (in [global])"
        else
            fail "'fruit:nfs_aces = no' missing from [global] — the client chmod channel is armed and Layer 8 permission wreckage returns (Archive Utility kills its target, mode-0000 unrecoverables)" \
                 "sudo tools/experiment-layer8-nfs-aces.sh --apply on the guest, or merge guest/samba/smb.conf.in"
        fi
    fi
fi

# ── 6. Mount state ─────────────────────────────────────────────────────────
section "mount"

# The same determination as common.sh's smbg_state, reimplemented here — this tool
# must work even when the deployed copy is broken, so it does not source it.
mnt="$(mount | grep -F " on $SMBG_MP (smbfs" || true)"
if [ -z "$mnt" ]; then
    warn "mount absent (ABSENT)" "sudo smb-guard --ensure"
elif [ "${mnt#*mounted by $SMBG_OWNER}" != "$mnt" ]; then
    ok "mount HEALTHY (mounted by $SMBG_OWNER)"
else
    fail "mount FOREIGN — ownership hijacked" "sudo smb-guard --ensure"
fi

# ── 7. Workspace git filemode — the Layer 8 operating contract ─────────────
# With the NFS ACE channel disarmed (fruit:nfs_aces = no in [global]), git must
# ignore modes on the Mac and judge them on the guest. Two state faults break
# that split, and both are written by routine git use, not by configuration
# drift — which is why they are swept here (audit only, remedies printed —
# Principle 21):
#   - a repo-local core.filemode (clone/init writes one on either side)
#     poisons the *other* side's mode judgement;
#   - a Mac-side checkout of an executable file drops its server x bit
#     (the mode the checkout applies rides the disarmed channel), which the
#     guest sees as index-vs-worktree mode drift.
section "workspace git filemode (Layer 8 operating contract)"

if [ -z "$mnt" ] || [ "${mnt#*mounted by $SMBG_OWNER}" = "$mnt" ]; then
    skip "repo-local core.filemode sweep (mount not healthy)"
elif ! command -v git >/dev/null 2>&1; then
    skip "repo-local core.filemode sweep (no git on the host)"
else
    n_poison=0
    while IFS= read -r g; do
        [ -n "$g" ] || continue
        d="$(dirname "$g")"
        if v="$(git -C "$d" config --local core.filemode 2>/dev/null)"; then
            fail "repo-local core.filemode=$v: $d — poisons the other side's mode judgement" \
                 "git -C '$d' config --unset core.filemode"
            n_poison=$((n_poison + 1))
        fi
    done <<FILEMODE_SWEEP
$(find "$SMBG_MP" -maxdepth 4 -name .git 2>/dev/null)
FILEMODE_SWEEP
    [ "$n_poison" -eq 0 ] && ok "no repo-local core.filemode in workspace repositories"
fi

if [ -z "$ssh_ctx" ] || [ -z "$ssh_out" ]; then
    skip "guest mode-drift sweep (no guest ssh)"
elif [ -z "$SMBG_GUEST_ROOT" ]; then
    skip "guest mode-drift sweep (no SMBG_GUEST_ROOT in the configuration)"
else
    # `; true` keeps the transport status separate from grep's no-match status.
    remote='for g in $(find '"$SMBG_GUEST_ROOT"' -maxdepth 4 -name .git 2>/dev/null); do d="${g%/.git}"; git -C "$d" diff --summary 2>/dev/null | grep "^ mode change" | sed "s|^|$d:|"; done; true'
    if [ "$ssh_ctx" = "root->owner" ]; then
        md="$(sudo -u "$SMBG_OWNER" -H ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" "$remote")" || md="__SSH_FAILED__"
    else
        md="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" "$remote")" || md="__SSH_FAILED__"
    fi
    if [ "$md" = "__SSH_FAILED__" ]; then
        skip "guest mode-drift sweep (guest ssh failed)"
    elif [ -n "$md" ]; then
        fail "index-vs-worktree mode drift on the guest — a Mac-side checkout dropped x bits?" \
             "on the guest: git -C <repo> checkout -- <path>   (per line below)"
        printf '%s\n' "$md" | sed 's/^/        /'
    else
        ok "no index-vs-worktree mode drift in guest repositories"
    fi
fi

# ── Verdict ────────────────────────────────────────────────────────────────
printf '\nok %s / fail %s / warn %s / skipped %s\n' "$N_OK" "$N_FAIL" "$N_WARN" "$N_SKIP"

if [ "$N_FAIL" -gt 0 ]; then
    echo "-> Faults found. Follow the per-item remedy, or re-run sudo ./host/install.sh if the deployed files are at fault."
    exit 1
fi
if [ "$N_SKIP" -gt 0 ]; then
    echo "-> No faults, but the verdict is incomplete. Re-run with sudo $0."
    exit 2
fi
echo "-> Healthy."
exit 0
