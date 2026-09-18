#!/bin/bash
# uninstall.sh — host/guest removal orchestrator. The mirror of install.sh.
#
# **Run it as a normal user (do not prefix it with sudo)** — the same reason as
# install.sh: privilege elevation happens per stage (sudo on the host, `ssh -t …
# sudo` on the guest), and a root shell would look at root's ~/.ssh for the guest
# alias.
#
#   ./uninstall.sh              host -> guest
#   ./uninstall.sh --host       host only
#   ./uninstall.sh --guest      guest only
#   ./uninstall.sh --dry-run    print both plans without removing
#
# The host goes first, the reverse of the deployment order is deliberate: the
# host side removes the guard, the wake hook and the self-check — everything that
# would otherwise fire against a guest that no longer has clockfix. The guest
# side then removes what the host was calling.
#
# Neither side removes the mount or the share. Those are printed as commands at
# the end of each side's run; sequencing them (unmount on the Mac before the
# share disappears on the guest) is a human decision.
#
# The guest transfer block is the same tar pipe as install.sh's — the two are kept
# in step by hand. It is transport, not policy; see the comments there for the
# bsdtar flags.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: ./uninstall.sh [--host|--guest] [--config <path>] [--purge-logs] [--dry-run]

  (no options)      remove from the host, then from the guest
  --host            host (macOS) only
  --guest           guest (Linux) only — transferred and run over ssh
  --config <path>   configuration file (default: smb-guard.conf in this directory)
  --purge-logs      host: also remove the log directory
  --dry-run         print the plans without removing anything
USAGE
    exit 2
}

ROOT="$(cd "$(dirname "$0")" && pwd)"

DO_HOST=1; DO_GUEST=1; CONF=""; DRY=0; PURGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host)       DO_GUEST=0; shift ;;
        --guest)      DO_HOST=0;  shift ;;
        --config)     [ $# -ge 2 ] || usage; CONF="$2"; shift 2 ;;
        --purge-logs) PURGE="--purge-logs"; shift ;;
        --dry-run)    DRY=1; shift ;;
        -h|--help)    usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "!! Run this script as a normal user (without sudo)." >&2
    echo "   As root, guest ssh would look at root's ~/.ssh and fail." >&2
    exit 1
fi

# The host and guest scripts each fall back to their deployed configuration when
# this file is absent, so a missing repo configuration is not fatal here — only
# the guest alias is needed by this orchestrator, and it can come from the
# deployed host copy.
[ -n "$CONF" ] || CONF="$ROOT/smb-guard.conf"
[ -r "$CONF" ] || CONF="/usr/local/etc/smb-guard.conf"
if [ ! -r "$CONF" ]; then
    echo "!! No configuration file (repo smb-guard.conf or deployed /usr/local/etc/smb-guard.conf)." >&2
    echo "   Pass --config, or run the host and guest scripts directly." >&2
    exit 78
fi

# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_HOST:?$CONF: SMBG_HOST is not set}"

DRYOPT=""
[ "$DRY" -eq 1 ] && DRYOPT="--dry-run"

# ── Host ───────────────────────────────────────────────────────────────────
if [ "$DO_HOST" -eq 1 ]; then
    echo "########## host (macOS) ##########"
    if [ "$DRY" -eq 1 ]; then
        "$ROOT/host/uninstall.sh" --config "$CONF" $PURGE --dry-run
    else
        sudo "$ROOT/host/uninstall.sh" --config "$CONF" $PURGE
    fi
    echo
fi

# ── Guest ──────────────────────────────────────────────────────────────────
if [ "$DO_GUEST" -eq 1 ]; then
    echo "########## guest ($SMBG_HOST) ##########"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" true 2>/dev/null; then
        echo "!! cannot connect to ssh $SMBG_HOST." >&2
        echo "   Check the alias in ~/.ssh/config and the state of the guest." >&2
        echo "   (Use --host to remove from the host only.)" >&2
        exit 1
    fi

    if [ "$DRY" -eq 0 ] && [ ! -t 0 ]; then
        echo "!! Guest removal needs a terminal (for the remote sudo password)." >&2
        echo "   Run it from a terminal, or log into the guest and run:" >&2
        echo "     sudo ./guest/uninstall.sh" >&2
        exit 1
    fi

    STAGE="/tmp/smb-guard-uninstall.$$"
    echo "-- transfer: $STAGE"
    ssh "$SMBG_HOST" "mkdir -p '$STAGE'"
    COPYFILE_DISABLE=1 tar --no-xattrs --no-fflags -C "$ROOT" -cf - guest \
        | ssh "$SMBG_HOST" "tar -C '$STAGE' -xf -"
    # shellcheck disable=SC2002
    cat "$CONF" | ssh "$SMBG_HOST" "cat > '$STAGE/smb-guard.conf'"

    set +e
    if [ "$DRY" -eq 1 ]; then
        ssh "$SMBG_HOST" \
            "'$STAGE/guest/uninstall.sh' --config '$STAGE/smb-guard.conf' --dry-run; \
             rc=\$?; rm -rf '$STAGE'; exit \$rc"
    else
        echo "-- running (the guest may ask for a sudo password)"
        ssh -t "$SMBG_HOST" \
            "sudo '$STAGE/guest/uninstall.sh' --config '$STAGE/smb-guard.conf'; \
             rc=\$?; rm -rf '$STAGE'; exit \$rc"
    fi
    grc=$?
    set -e
    if [ "$grc" -ne 0 ]; then
        echo "!! guest removal failed (exit=$grc)." >&2
        [ "$DO_HOST" -eq 1 ] && echo "   The host removal has already completed." >&2
        exit "$grc"
    fi
fi

echo
if [ "$DRY" -eq 1 ]; then
    echo "(--dry-run — nothing was removed)"
else
    echo "Removal complete. The mount and the share are still in place — see the printed blocks above."
fi
exit 0
