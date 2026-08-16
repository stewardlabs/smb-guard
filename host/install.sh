#!/bin/bash
# host/install.sh — host (macOS) side deployment.  sudo ./host/install.sh [options]
#
# Permissions matter. Because this system's dominant failure mode is "wrong
# permissions are silently ignored", deployment goes through a script rather than
# by hand:
#   - A LaunchDaemon plist that is not root:wheel 644 is refused by launchd.
#   - A script in /usr/local/sbin writable by another user becomes a root privilege
#     escalation vulnerability.
#   - /etc/newsyslog.d/*.conf that is not root:wheel 644 is **silently** ignored by
#     newsyslog — the log grows without bound with no symptom at all.
#
# Idempotent. A re-run performs bootout -> redeploy -> bootstrap again.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: sudo ./host/install.sh [--config <path>] [--dry-run]

  --config <path>  configuration file (default: smb-guard.conf at the repo root,
                   otherwise the already-deployed /usr/local/etc/smb-guard.conf)
  --dry-run        print the plan without deploying. Does not require root.
USAGE
    exit 2
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CONF=""
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || usage; CONF="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

DEST_CONF="/usr/local/etc/smb-guard.conf"
if [ -z "$CONF" ]; then
    if   [ -r "$ROOT/smb-guard.conf" ]; then CONF="$ROOT/smb-guard.conf"
    elif [ -r "$DEST_CONF" ];           then CONF="$DEST_CONF"
    else
        echo "No configuration file. Copy smb-guard.conf.example and fill in the values:" >&2
        echo "  cp $ROOT/smb-guard.conf.example $ROOT/smb-guard.conf" >&2
        exit 78   # EX_CONFIG
    fi
fi
[ -r "$CONF" ] || { echo "configuration file not readable: $CONF" >&2; exit 78; }

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "run as sudo ./host/install.sh (use --dry-run to only see the plan)" >&2
    exit 1
fi

# ── Configuration load and validation ──────────────────────────────────────
# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_OWNER:?$CONF: SMBG_OWNER is not set}"
: "${SMBG_MP:?$CONF: SMBG_MP is not set}"
: "${SMBG_HOST:?$CONF: SMBG_HOST is not set}"
: "${SMBG_SHARE:?$CONF: SMBG_SHARE is not set}"
: "${SMBG_SHARE_SUBPATH:=}"
: "${SMBG_LABEL_PREFIX:=io.stewardlabs}"
: "${SMBG_LOGDIR:=/var/log/smb}"

# For the deployment plan output only. Runtime assembly is done by lib/common.sh —
# to avoid two definitions, this only displays it, and the scripts use common.sh's
# value.
SMBG_SHARE_PATH="$SMBG_SHARE${SMBG_SHARE_SUBPATH:+/$SMBG_SHARE_SUBPATH}"

id -u "$SMBG_OWNER" >/dev/null 2>&1 || {
    echo "account '$SMBG_OWNER' does not exist ($CONF)" >&2; exit 78; }

GUARD_LABEL="$SMBG_LABEL_PREFIX.smb-guard"
WATCH_LABEL="$SMBG_LABEL_PREFIX.sleepwatcher"
GUARD_PLIST="/Library/LaunchDaemons/$GUARD_LABEL.plist"
WATCH_PLIST="/Library/LaunchDaemons/$WATCH_LABEL.plist"
NEWSYSLOG="/etc/newsyslog.d/$SMBG_LABEL_PREFIX.smb.conf"

# ── sleepwatcher binary discovery ──────────────────────────────────────────
# Homebrew installs into sbin, and that path is often not on PATH. The prefix
# differs per architecture, so look at both locations directly and fall back to
# PATH as a last resort.
SW=""
for c in /opt/homebrew/sbin/sleepwatcher /usr/local/sbin/sleepwatcher; do
    [ -x "$c" ] && { SW="$c"; break; }
done
[ -n "$SW" ] || SW="$(command -v sleepwatcher 2>/dev/null || true)"
if [ -z "$SW" ]; then
    echo "!! sleepwatcher not found. Install it and run again:" >&2
    echo "     brew install sleepwatcher" >&2
    echo "   (Do not register it as a brew service — this script deploys its own" >&2
    echo "    LaunchDaemon. See docs/decisions.md for why.)" >&2
    exit 1
fi

# ── Rendering ──────────────────────────────────────────────────────────────
# Fill the templates' @PLACEHOLDER@ with configuration values. A '|' in a value
# would collide with the sed delimiter, so it is rejected up front — it is not a
# character that belongs in a path or a label.
case "$SMBG_LABEL_PREFIX$SMBG_LOGDIR$SW" in
    *"|"*) echo "configuration values may not contain the '|' character" >&2; exit 78 ;;
esac

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smb-guard-render.XXXXXX")"
cleanup_stage() { rm -rf "$STAGE"; }
trap cleanup_stage EXIT

render() {   # render <template> <output path>
    sed -e "s|@LABEL_PREFIX@|$SMBG_LABEL_PREFIX|g" \
        -e "s|@LOGDIR@|$SMBG_LOGDIR|g" \
        -e "s|@SLEEPWATCHER_BIN@|$SW|g" \
        "$1" > "$2"
}

render "$HERE/LaunchDaemons/smb-guard.plist.in"    "$STAGE/guard.plist"
render "$HERE/LaunchDaemons/sleepwatcher.plist.in" "$STAGE/watch.plist"
render "$HERE/newsyslog.d/smb.conf.in"             "$STAGE/newsyslog.conf"

# An unsubstituted placeholder left in the rendered output would be deployed as-is
# and malfunction silently.
if grep -l '@[A-Z_]\{3,\}@' "$STAGE"/* >/dev/null 2>&1; then
    echo "!! unsubstituted placeholders remain:" >&2
    grep -n '@[A-Z_]\{3,\}@' "$STAGE"/* >&2
    exit 1
fi

# ── Plan output ────────────────────────────────────────────────────────────
cat <<PLAN
== deployment plan ==
  configuration  $CONF
                 -> $DEST_CONF                                 (root:wheel 644)
  library        host/lib/common.sh
                 -> /usr/local/lib/smb-guard/common.sh          (root:wheel 644, no exec bit)
  executables    host/sbin/{smb-guard,smb-guard-sleep,smb-guard-wakeup,smbfix}
                 -> /usr/local/sbin/                            (root:wheel 755)
  LaunchDaemon
                 -> $GUARD_PLIST   (root:wheel 644)
                 -> $WATCH_PLIST   (root:wheel 644)
  log rotation   -> $NEWSYSLOG   (root:wheel 644)
  log directory  $SMBG_LOGDIR                                   (root:wheel 755)

  owner          $SMBG_OWNER (uid $(id -u "$SMBG_OWNER"))
  mount point    $SMBG_MP
  guest          $SMBG_HOST : $SMBG_SHARE_PATH
  sleepwatcher   $SW
PLAN

if [ "$DRY" -eq 1 ]; then
    echo
    echo "(--dry-run — nothing was deployed)"
    exit 0
fi

# So that an abort under set -e is not silent. A partial deployment must always be
# announced.
trap 'rc=$?; cleanup_stage; if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "!! installation aborted (exit=$rc). The deployment may be partial." >&2
    echo "   Current state:  sudo launchctl print system/'"$GUARD_LABEL"'" >&2
    echo "                   ls -l /usr/local/sbin/smb-guard*" >&2
fi' EXIT

echo
echo "== 1. stop existing jobs =="
launchctl bootout "system/$WATCH_LABEL" 2>/dev/null || true
launchctl bootout "system/$GUARD_LABEL" 2>/dev/null || true
# A leftover user-domain agent created by brew makes the hooks fire twice.
OWNER_UID="$(id -u "$SMBG_OWNER")"
launchctl bootout "gui/$OWNER_UID/homebrew.mxcl.sleepwatcher" 2>/dev/null || true
sudo -u "$SMBG_OWNER" -H brew services stop sleepwatcher 2>/dev/null || true

echo "== 2. directories =="
install -d -o root -g wheel -m 755 /usr/local/sbin
install -d -o root -g wheel -m 755 /usr/local/etc
install -d -o root -g wheel -m 755 /usr/local/lib/smb-guard
install -d -o root -g wheel -m 755 "$SMBG_LOGDIR"

echo "== 3. configuration =="
# A copy, not a symlink. What this system recovers is the workspace mount, so a
# configuration pointing inside that mount would vanish along with it the moment
# the mount goes away.
if [ "$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")" != "$DEST_CONF" ]; then
    install -o root -g wheel -m 644 "$CONF" "$DEST_CONF"
    echo "   $DEST_CONF"
else
    echo "   $DEST_CONF (using the already-deployed file — unchanged)"
fi

echo "== 4. library (no exec bit — source only) =="
install -o root -g wheel -m 644 "$HERE/lib/common.sh" /usr/local/lib/smb-guard/common.sh

echo "== 5. executables =="
for f in smb-guard smb-guard-sleep smb-guard-wakeup smbfix; do
    install -o root -g wheel -m 755 "$HERE/sbin/$f" "/usr/local/sbin/$f"
    echo "   /usr/local/sbin/$f"
done

echo "== 6. plists =="
install -o root -g wheel -m 644 "$STAGE/guard.plist" "$GUARD_PLIST"
install -o root -g wheel -m 644 "$STAGE/watch.plist" "$WATCH_PLIST"
plutil -lint "$GUARD_PLIST"
plutil -lint "$WATCH_PLIST"

echo "== 7. log rotation =="
install -o root -g wheel -m 644 "$STAGE/newsyslog.conf" "$NEWSYSLOG"

echo "== 8. syntax check =="
for f in /usr/local/sbin/smb-guard /usr/local/sbin/smb-guard-sleep \
         /usr/local/sbin/smb-guard-wakeup /usr/local/sbin/smbfix; do
    bash -n "$f" && echo "   $f OK"
done

echo "== 9. registration =="
launchctl bootstrap system "$GUARD_PLIST"
launchctl bootstrap system "$WATCH_PLIST"

cat <<DONE

Done. To check:
  launchctl print system/$GUARD_LABEL | head -20
  launchctl print system/$WATCH_LABEL | head -20
  smb-guard --state
  sudo newsyslog -nv | grep $SMBG_LOGDIR

Top-priority check — whether guest ssh works from a root context (if this is dead,
all clock correction dies with it):
  sudo -u $SMBG_OWNER -H ssh -o BatchMode=yes -o ConnectTimeout=3 $SMBG_HOST 'date +%s'
DONE

exit 0
