#!/bin/bash
# cleanup.sh — removes the old v13 deployment. Run it **after install.sh and at
# least one verified sleep/wake cycle**.
#
# Why it is separate from install.sh:
#   While the old hooks (~/.sleep, ~/.wakeup) are still there, rollback is
#   possible. Deleting them before verification removes the means of going back.
#   Conversely, leaving them after verification is dangerous — if the brew service
#   comes back (via `brew upgrade sleepwatcher` or similar), the old and new hooks
#   run at the same time and intervene twice.
#
# Dry-run by default. Actual deletion:  sudo ./cleanup.sh --apply
set -eu

[ "$(id -u)" -eq 0 ] || { echo "run as sudo ./cleanup.sh [--apply]" >&2; exit 1; }

APPLY=0
PURGE_SUDOERS=0
for a in "$@"; do
    case "$a" in
        --apply)          APPLY=1 ;;
        --purge-sudoers)  PURGE_SUDOERS=1 ;;
        *) echo "usage: sudo ./cleanup.sh [--apply] [--purge-sudoers]" >&2; exit 2 ;;
    esac
done
[ "$APPLY" -eq 0 ] && echo "*** DRY-RUN — pass --apply to actually delete ***" && echo

OWNER="sanha"
HOME_DIR="$(dscl . -read "/Users/$OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
: "${HOME_DIR:=/Users/$OWNER}"

BACKUP="/var/backups/smb-guard-v13-$(date +%Y%m%d%H%M%S)"

# So that an abort under set -e is not silent. Partial execution of a cleanup must
# always be announced.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "!! aborted by an unexpected error (exit=$rc)." >&2
    echo "   Some things may have been deleted. Check the backup: $BACKUP" >&2
    echo "   Check sudoers state:  sudo visudo -c" >&2
fi' EXIT

act() {   # act <path> <description>
    [ -e "$1" ] || return 0
    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$BACKUP"
        cp -a "$1" "$BACKUP/" 2>/dev/null || true
        rm -rf "$1"
        echo "  deleted (backed up): $1   — $2"
    else
        echo "  [would delete] $1   — $2"
    fi
}

echo "== 1. leftovers of the brew sleepwatcher service =="
OWNER_UID="$(id -u "$OWNER" 2>/dev/null || echo 501)"
if [ "$APPLY" -eq 1 ]; then
    launchctl bootout "gui/$OWNER_UID/homebrew.mxcl.sleepwatcher" 2>/dev/null || true
    sudo -u "$OWNER" -H brew services stop sleepwatcher 2>/dev/null || true
fi
act "$HOME_DIR/Library/LaunchAgents/homebrew.mxcl.sleepwatcher.plist" "agent created by brew"

echo "== 2. old hooks (risk of double execution — must be removed) =="
act "$HOME_DIR/.sleep"   "-> /usr/local/sbin/smb-guard-sleep"
act "$HOME_DIR/.wakeup"  "-> /usr/local/sbin/smb-guard-wakeup"
act "$HOME_DIR/bin/smbfix" "-> /usr/local/sbin/smbfix"

echo "== 3. old state and log files =="
act "$HOME_DIR/.sleepwatcher.log"         "-> /var/log/smb/smb-guard.log"
act "$HOME_DIR/.sleepwatcher.last_sleep"  "-> /var/run/smb-guard/last_sleep"
act "$HOME_DIR/.sleepwatcher.sleep_state" "abolished in v14 (state is one log line)"
act "/var/log/smb-guard.log"              "-> /var/log/smb/smb-guard.log"
act "/var/log/smb-guard.launchd.log"      "-> /var/log/smb/smb-guard.launchd.log"

echo "== 4. sudoers =="
# Show what is being reclaimed before deleting. A NOPASSWD rule is a standing
# grant of privilege, so seeing "what disappears" before removing it is right.
show_rule() {
    [ -r "$1" ] || return 0
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1" | sed 's/^/       /'
}

# Permission audit of the sudoers.d files. **It never remediates automatically.**
# "Fixing" a file to 0440 that sudo has been ignoring because of wrong permissions
# is in fact newly opening a NOPASSWD privilege that was never granted. A cleanup
# must not become a privilege escalation.
audit_mode() {
    [ -e "$1" ] || return 0
    # Caution with set -e: an assignment whose command substitution fails exits the
    # shell "silently". A cleanup script that dies without a word leaves a
    # partially deleted state, so guard it with || true.
    local m; m="$(stat -f %Lp "$1" 2>/dev/null || true)"
    # stat's -f is a format specifier on macOS (BSD) but means filesystem info on
    # GNU. If the result is not in octal-permission form, make no judgement — a
    # wrong warning is worse than silence.
    case "$m" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
        *) echo "  ?? could not read permissions: $1 (check by hand: ls -l '$1')"; return 0 ;;
    esac
    [ "$m" = "440" ] && return 0
    echo "  !! wrong permissions: $1 = 0$m (sudoers expects 0440)"
    echo "     Whether this file's rules have actually been in effect is unclear. Check:"
    echo "       sudo -l -U $OWNER"
    echo "     Not remediated automatically — if it was ineffective, fixing it is a privilege escalation."
    echo "     To keep it, do it yourself:  sudo chown root:wheel '$1' && sudo chmod 0440 '$1'"
}

audit_mode /etc/sudoers.d/smb-guard
audit_mode /etc/sudoers.d/smb-remount

# (a) smb-guard — unnecessary since v14, where the hooks run as root.
#     The old ~/.wakeup and ~/bin/smbfix that referenced it are removed in §2.
if [ -e /etc/sudoers.d/smb-guard ]; then
    echo "  current rules:"; show_rule /etc/sudoers.d/smb-guard
fi
act "/etc/sudoers.d/smb-guard" "unnecessary since v14 (the hooks run as root)"

# (b) smb-remount — NOPASSWD for umount -f / automount -vc / diskutil unmount force.
#     No v14 script uses it (smbfix self-elevates, guard runs as root).
#     Removing an unused NOPASSWD is the rule, but a shell alias or manual
#     procedure outside the inventory may depend on it, so it is kept by default.
#     Remove it with --purge-sudoers once you are sure.
if [ -e /etc/sudoers.d/smb-remount ]; then
    echo "  current rules:"; show_rule /etc/sudoers.d/smb-remount
fi
if [ "$PURGE_SUDOERS" -eq 1 ]; then
    act "/etc/sudoers.d/smb-remount" "--purge-sudoers given — unused by any v14 script"
else
    echo "  [kept] /etc/sudoers.d/smb-remount"
    echo "         Unused by any v14 script. Add --purge-sudoers to remove it."
    echo "         Removing it is safe: smbfix works via its own sudo elevation (one password prompt)."
fi
echo "== 5. sudoers integrity check =="
# Removing files cannot break the syntax, but if it was already broken for another
# reason it is better caught here — a damaged sudoers makes sudo itself unusable.
if visudo -c >/dev/null 2>&1; then
    echo "  visudo -c OK"
else
    echo "  !! sudoers syntax error detected. Check immediately:  sudo visudo -c"
    visudo -c || true
fi

echo
if [ "$APPLY" -eq 1 ]; then
    echo "Done. Backup: $BACKUP"
    echo "To roll back, restore the originals from that directory."
    if [ "$PURGE_SUDOERS" -eq 0 ]; then
        echo "Note: /etc/sudoers.d/smb-remount was kept (removable with --purge-sudoers)."
    fi
else
    echo "To actually delete:  sudo ./cleanup.sh --apply"
    echo "Including sudoers:   sudo ./cleanup.sh --apply --purge-sudoers"
fi

# If the last statement were an AND list, its return value would become the script's
# exit code and cause the EXIT trap to false-positive (actually happened on 08-08:
# exit=1 on a normal completion when --purge-sudoers was given). Return 0 explicitly.
exit 0
