#!/bin/bash
# cleanup.sh — v13 구 배치 제거. **install.sh 실행 + 최소 1회 sleep/wake 검증 후**에 돌린다.
#
# install.sh 와 분리한 이유:
#   구 훅(~/.sleep, ~/.wakeup)이 남아 있으면 롤백이 가능하다. 검증 전에 지우면
#   되돌릴 수단이 사라진다. 반대로 검증 후에도 남겨두면 위험하다 —
#   `brew upgrade sleepwatcher` 등으로 brew 서비스가 되살아날 경우
#   구 훅과 신 훅이 동시 실행되어 이중 개입이 일어난다.
#
# 기본은 dry-run. 실제 삭제는  sudo ./cleanup.sh --apply
set -eu

[ "$(id -u)" -eq 0 ] || { echo "sudo ./cleanup.sh [--apply] 로 실행하세요" >&2; exit 1; }

APPLY=0
PURGE_SUDOERS=0
for a in "$@"; do
    case "$a" in
        --apply)          APPLY=1 ;;
        --purge-sudoers)  PURGE_SUDOERS=1 ;;
        *) echo "usage: sudo ./cleanup.sh [--apply] [--purge-sudoers]" >&2; exit 2 ;;
    esac
done
[ "$APPLY" -eq 0 ] && echo "*** DRY-RUN — 실제 삭제하려면 --apply ***" && echo

OWNER="sanha"
HOME_DIR="$(dscl . -read "/Users/$OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
: "${HOME_DIR:=/Users/$OWNER}"

BACKUP="/var/backups/smb-guard-v13-$(date +%Y%m%d%H%M%S)"

# set -e 로 중단될 때 침묵하지 않도록. 정리 작업의 부분 실행은 반드시 알려야 한다.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "!! 예기치 못한 오류로 중단되었습니다 (exit=$rc)." >&2
    echo "   부분적으로 삭제되었을 수 있습니다. 백업 확인: $BACKUP" >&2
    echo "   sudoers 상태 확인:  sudo visudo -c" >&2
fi' EXIT

act() {   # act <경로> <설명>
    [ -e "$1" ] || return 0
    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$BACKUP"
        cp -a "$1" "$BACKUP/" 2>/dev/null || true
        rm -rf "$1"
        echo "  삭제 (백업됨): $1   — $2"
    else
        echo "  [삭제 예정] $1   — $2"
    fi
}

echo "== 1. brew sleepwatcher 서비스 잔재 =="
OWNER_UID="$(id -u "$OWNER" 2>/dev/null || echo 501)"
if [ "$APPLY" -eq 1 ]; then
    launchctl bootout "gui/$OWNER_UID/homebrew.mxcl.sleepwatcher" 2>/dev/null || true
    sudo -u "$OWNER" -H brew services stop sleepwatcher 2>/dev/null || true
fi
act "$HOME_DIR/Library/LaunchAgents/homebrew.mxcl.sleepwatcher.plist" "brew 생성 에이전트"

echo "== 2. 구 훅 (이중 실행 위험 — 반드시 제거) =="
act "$HOME_DIR/.sleep"   "→ /usr/local/sbin/smb-guard-sleep"
act "$HOME_DIR/.wakeup"  "→ /usr/local/sbin/smb-guard-wakeup"
act "$HOME_DIR/bin/smbfix" "→ /usr/local/sbin/smbfix"

echo "== 3. 구 상태·로그 파일 =="
act "$HOME_DIR/.sleepwatcher.log"         "→ /var/log/smb/smb-guard.log"
act "$HOME_DIR/.sleepwatcher.last_sleep"  "→ /var/run/smb-guard/last_sleep"
act "$HOME_DIR/.sleepwatcher.sleep_state" "v14에서 폐지 (state는 로그 한 줄로 기록)"
act "/var/log/smb-guard.log"              "→ /var/log/smb/smb-guard.log"
act "/var/log/smb-guard.launchd.log"      "→ /var/log/smb/smb-guard.launchd.log"

echo "== 4. sudoers =="
# 삭제 전에 무엇을 회수하는지 보여준다. NOPASSWD 규칙은 상시 권한 부여이므로
# "무엇이 사라지는지" 를 눈으로 확인하고 지우는 것이 옳다.
show_rule() {
    [ -r "$1" ] || return 0
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1" | sed 's/^/       /'
}

# sudoers.d 파일의 권한 감사. **자동 교정하지 않는다.**
# 권한이 틀려 sudo가 무시해 온 파일을 0440으로 "고치는" 것은, 실제로는 부여된 적 없는
# NOPASSWD 권한을 지금 새로 여는 일이다. 정리 작업이 권한 확대가 되어서는 안 된다.
audit_mode() {
    [ -e "$1" ] || return 0
    # set -e 주의: 명령치환이 실패한 할당은 셸을 "조용히" 종료시킨다.
    # 정리 스크립트가 말없이 죽으면 부분 삭제 상태로 남으므로 반드시 || true 로 막는다.
    local m; m="$(stat -f %Lp "$1" 2>/dev/null || true)"
    # stat 의 -f 는 macOS(BSD)에서 포맷 지정이지만 GNU에서는 파일시스템 정보다.
    # 결과가 8진 권한 형태가 아니면 판정하지 않는다 — 잘못된 경고보다 침묵이 낫다.
    case "$m" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
        *) echo "  ?? 권한을 읽지 못했습니다: $1 (수동 확인: ls -l '$1')"; return 0 ;;
    esac
    [ "$m" = "440" ] && return 0
    echo "  !! 권한 이상: $1 = 0$m (sudoers 기대값 0440)"
    echo "     이 파일의 규칙이 실제로 적용돼 왔는지 불확실합니다. 확인:"
    echo "       sudo -l -U $OWNER"
    echo "     자동 교정하지 않습니다 — 인효였다면 교정은 권한 확대가 됩니다."
    echo "     유지하려면 직접:  sudo chown root:wheel '$1' && sudo chmod 0440 '$1'"
}

audit_mode /etc/sudoers.d/smb-guard
audit_mode /etc/sudoers.d/smb-remount

# (a) smb-guard — v14에서 훅이 root로 실행되므로 불필요.
#     이를 참조하던 구 ~/.wakeup / ~/bin/smbfix 는 §2에서 함께 제거된다.
if [ -e /etc/sudoers.d/smb-guard ]; then
    echo "  현재 규칙:"; show_rule /etc/sudoers.d/smb-guard
fi
act "/etc/sudoers.d/smb-guard" "v14에서 불필요 (훅이 root로 실행됨)"

# (b) smb-remount — umount -f / automount -vc / diskutil unmount force 의 NOPASSWD.
#     v14 스크립트 중 이것을 쓰는 것은 없다(smbfix는 자체 sudo 승격, guard는 root 실행).
#     쓰지 않는 NOPASSWD는 제거가 원칙이나, 인벤토리 밖의 셸 별칭·수동 절차가 의존할 수
#     있으므로 기본 보존한다. 확신이 서면 --purge-sudoers 로 함께 제거한다.
if [ -e /etc/sudoers.d/smb-remount ]; then
    echo "  현재 규칙:"; show_rule /etc/sudoers.d/smb-remount
fi
if [ "$PURGE_SUDOERS" -eq 1 ]; then
    act "/etc/sudoers.d/smb-remount" "--purge-sudoers 지정 — v14 스크립트 중 사용처 없음"
else
    echo "  [보존] /etc/sudoers.d/smb-remount"
    echo "         v14 스크립트 중 사용처 없음. 제거하려면 --purge-sudoers 를 붙이세요."
    echo "         제거해도 smbfix 는 자체 sudo 승격으로 동작합니다 (비밀번호 1회 입력)."
fi
echo "== 5. sudoers 무결성 검사 =="
# 파일 제거로 문법이 깨질 일은 없지만, 다른 원인으로 이미 깨져 있었다면
# 여기서 잡는 편이 낫다 — sudoers 파손은 sudo 자체를 못 쓰게 만든다.
if visudo -c >/dev/null 2>&1; then
    echo "  visudo -c OK"
else
    echo "  !! sudoers 문법 오류 감지. 즉시 확인하세요:  sudo visudo -c"
    visudo -c || true
fi

echo
if [ "$APPLY" -eq 1 ]; then
    echo "완료. 백업: $BACKUP"
    echo "롤백이 필요하면 위 디렉터리에서 원본을 복원하세요."
    if [ "$PURGE_SUDOERS" -eq 0 ]; then
        echo "참고: /etc/sudoers.d/smb-remount 는 보존했습니다 (--purge-sudoers 로 제거 가능)."
    fi
else
    echo "실제 삭제:  sudo ./cleanup.sh --apply"
    echo "sudoers 까지:  sudo ./cleanup.sh --apply --purge-sudoers"
fi

# 마지막 문장이 AND 리스트면 그 반환값이 스크립트 종료 코드가 되어 EXIT trap을 오탐시킨다
# (08-08 실제 발생: --purge-sudoers 지정 시 정상 완료인데 exit=1). 명시적으로 0을 반환한다.
exit 0
