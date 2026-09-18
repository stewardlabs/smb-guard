#!/bin/bash
# guest/uninstall.sh — guest (Linux, Samba server) side removal. The mirror of
# guest/install.sh.
#
#   directly on the guest:  sudo ./guest/uninstall.sh [options]
#   remotely from the host: ./uninstall.sh --guest   (the top-level orchestrator transfers and runs it)
#
# What it removes is what guest/install.sh deployed:
#   /etc/systemd/system/mac-cruft-cleanup.{service,timer}   (timer stopped and disabled first)
#   /usr/local/sbin/clockfix   /usr/local/sbin/mac-cruft-cleanup
#   /etc/sudoers.d/clockfix
#   /etc/smb-guard.conf
#
# What it leaves, and only prints the commands for:
#   /etc/samba/smb.conf — install.sh backs the previous file up as .bak-<timestamp>
#     before replacing it (--samba). Restoring it removes the share, and removing
#     the share while the Mac still mounts it is a sequencing decision for a
#     human; the latest backup is named in the printed block
#   the fstab bind mount of the share root — install.sh only advises it
#   chrony's makestep.conf — never deployed automatically (docs/install.md
#     'Guest clock')
#
# Idempotent: a path that is already gone is reported and skipped.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: sudo ./guest/uninstall.sh [--config <path>] [--dry-run]

  --config <path>   configuration file (default: the deployed /etc/smb-guard.conf,
                    otherwise smb-guard.conf above this script)
  --dry-run         print the removal plan without removing anything
USAGE
    exit 2
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CONF=""; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config)  [ $# -ge 2 ] || usage; CONF="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

# Deployed copy first — what has to be removed is what was deployed (the reverse
# of install.sh's preference for the repo copy).
DEST_CONF="/etc/smb-guard.conf"
if [ -z "$CONF" ]; then
    if   [ -r "$DEST_CONF" ];           then CONF="$DEST_CONF"
    elif [ -r "$ROOT/smb-guard.conf" ]; then CONF="$ROOT/smb-guard.conf"
    else
        echo "No configuration file: neither $DEST_CONF nor $ROOT/smb-guard.conf." >&2
        echo "Nothing to remove, or pass --config to name what was deployed." >&2
        exit 78
    fi
fi
[ -r "$CONF" ] || { echo "configuration file not readable: $CONF" >&2; exit 78; }

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "run as sudo ./guest/uninstall.sh (use --dry-run to only see the plan)" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_SHARE:=}"

UNIT_SERVICE=/etc/systemd/system/mac-cruft-cleanup.service
UNIT_TIMER=/etc/systemd/system/mac-cruft-cleanup.timer
SUDOERS=/etc/sudoers.d/clockfix
SBIN_FILES="clockfix mac-cruft-cleanup"

present() { [ -e "$1" ] && echo "present" || echo "absent"; }

# The most recent smb.conf backup install.sh made, if any — named in the advice
# block so the operator does not have to hunt for it.
SMB_BAK="$(ls -1t /etc/samba/smb.conf.bak-* 2>/dev/null | head -1 || true)"

cat <<PLAN
== removal plan (guest) ==
  configuration  $CONF  (read for the share name)

  systemd        stop + disable mac-cruft-cleanup.timer, then remove:
                 $UNIT_SERVICE   ($(present "$UNIT_SERVICE"))
                 $UNIT_TIMER     ($(present "$UNIT_TIMER"))
  executables    /usr/local/sbin/{$(echo $SBIN_FILES | tr ' ' ',')}
  sudoers        $SUDOERS   ($(present "$SUDOERS"))
  configuration  $DEST_CONF   ($(present "$DEST_CONF"))

  left alone (printed at the end): /etc/samba/smb.conf$( [ -n "$SMB_BAK" ] && echo " (backup: $SMB_BAK)" ),
  the share-root bind mount in fstab, chrony
PLAN

if [ "$DRY" -eq 1 ]; then
    echo; echo "(--dry-run — nothing was removed)"
    exit 0
fi

trap 'rc=$?; if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "!! removal aborted (exit=$rc). The removal may be partial." >&2
    echo "   Check:  systemctl status mac-cruft-cleanup.timer; ls -l /usr/local/sbin/clockfix /etc/sudoers.d/clockfix" >&2
fi' EXIT

rm_path() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        rm -rf "$1"
        echo "   removed  $1"
    else
        echo "   absent   $1"
    fi
}

echo
echo "== 1. timer =="
if systemctl list-unit-files mac-cruft-cleanup.timer --no-legend 2>/dev/null | grep -q .; then
    systemctl disable --now mac-cruft-cleanup.timer
    echo "   stopped and disabled  mac-cruft-cleanup.timer"
else
    echo "   not registered        mac-cruft-cleanup.timer"
fi

echo "== 2. systemd units =="
rm_path "$UNIT_TIMER"
rm_path "$UNIT_SERVICE"
systemctl daemon-reload

echo "== 3. executables =="
for f in $SBIN_FILES; do
    rm_path "/usr/local/sbin/$f"
done

echo "== 4. sudoers =="
rm_path "$SUDOERS"

echo "== 5. configuration =="
rm_path "$DEST_CONF"

echo "== 6. verification =="
left=0
if systemctl list-unit-files mac-cruft-cleanup.timer --no-legend 2>/dev/null | grep -q .; then
    echo "   !! still registered: mac-cruft-cleanup.timer"; left=$((left + 1))
fi
for p in "$UNIT_SERVICE" "$UNIT_TIMER" "$SUDOERS" "$DEST_CONF"; do
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

Removed. Left for a human, with the commands:

  Samba. Restoring the pre-install file removes the [${SMBG_SHARE:-share}] share — do it only
  once the Mac no longer mounts it (host side first: host/uninstall.sh, then the
  autofs teardown it prints):
$( if [ -n "$SMB_BAK" ]; then
     echo "    sudo cp -a $SMB_BAK /etc/samba/smb.conf && sudo testparm -s >/dev/null && sudo systemctl restart smbd"
   else
     echo "    (no smb.conf.bak-* backup found — the share was merged by hand; remove the [${SMBG_SHARE:-share}] section by hand)"
   fi )

  The share-root bind mount, if you added one (docs/failure-model.md Layer 6):
    remove its line from /etc/fstab, then: sudo umount <share root>/<workspace>

  chrony's makestep.conf, if you installed it (docs/install.md 'Guest clock'):
    sudo rm /etc/chrony/conf.d/makestep.conf && sudo systemctl restart chrony
DONE

exit 0
