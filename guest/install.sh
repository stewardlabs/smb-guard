#!/bin/bash
# guest/install.sh — guest (Linux, Samba server) side deployment.
#
#   directly on the guest:  sudo ./guest/install.sh [options]
#   remotely from the host: ./install.sh --guest      (the top-level orchestrator transfers and runs it)
#
# What gets deployed:
#   /usr/local/sbin/clockfix              clock step right after resume (called over ssh by the host hook)
#   /usr/local/sbin/mac-cruft-cleanup     post-hoc cleanup of macOS cruft
#   /etc/systemd/system/mac-cruft-cleanup.{service,timer}
#   /etc/sudoers.d/clockfix               so the host hook can call clockfix without a password
#   /etc/smb-guard.conf                   configuration
#
# The Samba configuration is **not deployed by default** (pass --samba to do it).
# Overwriting an existing smb.conf wholesale would lose settings unrelated to this
# share. The default behaviour is to print the substituted result for a human to
# merge.
#
# Idempotent.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: sudo ./guest/install.sh [--config <path>] [--sudo-user <account>] [--samba] [--dry-run]

  --config <path>        configuration file (default: smb-guard.conf above this script,
                         otherwise the already-deployed /etc/smb-guard.conf)
  --sudo-user <account>  account to grant clockfix NOPASSWD. This is the account the
                         host wake hook logs in as over ssh. Defaults to $SUDO_USER.
  --samba                deploy smb.conf (an existing file is backed up as .bak-<timestamp>).
                         Without it, the substituted result is only printed.
  --dry-run              print the plan without deploying.
USAGE
    exit 2
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CONF=""; SUDO_TARGET="${SUDO_USER:-}"; DO_SAMBA=0; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config)    [ $# -ge 2 ] || usage; CONF="$2"; shift 2 ;;
        --sudo-user) [ $# -ge 2 ] || usage; SUDO_TARGET="$2"; shift 2 ;;
        --samba)     DO_SAMBA=1; shift ;;
        --dry-run)   DRY=1; shift ;;
        -h|--help)   usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

DEST_CONF="/etc/smb-guard.conf"
if [ -z "$CONF" ]; then
    if   [ -r "$ROOT/smb-guard.conf" ]; then CONF="$ROOT/smb-guard.conf"
    elif [ -r "$DEST_CONF" ];           then CONF="$DEST_CONF"
    else
        echo "No configuration file. Copy smb-guard.conf.example and fill in the values." >&2
        exit 78
    fi
fi
[ -r "$CONF" ] || { echo "configuration file not readable: $CONF" >&2; exit 78; }

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "run as sudo ./guest/install.sh (use --dry-run to only see the plan)" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_GUEST_ROOT:?$CONF: SMBG_GUEST_ROOT is not set}"
: "${SMBG_SHARE:?$CONF: SMBG_SHARE is not set}"
: "${SMBG_OWNER:?$CONF: SMBG_OWNER is not set}"
: "${SMBG_SMB_USER:=$SMBG_OWNER}"

# The root exported over SMB. The intent by default is to export **the level above**
# the workspace rather than the workspace itself — Samba has a defect where, on file
# deletion, it clears streams and resolves the basename relative to the share root,
# so a file whose basename matches a name at the share root cannot be overwritten or
# deleted anywhere in the tree (docs/failure-model.md).
# Falls back to the workspace itself when unset — existing deployments are unaffected.
: "${SMBG_EXPORT_ROOT:=$SMBG_GUEST_ROOT}"

case "$SMBG_GUEST_ROOT$SMBG_EXPORT_ROOT$SMBG_SHARE$SMBG_SMB_USER" in
    *"|"*) echo "configuration values may not contain the '|' character" >&2; exit 78 ;;
esac

# The subpath the client mounts. It **must equal** the host-side SMBG_SHARE_SUBPATH —
# the Mac mounts //account@host/<share>/<this value>, so the mount fails if the
# server has no such path. Defaults to the workspace name when unset.
: "${SMBG_SHARE_SUBPATH:=$(basename "$SMBG_GUEST_ROOT")}"

# If the share root was raised, the workspace must actually appear beneath it. This
# repo does not touch fstab (the same policy as not touching autofs), so it only
# checks and advises.
if [ "$SMBG_EXPORT_ROOT" != "$SMBG_GUEST_ROOT" ]; then
    _leaf="$SMBG_EXPORT_ROOT/$SMBG_SHARE_SUBPATH"
    if [ ! -d "$_leaf" ]; then
        echo "!! $_leaf does not exist." >&2
        echo "   To use SMBG_EXPORT_ROOT, the workspace must appear beneath it:" >&2
        echo "     sudo install -d -o $SMBG_OWNER -g $SMBG_OWNER -m 755 $SMBG_EXPORT_ROOT $_leaf" >&2
        echo "     echo '$SMBG_GUEST_ROOT $_leaf none bind,x-systemd.requires-mounts-for=$SMBG_GUEST_ROOT 0 0' | sudo tee -a /etc/fstab" >&2
        echo "     sudo systemctl daemon-reload && sudo mount $_leaf" >&2
        exit 78
    fi
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smb-guard-render.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

render() {   # render <template> <output path>
    sed -e "s|@GUEST_ROOT@|$SMBG_GUEST_ROOT|g" \
        -e "s|@EXPORT_ROOT@|$SMBG_EXPORT_ROOT|g" \
        -e "s|@SHARE@|$SMBG_SHARE|g" \
        -e "s|@SMB_USER@|$SMBG_SMB_USER|g" \
        "$1" > "$2"
}

render "$HERE/systemd/mac-cruft-cleanup.service.in" "$STAGE/cleanup.service"
render "$HERE/samba/smb.conf.in"                    "$STAGE/smb.conf"
cp "$HERE/systemd/mac-cruft-cleanup.timer"          "$STAGE/cleanup.timer"

if grep -n '@[A-Z_]\{3,\}@' "$STAGE"/* >/dev/null 2>&1; then
    echo "!! unsubstituted placeholders remain:" >&2
    grep -n '@[A-Z_]\{3,\}@' "$STAGE"/* >&2
    exit 1
fi

cat <<PLAN
== deployment plan (guest) ==
  configuration  $CONF -> $DEST_CONF                            (root:root 644)
  executables    guest/sbin/{clockfix,mac-cruft-cleanup}
                 -> /usr/local/sbin/                            (root:root 755)
  systemd        -> /etc/systemd/system/mac-cruft-cleanup.service (root:root 644)
                 -> /etc/systemd/system/mac-cruft-cleanup.timer   (root:root 644)
  sudoers        -> /etc/sudoers.d/clockfix                     (root:root 0440)
                 clockfix NOPASSWD for ${SUDO_TARGET:-<resolved from \$SUDO_USER at run time>}
  Samba          $( [ "$DO_SAMBA" -eq 1 ] && echo "-> /etc/samba/smb.conf (existing file backed up, then replaced)" \
                                          || echo "not deployed (substituted result printed only — use --samba to deploy)" )

  workspace      $SMBG_GUEST_ROOT                       (cruft cleanup: full sweep)
  share root     $SMBG_EXPORT_ROOT$( [ "$SMBG_EXPORT_ROOT" = "$SMBG_GUEST_ROOT" ] \
                && echo "  (same as the workspace — see failure-model.md Layer 6)" \
                || echo "  (cruft cleanup: depth 1)" )
  share          [$SMBG_SHARE]  valid users = $SMBG_SMB_USER
  mount URL      //$SMBG_SMB_USER@${SMBG_HOST:-<host>}/$SMBG_SHARE$( [ "$SMBG_EXPORT_ROOT" != "$SMBG_GUEST_ROOT" ] && echo "/$SMBG_SHARE_SUBPATH" )
                 (the Mac's /etc/auto_smb must match this path)
PLAN

if [ "$DRY" -eq 1 ]; then
    echo; echo "(--dry-run — nothing was deployed)"
    exit 0
fi

if [ ! -d "$SMBG_GUEST_ROOT" ]; then
    echo "!! workspace path does not exist: $SMBG_GUEST_ROOT" >&2
    echo "   Check SMBG_GUEST_ROOT in the configuration." >&2
    exit 1
fi

trap 'rc=$?; rm -rf "$STAGE"; if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "!! installation aborted (exit=$rc). The deployment may be partial." >&2
    echo "   Check:  systemctl status mac-cruft-cleanup.timer; ls -l /usr/local/sbin/clockfix" >&2
fi' EXIT

echo
echo "== 1. configuration =="
install -o root -g root -m 644 "$CONF" "$DEST_CONF"
echo "   $DEST_CONF"

echo "== 2. executables =="
install -d -o root -g root -m 755 /usr/local/sbin
for f in clockfix mac-cruft-cleanup; do
    install -o root -g root -m 755 "$HERE/sbin/$f" "/usr/local/sbin/$f"
    echo "   /usr/local/sbin/$f"
done

echo "== 3. sudoers (clockfix) =="
# The host's wake hook is non-interactive and cannot type a password. The argument
# wildcard is there to accept the epoch value (integer or fractional).
#
# **sudo refuses anything that is not 0440.** Deploy only after checking the syntax
# with visudo -c — a damaged sudoers makes sudo itself unusable, so writing first
# and checking afterwards is too late.
if [ -z "$SUDO_TARGET" ]; then
    echo "   !! --sudo-user was not given and \$SUDO_USER is empty."
    echo "      Skipping the clockfix NOPASSWD rule — clock correction on wake will fail."
    echo "      Later: echo '<account> ALL=(root) NOPASSWD: /usr/local/sbin/clockfix *' \\"
    echo "              | sudo tee /etc/sudoers.d/clockfix && sudo chmod 0440 /etc/sudoers.d/clockfix"
else
    printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/clockfix *\n' "$SUDO_TARGET" \
        > "$STAGE/clockfix.sudoers"
    if visudo -c -f "$STAGE/clockfix.sudoers" >/dev/null; then
        install -o root -g root -m 0440 "$STAGE/clockfix.sudoers" /etc/sudoers.d/clockfix
        echo "   /etc/sudoers.d/clockfix  ($SUDO_TARGET)"
    else
        echo "   !! sudoers syntax check failed — not deployed" >&2
        exit 1
    fi
fi

echo "== 4. systemd units =="
install -o root -g root -m 644 "$STAGE/cleanup.service" /etc/systemd/system/mac-cruft-cleanup.service
install -o root -g root -m 644 "$STAGE/cleanup.timer"   /etc/systemd/system/mac-cruft-cleanup.timer
systemctl daemon-reload
systemctl enable --now mac-cruft-cleanup.timer
systemctl list-timers mac-cruft-cleanup.timer --no-pager || true

echo "== 5. one-off cruft reclamation (idempotent) =="
/usr/local/sbin/mac-cruft-cleanup "$SMBG_GUEST_ROOT" || true

echo "== 6. Samba =="
if [ "$DO_SAMBA" -eq 1 ]; then
    if [ -f /etc/samba/smb.conf ]; then
        bak="/etc/samba/smb.conf.bak-$(date +%Y%m%d%H%M%S)"
        cp -a /etc/samba/smb.conf "$bak"
        echo "   existing configuration backed up: $bak"
    fi
    install -o root -g root -m 644 "$STAGE/smb.conf" /etc/samba/smb.conf
    testparm -s >/dev/null
    echo "   testparm OK"
    # A leftover veto makes every macOS Finder copy fail with -8062.
    # Do not check with `grep -i veto` — it would match fruit:veto_appledouble = no
    # because of the name, but that line is not a block; it lifts one, and it must
    # stay.
    if testparm -s 2>/dev/null | grep -qE '^[[:space:]]*veto files'; then
        echo "   !! veto files is still present — Finder copies will fail" >&2
        exit 1
    fi
    systemctl restart smbd
    echo "   smbd restarted"
else
    echo "   Not deployed. Merge the following into your existing /etc/samba/smb.conf"
    echo "   (or re-run with --samba — the existing file is backed up):"
    echo "   ---------------------------------------------------------------"
    sed 's/^/   /' "$STAGE/smb.conf"
    echo "   ---------------------------------------------------------------"
fi

cat <<DONE

Done. To check:
  systemctl list-timers mac-cruft-cleanup.timer     # NEXT must be populated
  journalctl -u mac-cruft-cleanup -n 20             # cleanup history (quiet when zero)
  sudo -n /usr/local/sbin/clockfix \$(date +%s)      # confirm NOPASSWD works
  testparm -s 2>/dev/null | grep -E '^\s*veto files'   # must be 0 lines

Clock: continuous correction while awake belongs to the NTP daemon. A reference
       chrony configuration is in guest/chrony/ and is not deployed automatically
       (it is system clock policy, and getting it wrong is costly).
       See the 'Guest clock' section of docs/install.md for details.
DONE

exit 0
