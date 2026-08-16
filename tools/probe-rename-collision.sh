#!/bin/bash
# probe-rename-collision.sh — determination and regression check for share root
# name collision (Layer 6).
#
# Background: when deleting a file, Samba clears alternate data streams via
#       delete_all_streams(), and that path uses only the basename, resolving it
#       **relative to the share root**. If a name of the same basename exists at
#       the share root, it opens the wrong object and fails, surfacing to the
#       client as ENOENT.
#       -> An existing file whose basename matches an entry name at the share root
#          cannot be overwritten or deleted anywhere in the tree. `.git/config`
#          gets caught by this and git breaks.
#       Details in docs/failure-model.md Layer 6.
#
# What this tool does: fetches the share root's entry names from the guest and
#       actually attempts an "overwriting rename" with each of those names on the
#       mount. The names that fail are exactly the **contaminated basename set**.
#
# Verdict (exit codes):
#   0 = healthy. Either nothing failed, or the only failure is the **expected
#       residue**. In a layout with the share root above the workspace, the
#       workspace's own name necessarily remains — it is a legitimate entry of the
#       share root
#   1 = fault. Some other name is contaminated. Either something appeared at the
#       share root (raised layout), or the workspace is being exported directly in
#       the first place (unremediated — nearly every name at the root fails)
#
#   Why the expected residue is not reported as contamination: **if the healthy
#   state raises an alarm every time, the real faults get ignored along with it**
#   (Principle 23).
#
# How to read it: zero failures means either there are no streams (the server runs
#          without fruit) or it is already resolved.
#          **The measurement is only valid if the control succeeds** — if even the
#          control fails, the problem is the mount or permissions, not this defect
#          (Principle 25: silence means two different things).
#
# It deletes nothing — it works only inside a temporary directory of its own making
# and reclaims it on EXIT. No root needed. Run it as the owner account.
#
# usage: ./probe-rename-collision.sh [--config <path>]

set -u

CONF="${SMBG_CONF:-/usr/local/etc/smb-guard.conf}"
[ "${1:-}" = "--config" ] && { CONF="${2:?--config requires a path}"; shift 2; }

[ -r "$CONF" ] || { echo "configuration not readable: $CONF" >&2; exit 78; }
# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_MP:?$CONF: SMBG_MP is not set}"
: "${SMBG_HOST:?$CONF: SMBG_HOST is not set}"
: "${SMBG_GUEST_ROOT:=$SMBG_MP}"
: "${SMBG_EXPORT_ROOT:=$SMBG_GUEST_ROOT}"

# Expected residue = the name the client mounts under the share root (i.e. the
# workspace itself). Determined by the same rule as the guest-side install —
# SMBG_SHARE_SUBPATH is canonical, falling back to the workspace name. In a layout
# where the share root was not raised, there is no expected residue.
EXPECTED=""
if [ "$SMBG_EXPORT_ROOT" != "$SMBG_GUEST_ROOT" ]; then
    EXPECTED="${SMBG_SHARE_SUBPATH:-$(basename "$SMBG_GUEST_ROOT")}"
fi

mount | grep -q " on $SMBG_MP (smbfs" || {
    echo "$SMBG_MP is not mounted as smbfs — mount it first" >&2; exit 1; }

# Only the server knows the share root's entry list. When the mount points at a
# subdirectory it is invisible from the client, so fetch it over ssh.
names="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" \
         "ls -A -- '$SMBG_EXPORT_ROOT'" 2>/dev/null)"
[ -n "$names" ] || { echo "could not fetch the share root listing: $SMBG_HOST:$SMBG_EXPORT_ROOT" >&2; exit 1; }

WORK_LEAF=".probe-rename-collision.$$"
WORK="$SMBG_MP/$WORK_LEAF"
mkdir -p "$WORK" || { echo "could not create the work directory: $WORK" >&2; exit 1; }

# **The cleanup itself is caught by this very defect.** The reclamation targets
# include contaminated basenames, so an rm -rf from the Mac fails at unlink with
# ENOENT and the directory survives (measured). The guest sees a local filesystem
# and is unaffected, so delete from there — a diagnostic tool must not leave cruft.
cleanup() {
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" \
           "rm -rf -- '$SMBG_GUEST_ROOT/$WORK_LEAF'" 2>/dev/null; then
        return 0
    fi
    rm -rf "$WORK" 2>/dev/null
    if [ -d "$WORK" ]; then
        echo "!! could not reclaim the temporary directory: $WORK" >&2
        echo "   Delete it from the guest: ssh $SMBG_HOST \"rm -rf '$SMBG_GUEST_ROOT/$WORK_LEAF'\"" >&2
    fi
    return 0
}
trap cleanup EXIT

# Control: a name that certainly does not exist at the share root. If this fails,
# the measurement itself is invalid.
CONTROL="__probe_control_$$"

# For one name, attempt an "overwriting rename onto an already existing target".
#   0 = success (healthy)  /  1 = failure (contaminated name)
try_name() {
    local name="$1" d
    d="$WORK/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
    mkdir -p "$d" 2>/dev/null || return 2
    : > "$d/$name"   || return 2          # create the target first (it must exist to reproduce)
    : > "$d/src"     || return 2
    mv -f "$d/src" "$d/$name" 2>/dev/null && return 0
    return 1
}

echo "share root : $SMBG_HOST:$SMBG_EXPORT_ROOT"
echo "mount      : $SMBG_MP"
echo

if ! try_name "$CONTROL"; then
    echo "!! the control ($CONTROL) failed — this is a mount or permission problem." >&2
    echo "   It is not a determination of this defect (Layer 6). Measurement invalid." >&2
    exit 1
fi
echo "control OK — measurement valid"
echo

unexpected=""; n_ok=0; n_fail=0; n_bad=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if try_name "$name"; then
        n_ok=$((n_ok + 1))
        continue
    fi
    n_fail=$((n_fail + 1))
    if [ -n "$EXPECTED" ] && [ "$name" = "$EXPECTED" ]; then
        printf '  FAIL  %-24s (expected residue — the workspace itself)\n' "$name"
    else
        n_bad=$((n_bad + 1)); unexpected="$unexpected $name"
        printf '  FAIL  %s\n' "$name"
    fi
done <<EOF
$names
EOF

echo
# The braces around these expansions are kept deliberately. While this repository
# printed Korean, a variable expansion followed immediately by a multibyte
# character made macOS bash 3.2 fold that character's first byte into the variable
# name under a UTF-8 locale — `${n_ok}` would otherwise be looked up as `n_ok` plus
# 0xEA, and meeting set -u it died as an unbound variable. It was not reproducible
# under LC_ALL=C, so it only blew up in environments with a different locale — and
# it did leak exactly that way, killing this tool right before its verdict.
# English output removes the trigger, but the habit is worth keeping (Principle 29).
echo "ok ${n_ok} / failed ${n_fail}  (contaminated, excluding the expected residue: ${n_bad})"

if [ "$n_bad" -eq 0 ]; then
    if [ "$n_fail" -eq 0 ]; then
        echo "-> Healthy. No contaminated names — nothing at the share root collides at all."
    else
        echo "-> Healthy. The only failure is the expected residue '${EXPECTED}'."
        echo "   The raised share root layout is intact (failure-model.md Layer 6)."
    fi
    exit 0
fi

echo "-> unexpectedly contaminated basenames:${unexpected}"
echo "   Existing files with these names cannot be overwritten or deleted anywhere in the tree."
if [ "$SMBG_EXPORT_ROOT" = "$SMBG_GUEST_ROOT" ]; then
    echo "   The share root is the workspace itself — the remedy is to raise it one level"
    echo "   (docs/decisions.md 'Put the share root above the workspace, not at it')."
else
    echo "   The share root is already raised. Check whether something other than the workspace appeared there"
    echo "   (docs/open-questions.md 'Names other than the workspace appearing at the share root')."
fi
exit 1
