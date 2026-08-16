#!/bin/bash
# probe-layer4b.sh v2 — one-off diagnostic to determine the cause of Layer 4b.  sudo ./probe-layer4b.sh
#
# Background: `umount -f` returned EPERM only in a daemon context (smb-guard
# watch) — 08-08 12:19, once.
# Remaining hypotheses:
#   (a) execution context — launchd system domain vs login session
#   (c) timing            — an unmount is refused right after the mount (at the
#       moment the event fires)
# Rejected: TCC/FDA (observation 5), the mount's owner (on 08-08 a root mount was
# successfully unmounted from Terminal.app)
#
# v2 changes — problems exposed by the first run on 08-08:
#   - **Creating FOREIGN is a race.** In the empty window after an unmount, root's
#     ls competes with the owner's processes, and when the owner wins the result is
#     HEALTHY and the measurement is impossible. Retries were added.
#   - An "immediate umount" round was added to test hypothesis (c).
set -u

PLIST=/Library/LaunchDaemons/io.stewardlabs.smb-guard.plist
LABEL=system/io.stewardlabs.smb-guard
MP=/opt/stewardlabs
OWNER=sanha
RETRIES=5

[ "$(id -u)" -eq 0 ] || { echo "run as sudo ./probe-layer4b.sh" >&2; exit 1; }

state() {
    local line
    line="$(mount | grep -F " on $MP (smbfs" || true)"
    if   [ -z "$line" ];                        then echo ABSENT
    elif [[ "$line" == *"mounted by $OWNER"* ]]; then echo HEALTHY
    else                                             echo FOREIGN
    fi
}

restored=0
restore() {
    [ "$restored" -eq 1 ] && return 0
    restored=1
    echo
    echo "== restore =="
    /usr/local/sbin/smb-guard --remount >/dev/null 2>&1 || true
    echo "-- mount: state=$(state)"
    launchctl bootstrap system "$PLIST" 2>/dev/null || true
    if launchctl print "$LABEL" >/dev/null 2>&1; then
        echo "-- guard daemon: OK"
    else
        echo "-- guard daemon: !! reload failed. Run it by hand:"
        echo "     sudo launchctl bootstrap system $PLIST"
    fi
}
trap restore EXIT INT TERM

# Create a FOREIGN mount. Retry when the race is lost and the result is HEALTHY.
# 0=success 1=failure
make_foreign() {
    local i s
    for i in $(seq 1 "$RETRIES"); do
        diskutil unmount force "$MP" >/dev/null 2>&1 || umount -f "$MP" >/dev/null 2>&1 || true
        sleep 1
        if [ "$(state)" != "ABSENT" ]; then
            echo "   [$i] unmount failed (state=$(state))"
            continue
        fi
        /bin/ls "$MP" >/dev/null 2>&1 || true     # directory open in a root context
        sleep 2
        s="$(state)"
        if [ "$s" = "FOREIGN" ]; then
            [ "$i" -gt 1 ] && echo "   [$i] FOREIGN created"
            return 0
        fi
        echo "   [$i] lost the race — an owner process triggered first (state=$s), retrying"
    done
    return 1
}

echo "== initial state =="
echo "   state=$(state)"
mount | grep -F " on $MP " | sed 's/^/   /'

echo
echo "== 1. stop the watch daemon (so it cannot remediate mid-measurement) =="
launchctl bootout "$LABEL" 2>/dev/null || true
sleep 1
if launchctl print "$LABEL" >/dev/null 2>&1; then
    echo "   !! could not stop it — aborting"; exit 1
fi
echo "   stop confirmed"

# ── Round 1: umount after a delay — tests hypothesis (a) ───────────────────
echo
echo "== 2. round 1 — create FOREIGN, wait 3s, umount -f =="
if ! make_foreign; then
    echo "   !! lost the race all ${RETRIES} times — cannot create FOREIGN."
    echo "      Some owner process is touching $MP."
    echo "      Close editors, LSPs, file watchers and other shells' cwd, then rerun."
    echo "      (This race is itself why Layer 4 hijacking is intermittent — it is expected.)"
    exit 1
fi
mount | grep -F " on $MP (smbfs" | sed 's/^/   /'
sleep 3
out1="$(umount -f "$MP" 2>&1)"; rc1=$?
echo "   delayed umount -f: exit=$rc1${out1:+  output: $out1}"

# ── Round 2: immediate umount — tests hypothesis (c) ───────────────────────
echo
echo "== 3. round 2 — umount -f immediately after creating FOREIGN, no delay =="
echo "   (approximates the daemon's StartOnMount firing point. Going through a shell, it is not an exact reproduction.)"
rc2=""
if make_foreign; then
    out2="$(umount -f "$MP" 2>&1)"; rc2=$?
    echo "   immediate umount -f: exit=$rc2${out2:+  output: $out2}"
else
    echo "   !! could not create FOREIGN — round 2 skipped"
fi

# ── Verdict ────────────────────────────────────────────────────────────────
echo
echo "== verdict =="
if [ "$rc1" -ne 0 ]; then
    echo "   Round 1 failed -> a root mount cannot be unmounted even from a login session."
    echo "   Hypothesis (b), the mount's owner, comes back to life. The docs need review."
elif [ -n "$rc2" ] && [ "$rc2" -ne 0 ]; then
    cat <<'MSG'
   Round 1 passed / round 2 failed -> **hypothesis (c), timing, is supported.**
   An unmount is refused right after the mount. The daemon fires via StartOnMount
   at the moment the mount happens, so it has always been hitting this condition.
   The execution context is irrelevant.
   -> Settle Layer 4b in §1 of the docs as "timing" and update the rationale for
      the diskutil-first policy.
MSG
elif [ -n "$rc2" ]; then
    cat <<'MSG'
   Rounds 1 and 2 both passed -> not timing either. What remains is only (a), the
   execution context, and that cannot be reproduced from a shell. Further work
   would need a one-off LaunchDaemon.

   **Ending the investigation here is recommended.** There is no functional impact
   (diskutil is stage 1), and the cost of testing the remaining hypothesis exceeds
   the diagnostic value it would buy. Record it as open and resume if it recurs.
MSG
else
    echo "   Round 2 not measured — verdict withheld."
fi
echo
echo "   Add this output to the observation table in §1 of the handoff document."
exit 0
