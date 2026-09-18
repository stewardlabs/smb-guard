#!/bin/bash
# host/uninstall.sh — host (macOS) side removal. The mirror of host/install.sh.
#
#   sudo ./host/uninstall.sh [--config <path>] [--purge-logs] [--dry-run]
#
# Why a script and not a list of rm commands: host/install.sh places thirteen
# files under five directories. Removing them by hand is exactly the failure this
# repo exists to avoid — one is missed, and the one that is missed is a
# LaunchDaemon that keeps firing against a mount that no longer exists.
#
# What it removes is precisely what host/install.sh deployed, nothing more:
#   the three LaunchDaemons (booted out first, then their plists)
#   /usr/local/sbin/{smb-guard,smb-guard-sleep,smb-guard-wakeup,smbfix,
#                    smb-guard-selfcheck,smb-guard-doctor}
#   /usr/local/lib/smb-guard/          /usr/local/etc/smb-guard.conf
#   /etc/newsyslog.d/<prefix>.smb.conf /var/run/smb-guard
#
# What it deliberately leaves, and only prints the commands for:
#   the autofs trio and /etc/auto_smb — they ARE the mount, install never wrote
#     them, and the map holds credentials; the same boundary as --restore
#   the log directory — it is evidence (Principle 3). --purge-logs removes it
#   sleepwatcher (Homebrew) — not ours; other tools may depend on it
#   DSDontWriteNetworkStores — a Mac-wide Finder setting, not ours
#
# Removing the guard does not remove the mount. autofs keeps working on its own;
# tearing the mount down is a separate decision and the printed block covers it.
#
# The configuration is read from the DEPLOYED copy first, then the repo — the
# reverse of install.sh. What has to be removed is what was deployed, and the
# label prefix and log directory in effect are the ones the deployed copy holds.
# Only when there is no deployed copy does the repo configuration stand in.
#
# Idempotent: a path that is already gone is reported and skipped, not an error.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: sudo ./host/uninstall.sh [--config <path>] [--purge-logs] [--dry-run]

  --config <path>   configuration file (default: the deployed
                    /usr/local/etc/smb-guard.conf, otherwise smb-guard.conf above this script)
  --purge-logs      also remove the log directory (kept by default — it is evidence)
  --dry-run         print the removal plan without removing anything
USAGE
    exit 2
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CONF=""
DRY=0
PURGE_LOGS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config)     [ $# -ge 2 ] || usage; CONF="$2"; shift 2 ;;
        --purge-logs) PURGE_LOGS=1; shift ;;
        --dry-run)    DRY=1; shift ;;
        -h|--help)    usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

DEST_CONF="/usr/local/etc/smb-guard.conf"
if [ -z "$CONF" ]; then
    if   [ -r "$DEST_CONF" ];           then CONF="$DEST_CONF"
    elif [ -r "$ROOT/smb-guard.conf" ]; then CONF="$ROOT/smb-guard.conf"
    else
        echo "No configuration file: neither $DEST_CONF nor $ROOT/smb-guard.conf." >&2
        echo "Nothing to remove, or pass --config to name what was deployed." >&2
        exit 78   # EX_CONFIG
    fi
fi
[ -r "$CONF" ] || { echo "configuration file not readable: $CONF" >&2; exit 78; }

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "run as sudo ./host/uninstall.sh (use --dry-run to only see the plan)" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_OWNER:?$CONF: SMBG_OWNER is not set}"
: "${SMBG_MP:?$CONF: SMBG_MP is not set}"
: "${SMBG_LABEL_PREFIX:=io.stewardlabs}"
: "${SMBG_LOGDIR:=/var/log/smb}"
: "${SMBG_AUTOFS_MAP:=auto_smb}"

GUARD_LABEL="$SMBG_LABEL_PREFIX.smb-guard"
WATCH_LABEL="$SMBG_LABEL_PREFIX.sleepwatcher"
SELF_LABEL="$SMBG_LABEL_PREFIX.selfcheck"
GUARD_PLIST="/Library/LaunchDaemons/$GUARD_LABEL.plist"
WATCH_PLIST="/Library/LaunchDaemons/$WATCH_LABEL.plist"
SELF_PLIST="/Library/LaunchDaemons/$SELF_LABEL.plist"
NEWSYSLOG="/etc/newsyslog.d/$SMBG_LABEL_PREFIX.smb.conf"
RUNDIR="/var/run/smb-guard"   # the runtime lock directory common.sh creates

SBIN_FILES="smb-guard smb-guard-sleep smb-guard-wakeup smbfix smb-guard-selfcheck smb-guard-doctor"

# ── Plan output ────────────────────────────────────────────────────────────
present() { [ -e "$1" ] && echo "present" || echo "absent"; }

cat <<PLAN
== removal plan ==
  configuration  $CONF  (read for the label prefix and log directory)

  LaunchDaemons  bootout, then remove:
                 $GUARD_PLIST   ($(present "$GUARD_PLIST"))
                 $WATCH_PLIST   ($(present "$WATCH_PLIST"))
                 $SELF_PLIST   ($(present "$SELF_PLIST"))
  executables    /usr/local/sbin/{$(echo $SBIN_FILES | tr ' ' ',')}
  library        /usr/local/lib/smb-guard/          ($(present /usr/local/lib/smb-guard))
  configuration  $DEST_CONF          ($(present "$DEST_CONF"))
  log rotation   $NEWSYSLOG   ($(present "$NEWSYSLOG"))
  runtime dir    $RUNDIR                     ($(present "$RUNDIR"))
  log directory  $SMBG_LOGDIR   $( [ "$PURGE_LOGS" -eq 1 ] && echo "REMOVED (--purge-logs)" || echo "kept — evidence; pass --purge-logs to remove" )

  left alone (printed at the end): the autofs trio, /etc/$SMBG_AUTOFS_MAP, the mount
  itself, Homebrew sleepwatcher, DSDontWriteNetworkStores
PLAN

if [ "$DRY" -eq 1 ]; then
    echo
    echo "(--dry-run — nothing was removed)"
    exit 0
fi

# A partial removal must be announced, for the same reason a partial install is:
# a LaunchDaemon left loaded without its script logs an error on every mount
# event, and nothing else says why.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "!! removal aborted (exit=$rc). The removal may be partial." >&2
    echo "   Current state:  sudo launchctl print system/'"$GUARD_LABEL"'" >&2
    echo "                   ls -l /usr/local/sbin/smb-guard*" >&2
fi' EXIT

rm_path() {   # rm_path <path> — report, then remove; absent is not an error
    if [ -e "$1" ] || [ -L "$1" ]; then
        rm -rf "$1"
        echo "   removed  $1"
    else
        echo "   absent   $1"
    fi
}

echo
echo "== 1. stop the jobs =="
# bootout before the files go: a job whose script has vanished stays loaded and
# fails loudly on every trigger.
for lbl in "$SELF_LABEL" "$WATCH_LABEL" "$GUARD_LABEL"; do
    if launchctl print "system/$lbl" >/dev/null 2>&1; then
        # A failed bootout aborts (set -e): removing the files under a job that is
        # still loaded is the partial state the header warns about.
        launchctl bootout "system/$lbl"
        echo "   booted out  $lbl"
    else
        echo "   not loaded  $lbl"
    fi
done

echo "== 2. plists =="
rm_path "$SELF_PLIST"
rm_path "$WATCH_PLIST"
rm_path "$GUARD_PLIST"

echo "== 3. executables =="
for f in $SBIN_FILES; do
    rm_path "/usr/local/sbin/$f"
done

echo "== 4. library and configuration =="
rm_path /usr/local/lib/smb-guard
rm_path "$DEST_CONF"

echo "== 5. log rotation and runtime directory =="
rm_path "$NEWSYSLOG"
rm_path "$RUNDIR"

echo "== 6. logs =="
if [ "$PURGE_LOGS" -eq 1 ]; then
    rm_path "$SMBG_LOGDIR"
else
    echo "   kept     $SMBG_LOGDIR  (remove by hand, or re-run with --purge-logs)"
fi

# ── Self-verification ──────────────────────────────────────────────────────
# After this script there is no doctor left to confirm the removal, so the
# script confirms it itself (Principle 9: check that something actually
# happened before reporting success). Any leftover fails the run.
echo "== 7. verification =="
left=0
for lbl in "$GUARD_LABEL" "$WATCH_LABEL" "$SELF_LABEL"; do
    if launchctl print "system/$lbl" >/dev/null 2>&1; then
        echo "   !! still loaded: $lbl"; left=$((left + 1))
    fi
done
for p in "$GUARD_PLIST" "$WATCH_PLIST" "$SELF_PLIST" \
         /usr/local/lib/smb-guard "$DEST_CONF" "$NEWSYSLOG" "$RUNDIR"; do
    [ -e "$p" ] && { echo "   !! still present: $p"; left=$((left + 1)); }
done
for f in $SBIN_FILES; do
    [ -e "/usr/local/sbin/$f" ] && { echo "   !! still present: /usr/local/sbin/$f"; left=$((left + 1)); }
done
if [ "$left" -ne 0 ]; then
    echo "   $left item(s) remain — see above" >&2
    exit 1
fi
echo "   nothing of the deployment remains"

cat <<DONE

Removed. What this script does not touch, and the commands if you want them gone:

  The mount (autofs). install.sh never wrote these; the map holds credentials.
  Only do this once nothing on this Mac needs $SMBG_MP any more:
    sudo umount "$SMBG_MP" 2>/dev/null || true
    sudo sed -i '' '/^\/-[[:space:]]*$SMBG_AUTOFS_MAP[[:space:]]/d' /etc/auto_master
    sudo rm /etc/$SMBG_AUTOFS_MAP
    sudo automount -vc
    # /etc/autofs.conf: AUTOMOUNT_TIMEOUT, AUTOMOUNTD_MNTOPTS, AUTOMOUNTD_NOSUID are
    # harmless without a map; reset them by hand if you want Apple's defaults back
    sudo rmdir "$SMBG_MP"

  Homebrew sleepwatcher — only if nothing else uses it:
    brew uninstall sleepwatcher

  Finder's .DS_Store suppression on network volumes, if it was set for this mount:
    sudo defaults delete /Library/Preferences/com.apple.desktopservices DSDontWriteNetworkStores
    defaults delete com.apple.desktopservices DSDontWriteNetworkStores

  The guest side: sudo ./guest/uninstall.sh on the guest, or ./uninstall.sh --guest from here.
DONE

exit 0
