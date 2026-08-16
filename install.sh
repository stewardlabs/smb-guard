#!/bin/bash
# install.sh — host/guest deployment orchestrator.  ./install.sh [options]
#
# **Run it as a normal user (do not prefix it with sudo).** Privilege elevation
# happens separately at each stage: sudo on the host, `ssh -t … sudo` on the guest.
# Running this whole script as root makes ssh look at root's ~/.ssh, so the guest
# alias and key do not resolve. For the same reason the wake hook switches
# credentials back with `sudo -u <owner> -H ssh` from its root context.
#
#   ./install.sh              check the configuration -> host -> guest
#   ./install.sh --host       host only
#   ./install.sh --guest      guest only
#   ./install.sh --dry-run    print both plans without deploying
#
# Guest deployment touches Samba and systemd, so on failure it stops right there
# and reports that the application was partial. The host goes first because it is
# easier to undo.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: ./install.sh [--host|--guest] [--config <path>] [--samba] [--dry-run]

  (no options)      deploy host, then guest
  --host            host (macOS) only
  --guest           guest (Linux) only — transferred and run over ssh
  --config <path>   configuration file (default: smb-guard.conf in this directory)
  --samba           also deploy the guest's /etc/samba/smb.conf (default: print only)
  --dry-run         print the plan without deploying
USAGE
    exit 2
}

ROOT="$(cd "$(dirname "$0")" && pwd)"

DO_HOST=1; DO_GUEST=1; CONF=""; DRY=0; SAMBA=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host)    DO_GUEST=0; shift ;;
        --guest)   DO_HOST=0;  shift ;;
        --config)  [ $# -ge 2 ] || usage; CONF="$2"; shift 2 ;;
        --samba)   SAMBA="--samba"; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "!! Run this script as a normal user (without sudo)." >&2
    echo "   As root, guest ssh would look at root's ~/.ssh and fail." >&2
    exit 1
fi

[ -n "$CONF" ] || CONF="$ROOT/smb-guard.conf"
if [ ! -r "$CONF" ]; then
    cat >&2 <<EOF
configuration file not found: $CONF

  cp $ROOT/smb-guard.conf.example $ROOT/smb-guard.conf
  \$EDITOR $ROOT/smb-guard.conf

Four values must be filled in: the account, the mount point, the guest alias and
the share name.
EOF
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
        "$ROOT/host/install.sh" --config "$CONF" --dry-run
    else
        sudo "$ROOT/host/install.sh" --config "$CONF"
    fi
    echo
fi

# ── Guest ──────────────────────────────────────────────────────────────────
if [ "$DO_GUEST" -eq 1 ]; then
    echo "########## guest ($SMBG_HOST) ##########"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" true 2>/dev/null; then
        echo "!! cannot connect to ssh $SMBG_HOST." >&2
        echo "   Check the alias in ~/.ssh/config and the state of the guest." >&2
        echo "   (Use --host to deploy the host only.)" >&2
        exit 1
    fi

    # A real deployment needs remote sudo, and sudo requires a TTY to prompt for a
    # password. Without this early check it would only fail after transferring
    # every file.
    if [ "$DRY" -eq 0 ] && [ ! -t 0 ]; then
        echo "!! Guest deployment needs a terminal (for the remote sudo password)." >&2
        echo "   Run it from a terminal, or log into the guest and run:" >&2
        echo "     sudo ./guest/install.sh --config <configuration file>" >&2
        exit 1
    fi

    # Transfer and execution are separated: `ssh -t` grabs stdin as a TTY and
    # cannot coexist with the tar stream. Transfer first without a TTY, then
    # allocate one to receive the sudo prompt.
    STAGE="/tmp/smb-guard-install.$$"
    echo "-- transfer: $STAGE"
    ssh "$SMBG_HOST" "mkdir -p '$STAGE'"
    # Send without macOS extended attributes (provenance/quarantine) or BSD file
    # flags. Either one makes the guest's GNU tar emit a warning per entry, burying
    # the real errors.
    #
    # **--no-xattrs alone is not enough.** File flags come from chflags, not from
    # extended attributes, so they survive it and still produce one
    # "Ignoring unknown extended header keyword 'SCHILY.fflags'" per entry — which
    # is exactly what this pair of options exists to prevent.
    # COPYFILE_DISABLE stops ._* files from being bundled along.
    #
    # Both options are bsdtar (libarchive); GNU tar has neither. That is fine here
    # because this side always runs on the macOS host, but it is the thing to fix
    # first if this orchestrator is ever ported to a Linux host.
    COPYFILE_DISABLE=1 tar --no-xattrs --no-fflags -C "$ROOT" -cf - guest \
        | ssh "$SMBG_HOST" "tar -C '$STAGE' -xf -"
    # shellcheck disable=SC2002
    cat "$CONF" | ssh "$SMBG_HOST" "cat > '$STAGE/smb-guard.conf'"

    # The staging directory is removed regardless of success or failure, and the
    # remote exit code is passed through unchanged.
    set +e
    if [ "$DRY" -eq 1 ]; then
        # Printing the plan needs no root -> no sudo and no TTY.
        ssh "$SMBG_HOST" \
            "'$STAGE/guest/install.sh' --config '$STAGE/smb-guard.conf' $SAMBA --dry-run; \
             rc=\$?; rm -rf '$STAGE'; exit \$rc"
    else
        echo "-- running (the guest may ask for a sudo password)"
        # -t allocates a TTY so the remote sudo password prompt appears on this terminal.
        ssh -t "$SMBG_HOST" \
            "sudo '$STAGE/guest/install.sh' --config '$STAGE/smb-guard.conf' $SAMBA; \
             rc=\$?; rm -rf '$STAGE'; exit \$rc"
    fi
    grc=$?
    set -e
    if [ "$grc" -ne 0 ]; then
        echo "!! guest deployment failed (exit=$grc)." >&2
        [ "$DO_HOST" -eq 1 ] && echo "   The host deployment has already completed." >&2
        exit "$grc"
    fi
fi

echo
if [ "$DRY" -eq 1 ]; then
    echo "(--dry-run — nothing was deployed)"
else
    echo "Deployment complete. Follow the verification procedure in docs/install.md."
fi
exit 0
