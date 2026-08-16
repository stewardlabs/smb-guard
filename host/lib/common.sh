#!/bin/bash
# /usr/local/lib/smb-guard/common.sh
# Shared base for the smb-guard family — source only. Not an executable.
#
# Members:
#   /usr/local/sbin/smb-guard          mount event hook (StartOnMount) + the only remediation engine
#   /usr/local/sbin/smb-guard-sleep    sleepwatcher -s  (records only)
#   /usr/local/sbin/smb-guard-wakeup   sleepwatcher -w
#   /usr/local/sbin/smbfix             manual recovery (interactive)
#
# Boundary principle — this file holds "read-only" material only:
#   constants, logging, state determination, credential-switch wrappers.
#   Code that actually changes the mount (force_umount / trigger / retry) lives
#   only inside smb-guard. Keeping remediation in a single agent is the core
#   invariant of this system, and sharing determination logic does not break
#   that invariant — it prevents the determination criteria from diverging.
#
# Target shell: bash 3.2 (the stock macOS /bin/bash). No zsh-only syntax.

# ── Configuration load ─────────────────────────────────────────────────────
# Environment-specific values (account, mount point, host alias, share name)
# come from the configuration file, not from here. Separating code from
# environment is what lets local values survive an update of the distribution.
#
# **The configuration file is never deployed as a symlink — that is a circular
# dependency.** What this system recovers is the workspace mount itself, so
# linking the configuration to a canonical copy inside that mount would make the
# means of recovery vanish at the exact moment the mount goes away. Always a
# real file.
SMBG_CONF="${SMBG_CONF:-/usr/local/etc/smb-guard.conf}"
if [ -r "$SMBG_CONF" ]; then
  . "$SMBG_CONF"
fi

# The log path is settled **before** the required values are validated, because
# where to record a validation failure depends on the log settings themselves.
: "${SMBG_LOGDIR:=/var/log/smb}"
SMBG_LOG="$SMBG_LOGDIR/smb-guard.log"       # unified event log for all 4 scripts

# ── Required configuration ─────────────────────────────────────────────────
# Missing values die here. Falling through to defaults would mean "touching
# someone else's mount under someone else's account", so explicit failure beats
# silent success (Principle 9).
: "${SMBG_OWNER:?smb-guard: SMBG_OWNER is not set — check $SMBG_CONF}"
: "${SMBG_MP:?smb-guard: SMBG_MP is not set — check $SMBG_CONF}"
: "${SMBG_HOST:?smb-guard: SMBG_HOST is not set — check $SMBG_CONF}"
: "${SMBG_SHARE:?smb-guard: SMBG_SHARE is not set — check $SMBG_CONF}"

# ── Optional configuration (defaults) ──────────────────────────────────────
# launchd Label prefix. The plist filename and the Label must agree, so
# install.sh generates both together. Here it is used to look the jobs up.
: "${SMBG_LABEL_PREFIX:=io.stewardlabs}"

# Upper bound for the trigger ls. It presupposes the map's soft option — with
# it, a missing server still fails within finite time. On a hard mount this
# value is meaningless, so check the map first.
: "${SMBG_TRIGGER_TIMEOUT:=15}"

# Spurious-wake gate. Anything that slept for less than this is treated as a
# sleep-transition darkwake and wake handling is skipped entirely.
: "${SMBG_SLEEP_GATE:=30}"

# Optional user hook to open in the owner's GUI session on wake, e.g. an app
# that mounts local volumes. Empty means no-op. Run only if the path exists.
: "${SMBG_WAKE_USER_HOOK:=}"

# SMB authentication account. May differ from the local owner account —
# **mount ownership determination (`mounted by`) uses SMBG_OWNER, server
# authentication uses this value.** Mixing the two produces the misdiagnosis of
# reading `//account@host/share` as ownership (that notation is the
# authentication account, not the mount owner).
: "${SMBG_SMB_USER:=$SMBG_OWNER}"

# Workspace path as seen inside the guest. Used when a remote diagnostic command
# (such as smbfix's future-mtime check) targets the guest filesystem. It need not
# equal the host mount point — they are paths on different filesystems. Falls
# back to the host path when unset.
: "${SMBG_GUEST_ROOT:=$SMBG_MP}"

# Path appended after the share name in the mount URL. This is what lets a layout
# with the share root above the workspace **mount a subdirectory of the share**
# (the guest-side rationale is in the smb.conf.in header).
# e.g. SMBG_SHARE=ws, SMBG_SHARE_SUBPATH=stewardlabs → //account@host/ws/stewardlabs
# Leave empty to mount the share root itself — existing deployments are unaffected.
: "${SMBG_SHARE_SUBPATH:=}"

# ── Derived values ─────────────────────────────────────────────────────────
# Path portion of the mount URL. The autofs map and smbfix's mount probe must use
# the same value, so it is assembled exactly once here.
SMBG_SHARE_PATH="$SMBG_SHARE${SMBG_SHARE_SUBPATH:+/$SMBG_SHARE_SUBPATH}"

# A failed UID lookup means "that account does not exist". Using a fallback UID
# would touch the mount under an unrelated user's credentials, so fail instead.
SMBG_OWNER_UID="$(id -u "$SMBG_OWNER" 2>/dev/null)"
if [ -z "$SMBG_OWNER_UID" ]; then
  echo "smb-guard: account '$SMBG_OWNER' not found ($SMBG_CONF)" >&2
  exit 78   # EX_CONFIG
fi

SMBG_OWNER_HOME="$(dscl . -read "/Users/$SMBG_OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
: "${SMBG_OWNER_HOME:=/Users/$SMBG_OWNER}"

SMBG_GUARD="/usr/local/sbin/smb-guard"

# ── Runtime paths ──────────────────────────────────────────────────────────
SMBG_RUNDIR="/var/run/smb-guard"            # cleared on reboot — intended
SMBG_LOCKDIR="$SMBG_RUNDIR/lock"
SMBG_LAST_SLEEP="$SMBG_RUNDIR/last_sleep"

if [ "$(id -u)" -eq 0 ]; then
  [ -d "$SMBG_LOGDIR" ] || install -d -o root -g wheel -m 755 "$SMBG_LOGDIR"
  [ -d "$SMBG_RUNDIR" ] || install -d -o root -g wheel -m 755 "$SMBG_RUNDIR"
fi

# ── Logging ────────────────────────────────────────────────────────────────
# Format:  2026-08-08 14:23:01 [tag] message
# Tags distinguish the 4 scripts, so they share one file. wake → guard firing →
# smbfix are causally entangled; without a single time-ordered stream, tracing
# after the fact means correlating timestamps by hand.
: "${SMBG_TAG:=$(basename -- "$0")}"

# Tag computation hook. Redefine at the call site to append elapsed time etc.
#   e.g.  smbg_tag() { printf 'wakeup +%ss' $(( $(date +%s) - T0 )); }
smbg_tag() { printf '%s' "$SMBG_TAG"; }

# Log file only (for non-interactive hooks)
log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$(smbg_tag)" "$*" >> "$SMBG_LOG" 2>/dev/null
}

# Terminal + log (for interactive tools)
say() { printf '%s\n' "$*"; log "$*"; }

# ── Privilege ──────────────────────────────────────────────────────────────
smbg_is_root()  { [ "$(id -u)" -eq 0 ]; }
smbg_is_owner() { [ "$(id -u)" -eq "$SMBG_OWNER_UID" ]; }

# Run with the owner's credentials (no GUI session needed — ssh and the like).
# -H is required so HOME becomes the owner's; otherwise the guest alias in
# ~/.ssh/config does not resolve.
smbg_as_owner() {
  if smbg_is_owner; then "$@"
  else sudo -u "$SMBG_OWNER" -H "$@"
  fi
}

# Run in the owner's GUI session context (needed for the Mach bootstrap and the
# login keychain). The autofs trigger (talking to automountd), open(1) and
# mount_smbfs's keychain lookup all fall in this category.
smbg_in_session() {
  if smbg_is_root; then
    launchctl asuser "$SMBG_OWNER_UID" sudo -u "$SMBG_OWNER" -H "$@"
  else
    "$@"
  fi
}

# Whether a GUI session exists. Fails at the logout/login window.
smbg_session_active() { launchctl print "gui/$SMBG_OWNER_UID" >/dev/null 2>&1; }

# guard invocation wrapper — works from both the system domain (root) and the
# user domain (sudo -n).
smbg_guard() {
  if smbg_is_root; then "$SMBG_GUARD" "$@"
  else sudo -n "$SMBG_GUARD" "$@"
  fi
}

# ── State determination ────────────────────────────────────────────────────
# Determination that does not cause a trigger: read the mount table only.
# Path access (stat/ls) is never used for determination — it can fire the autofs
# trigger, and under a launchd context TCC EPERM leads to a misdiagnosis.
# "ls failed ≠ mount failed".
# Skip the autofs trigger line and look only at the smbfs line.
# A root mount has no 'mounted by' field at all.
smbg_state() {
  local line
  line="$(mount | grep -F " on $SMBG_MP (smbfs" || true)"
  if   [ -z "$line" ];                              then echo ABSENT
  elif [[ "$line" == *"mounted by $SMBG_OWNER"* ]]; then echo HEALTHY
  else                                                   echo FOREIGN
  fi
}

# ── Subcommand output flattening ───────────────────────────────────────────
# Letting a subcommand's stdout/stderr flow into the log verbatim inserts
# untagged text between tagged lines, which makes an expected failure (the one
# that induces the fallback) indistinguishable from a real one — that is why
# "umount failed → success → ls failed → remediation complete" read as a
# contradiction in scenario A on 08-08.
# The original text is not discarded but squashed onto one line and carried
# inside log()'s tag.
smbg_oneline() {
  printf '%s' "$1" | tr -s ' \t\n' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}
