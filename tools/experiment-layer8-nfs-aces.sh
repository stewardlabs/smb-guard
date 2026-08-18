#!/bin/bash
# experiment-layer8-nfs-aces.sh — guest-side switch for the Layer 8 blocking
# experiment. Run ON THE GUEST, as root. Not a deployment target.
#
# Background: fruit:nfs_aces is a GLOBAL-ONLY option — set per share it silently
#       takes no effect (vfs_fruit(8) GLOBAL OPTIONS; the module reads it with
#       lp_parm_bool(-1, ...), which consults [global] only). That is why the
#       Layer 8 capture saw client chmods land "with the option set": the guard
#       in check_ms_nfs() exists but never armed. Details in
#       docs/failure-model.md Layer 8 and docs/open-questions.md.
#
# What this tool does:
#   --apply    back up smb.conf, comment out any active per-share
#              fruit:nfs_aces line, insert `fruit:nfs_aces = no` into [global],
#              validate with testparm, restart smbd
#   --revert   restore the backup taken by --apply, restart smbd
#
# The edit is validated on a copy first; smb.conf is only replaced after
# testparm accepts it. The backup is the revert path — do not edit smb.conf
# between --apply and --revert, the revert is a whole-file restore.
#
# After --apply, the Mac MUST tear down its SMB session completely (unmount
# every share from this server) before measuring: the AAPL capabilities that
# carry the NFS ACE channel are negotiated once per session, not per mount.

set -u

CONF=/etc/samba/smb.conf
BACKUP=/etc/samba/smb.conf.layer8-nfs-aces.bak

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ -f "$CONF" ] || die "$CONF not found"

restart_and_show() {
    systemctl restart smbd || die "smbd restart failed — inspect $CONF"
    echo "-- effective value (testparm) --"
    testparm -s 2>/dev/null | grep -i 'nfs_aces' || echo "(not shown: option at default)"
}

case "${1:-}" in
--apply)
    [ -f "$BACKUP" ] && die "backup already exists — experiment already applied? ($BACKUP)"
    TMP=$(mktemp) || die "mktemp failed"
    cp -p "$CONF" "$BACKUP" || die "backup failed"
    # Comment out active fruit:nfs_aces lines (wherever they are), then arm the
    # option where it actually lives. Already-commented lines do not match, and
    # section headers may be indented (the deployed file indents them).
    sed -E 's|^([[:space:]]*)(fruit:nfs_aces[[:space:]]*=.*)$|\1# \2|' "$CONF" \
        | sed -E '/^[[:space:]]*\[global\][[:space:]]*$/a\   fruit:nfs_aces = no' > "$TMP" \
        || die "edit failed"
    grep -qE '^[[:space:]]*fruit:nfs_aces = no$' "$TMP" || die "insertion not found — is there a [global] section?"
    testparm -s "$TMP" >/dev/null 2>&1 || die "testparm rejected the edited file — $CONF untouched"
    cp "$TMP" "$CONF" || die "install failed — restore from $BACKUP"
    rm -f "$TMP"
    restart_and_show
    echo "APPLIED. Before measuring: unmount every share of this server on the Mac,"
    echo "then remount — AAPL caps are negotiated once per session."
    ;;
--revert)
    [ -f "$BACKUP" ] || die "no backup found ($BACKUP) — nothing to revert"
    cp "$BACKUP" "$CONF" || die "restore failed"
    rm -f "$BACKUP"
    restart_and_show
    echo "REVERTED. Re-establish the Mac session here too before trusting measurements."
    ;;
*)
    echo "usage: sudo $0 --apply | --revert" >&2
    exit 2
    ;;
esac
