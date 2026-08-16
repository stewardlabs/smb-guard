#!/bin/bash
# doctor.sh — 호스트(macOS) 구성 생존 점검. 읽기 전용 — 아무것도 고치지 않는다.
#
# 왜 별도 도구인가: macOS 메이저 업그레이드는 이 체계의 전제를 두 방향에서 무너뜨릴
# 수 있고, 어느 쪽도 "파일이 있는가"만으로는 판정되지 않는다.
#   · /etc/auto_master · /etc/autofs.conf 는 Apple 배포 파일이라 업그레이드가 기본값으로
#     되돌릴 수 있다 (커뮤니티 보고 반복 — Apple 미문서화). autofs 3종은 정확히
#     install.sh 가 관리하지 않는 영역이어서 (docs/install.md 'autofs 설정 — 이 레포가
#     건드리지 않는 부분') 재설치 한 번으로 복구되지 않는다 — 그래서 검사가 설치와
#     별도의 도구여야 한다.
#   · 백그라운드 항목 승인(BTM, macOS 13+)이 리셋되면 LaunchDaemon 이 "파일은 있는데
#     로드 안 됨"이 된다. launchctl 로 실제 로드 상태를 봐야 구분된다.
#
# 자동 교정하지 않는다 (원칙 21): 권한이 틀려 무시돼 온 파일을 "고치는" 것은 한 번도
# 부여된 적 없는 권한을 새로 여는 일이다. 각 항목은 처방 명령을 안내만 하고, 실행은
# 사람이 판단해서 한다. 배치물(install 관리 영역) 이상의 일괄 처방은 install.sh 재실행이다.
#
# 한계 — 이 도구가 판정하지 못하는 것:
#   · autofs 는 파일 내용만 본다. 파일이 맞아도 반영(sudo automount -vc) 전이면 런타임은
#     옛 값이다 — 반영 여부는 읽기 전용으로 알 수 없다.
#   · StartOnMount 훅이 실제로 걸렸는지는 launchctl print 로 구분할 수 없다
#     (docs/install.md '검증' 1 의 주의). 마운트 동작까지 포함한 검증은 install.md
#     '검증' 절차를 따른다.
#
# 판정 (종료 코드):
#   0 = 검사한 범위 전부 정상 (WARN 은 있을 수 있다)
#   1 = 이상 1건 이상
#   2 = 이상은 없으나 root 필요 항목을 건너뜀 — sudo 로 다시 돌려야 판정이 완결된다
#       (건너뛴 항목의 "조용함"을 정상으로 읽지 않기 위해 0 과 구분한다 — 원칙 25)
#
# usage: sudo ./doctor.sh [--config <경로>]      # root 아니면 일부 항목 skip

set -u

CONF=""
[ "${1:-}" = "--config" ] && { CONF="${2:?--config 에 경로가 필요합니다}"; shift 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# 설정은 배치본을 우선한다 — 런타임이 실제로 읽는 값이 판정 기준이어야 한다.
# 배치본이 없으면(미설치·소실) 레포의 설정으로 폴백해 나머지 검사를 계속한다.
DEPLOY_CONF="/usr/local/etc/smb-guard.conf"
if [ -z "$CONF" ]; then
    if   [ -r "$DEPLOY_CONF" ];         then CONF="$DEPLOY_CONF"
    elif [ -r "$ROOT/smb-guard.conf" ]; then CONF="$ROOT/smb-guard.conf"
    else
        echo "설정을 찾을 수 없습니다: $DEPLOY_CONF, $ROOT/smb-guard.conf" >&2
        exit 78   # EX_CONFIG
    fi
fi
[ -r "$CONF" ] || { echo "설정을 읽을 수 없습니다: $CONF" >&2; exit 78; }
# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_OWNER:?$CONF: SMBG_OWNER 미설정}"
: "${SMBG_MP:?$CONF: SMBG_MP 미설정}"
: "${SMBG_HOST:?$CONF: SMBG_HOST 미설정}"
: "${SMBG_SHARE:?$CONF: SMBG_SHARE 미설정}"
: "${SMBG_SHARE_SUBPATH:=}"
: "${SMBG_LABEL_PREFIX:=io.stewardlabs}"
: "${SMBG_LOGDIR:=/var/log/smb}"
SMBG_SHARE_PATH="$SMBG_SHARE${SMBG_SHARE_SUBPATH:+/$SMBG_SHARE_SUBPATH}"

GUARD_LABEL="$SMBG_LABEL_PREFIX.smb-guard"
WATCH_LABEL="$SMBG_LABEL_PREFIX.sleepwatcher"
GUARD_PLIST="/Library/LaunchDaemons/$GUARD_LABEL.plist"
WATCH_PLIST="/Library/LaunchDaemons/$WATCH_LABEL.plist"
NEWSYSLOG="/etc/newsyslog.d/$SMBG_LABEL_PREFIX.smb.conf"

OWNER_UID="$(id -u "$SMBG_OWNER" 2>/dev/null)" || {
    echo "계정 '$SMBG_OWNER' 이(가) 존재하지 않습니다 ($CONF)" >&2; exit 78; }
OWNER_HOME="$(dscl . -read "/Users/$SMBG_OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
: "${OWNER_HOME:=/Users/$SMBG_OWNER}"

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# ── 판정 출력 ──────────────────────────────────────────────────────────────
# skip 은 "검사 안 함"이지 "정상"이 아니다 — 종료 코드에서 0 과 2 로 구분한다.
N_OK=0; N_FAIL=0; N_WARN=0; N_SKIP=0
section() { printf '\n== %s ==\n' "$1"; }
hint()    { [ -n "${1:-}" ] && printf '        → %s\n' "$1"; return 0; }
ok()      { N_OK=$((N_OK + 1));     printf '  ok    %s\n' "$1"; }
warn()    { N_WARN=$((N_WARN + 1)); printf '  WARN  %s\n' "$1"; hint "${2:-}"; }
fail()    { N_FAIL=$((N_FAIL + 1)); printf '  FAIL  %s\n' "$1"; hint "${2:-}"; }
skip()    { N_SKIP=$((N_SKIP + 1)); printf '  skip  %s\n' "$1"; hint "${2:-}"; }

# check_file <경로> <owner:group> <8진권한> — 존재·소유·권한을 한 번에 판정.
# 지배적 실패 모드가 "권한이 틀리면 조용히 무시된다"이므로 (host/install.sh 헤더),
# 존재만 보고 넘어가면 반쪽 판정이다.
check_file() {
    local p="$1" og="$2" perm="$3" st
    if [ ! -e "$p" ]; then
        fail "$p 없음" "sudo ./host/install.sh 재실행"
        return 1
    fi
    st="$(stat -f '%Su:%Sg %Lp' "$p" 2>/dev/null)" || { fail "$p stat 실패"; return 1; }
    if [ "$st" = "$og $perm" ]; then
        ok "$p ($st)"
    else
        fail "$p 소유·권한 이상: $st (기대 $og $perm)" \
             "sudo chown $og '$p' && sudo chmod $perm '$p'  (또는 install.sh 재실행)"
        return 1
    fi
    return 0
}

# drift <배치본> <레포원본> — 내용 비교. 레포 밖에서 실행되면(원본 부재) 건너뛴다.
# FAIL 이 아니라 WARN 인 이유: 어느 쪽이 최신인지는 내용만으로 판정할 수 없다 —
# 레포가 앞서 있으면 "재설치 필요"고, 배치본이 앞서 있으면 "레포 반영 필요"다.
drift() {
    local deployed="$1" src="$2"
    [ -r "$src" ] || { skip "드리프트: $deployed (레포 원본 없음)"; return 0; }
    [ -r "$deployed" ] || return 0   # 부재는 check_file 이 이미 FAIL 로 보고했다
    if cmp -s "$deployed" "$src"; then
        ok "드리프트 없음: $deployed"
    else
        warn "레포와 내용이 다름: $deployed" \
             "diff '$src' '$deployed' 로 방향 확인 후 install.sh 재실행 또는 레포 반영"
    fi
}

echo "smb-guard doctor — 설정 $CONF"
[ "$IS_ROOT" -eq 1 ] || echo "(root 아님 — 일부 항목을 건너뜁니다. 완결 판정은 sudo $0)"

# ── 1. autofs — install 비관리 영역, 업그레이드 원복 위험 최고 ─────────────
section "autofs (docs/install.md 'autofs 설정')"

if grep -Eq '^/-[[:space:]]+auto_smb([[:space:]]|$)' /etc/auto_master 2>/dev/null; then
    ok "/etc/auto_master 직접 맵 라인"
else
    fail "/etc/auto_master 에 auto_smb 직접 맵 라인이 없음 — 업그레이드 원복 의심" \
         "'/-    auto_smb    -nosuid' 추가 후 sudo automount -vc"
fi

if [ ! -e /etc/auto_smb ]; then
    fail "/etc/auto_smb 없음" "docs/install.md 'autofs 설정' 절차로 재작성"
else
    st="$(stat -f '%Su %Lp' /etc/auto_smb 2>/dev/null)"
    if [ "$st" = "root 600" ]; then
        ok "/etc/auto_smb (root 600)"
    else
        # URL 에 자격 증명이 들어 있다 — 다른 사용자가 읽을 수 있으면 유출이다.
        fail "/etc/auto_smb 소유·권한 이상: $st (기대 root 600 — 자격 증명 포함 파일)" \
             "sudo chown root /etc/auto_smb && sudo chmod 600 /etc/auto_smb"
    fi
    if [ -r /etc/auto_smb ]; then
        map_line="$(awk -v mp="$SMBG_MP" '$1 == mp {print; exit}' /etc/auto_smb)"
        if [ -z "$map_line" ]; then
            fail "/etc/auto_smb 에 $SMBG_MP 항목이 없음"
        else
            opts="$(printf '%s\n' "$map_line" | awk '{print $2}')"
            url="$(printf '%s\n' "$map_line" | awk '{print $3}')"
            case "$opts" in
                *-fstype=smbfs*) ok "맵: fstype=smbfs" ;;
                *) fail "맵: fstype 이 smbfs 가 아님 ($opts)" ;;
            esac
            # soft 는 필수 — 서버 부재 시 유한 시간 내 실패해야 SMBG_TRIGGER_TIMEOUT 과
            # 웨이크 훅의 대기 상한이 성립한다 (docs/install.md).
            case ",$opts," in
                *,soft,*) ok "맵: soft" ;;
                *) fail "맵: soft 옵션 없음 — 서버 부재 시 무한 대기, 훅 대기 상한 붕괴" ;;
            esac
            # nodatacache 는 게스트 로컬 쓰기를 맥이 읽는 구성에서 필수 (층 7).
            # 순수 소비용 마운트라면 없어도 되므로 FAIL 이 아니라 WARN 이다.
            case ",$opts," in
                *,nodatacache,*) ok "맵: nodatacache" ;;
                *) warn "맵: nodatacache 없음" \
                        "게스트 로컬 쓰기를 읽는 구성이면 필수 (failure-model.md 층 7)" ;;
            esac
            case "$url" in
                *"@$SMBG_HOST/$SMBG_SHARE_PATH") ok "맵: URL …@$SMBG_HOST/$SMBG_SHARE_PATH" ;;
                *) fail "맵: URL 이 설정과 불일치 (기대 …@$SMBG_HOST/$SMBG_SHARE_PATH)" ;;
            esac
        fi
    else
        skip "/etc/auto_smb 내용 검사 (root 필요)"
    fi
fi

tmo="$(sed -n 's/^AUTOMOUNT_TIMEOUT=//p' /etc/autofs.conf 2>/dev/null | tail -1)"
case "$tmo" in
    '')       fail "AUTOMOUNT_TIMEOUT 미설정 — Apple 기본 3600 = 만료 창 부활 (층 0)" \
                   "/etc/autofs.conf 에 AUTOMOUNT_TIMEOUT=604800 설정 후 sudo automount -vc" ;;
    *[!0-9]*) warn "AUTOMOUNT_TIMEOUT='$tmo' — 숫자가 아님" ;;
    *) if [ "$tmo" -lt 86400 ]; then
           warn "AUTOMOUNT_TIMEOUT=$tmo — 만료 창이 하루 미만" \
                "의도한 값인지 확인 (docs 권장 604800)"
       else
           ok "AUTOMOUNT_TIMEOUT=$tmo"
       fi ;;
esac

# ── 2. 배치물 — install 관리 영역, 이상 시 일괄 처방은 재설치 ──────────────
section "배치물 (host/install.sh 관리 영역)"

check_file "$DEPLOY_CONF"                     root:wheel 644 && drift "$DEPLOY_CONF" "$ROOT/smb-guard.conf"
check_file /usr/local/lib/smb-guard/common.sh root:wheel 644 && drift /usr/local/lib/smb-guard/common.sh "$ROOT/host/lib/common.sh"
for f in smb-guard smb-guard-sleep smb-guard-wakeup smbfix; do
    check_file "/usr/local/sbin/$f" root:wheel 755 && drift "/usr/local/sbin/$f" "$ROOT/host/sbin/$f"
done
check_file "$GUARD_PLIST" root:wheel 644
check_file "$WATCH_PLIST" root:wheel 644
check_file "$NEWSYSLOG"   root:wheel 644
check_file "$SMBG_LOGDIR" root:wheel 755

# sleepwatcher 바이너리 — brew 마이그레이션·재설치로 소실될 수 있다. 배치된 plist 가
# 가리키는 실제 경로를 기준으로 본다 (템플릿의 @SLEEPWATCHER_BIN@ 이 치환된 값).
SW="$(plutil -extract ProgramArguments.0 raw -o - "$WATCH_PLIST" 2>/dev/null)" || SW=""
if [ -z "$SW" ]; then
    skip "sleepwatcher 바이너리 (plist 에서 경로를 읽지 못함)"
elif [ -x "$SW" ]; then
    ok "sleepwatcher 바이너리: $SW"
else
    fail "sleepwatcher 바이너리 없음: $SW" \
         "brew install sleepwatcher 후 sudo ./host/install.sh 재실행 (경로가 바뀌었을 수 있다)"
fi

# 렌더링 산출물 드리프트 — 템플릿과 배치본은 직접 비교할 수 없으므로 install.sh 와
# 같은 규칙으로 재렌더링해서 비교한다. 치환값(SW)을 못 얻었으면 측정 불가로 넘긴다.
if [ -n "$SW" ] && [ -r "$ROOT/host/LaunchDaemons/smb-guard.plist.in" ]; then
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smb-guard-doctor.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    render() {
        sed -e "s|@LABEL_PREFIX@|$SMBG_LABEL_PREFIX|g" \
            -e "s|@LOGDIR@|$SMBG_LOGDIR|g" \
            -e "s|@SLEEPWATCHER_BIN@|$SW|g" \
            "$1" > "$2"
    }
    render "$ROOT/host/LaunchDaemons/smb-guard.plist.in"    "$STAGE/guard.plist"
    render "$ROOT/host/LaunchDaemons/sleepwatcher.plist.in" "$STAGE/watch.plist"
    render "$ROOT/host/newsyslog.d/smb.conf.in"             "$STAGE/newsyslog.conf"
    drift "$GUARD_PLIST" "$STAGE/guard.plist"
    drift "$WATCH_PLIST" "$STAGE/watch.plist"
    drift "$NEWSYSLOG"   "$STAGE/newsyslog.conf"
else
    skip "렌더링 산출물 드리프트 (레포 템플릿 또는 치환값 없음)"
fi

# ── 3. launchd 로드 상태 — BTM 리셋의 탐지 지점 ────────────────────────────
section "launchd (system 도메인 — root 필요)"

if [ "$IS_ROOT" -eq 1 ]; then
    if launchctl print "system/$GUARD_LABEL" >/dev/null 2>&1; then
        ok "$GUARD_LABEL 로드됨 (state 는 not running 이 정상 — 이벤트 훅)"
    elif [ -e "$GUARD_PLIST" ]; then
        fail "$GUARD_LABEL: plist 는 있는데 로드 안 됨 — BTM 승인 리셋 의심" \
             "시스템 설정 > 일반 > 로그인 항목 확인 후 sudo launchctl bootstrap system $GUARD_PLIST"
    else
        fail "$GUARD_LABEL 미설치" "sudo ./host/install.sh"
    fi
    watch_pr="$(launchctl print "system/$WATCH_LABEL" 2>/dev/null)"
    if [ -z "$watch_pr" ]; then
        if [ -e "$WATCH_PLIST" ]; then
            fail "$WATCH_LABEL: plist 는 있는데 로드 안 됨 — BTM 승인 리셋 의심" \
                 "시스템 설정 > 일반 > 로그인 항목 확인 후 sudo launchctl bootstrap system $WATCH_PLIST"
        else
            fail "$WATCH_LABEL 미설치" "sudo ./host/install.sh"
        fi
    elif printf '%s' "$watch_pr" | grep -q 'state = running'; then
        ok "$WATCH_LABEL 상주 중 (state = running)"
    else
        fail "$WATCH_LABEL 로드됐지만 미상주 — 수면·웨이크 훅이 죽어 있다" \
             "로그 확인: $SMBG_LOGDIR/sleepwatcher.launchd.log"
    fi
else
    skip "$GUARD_LABEL 로드 상태 (root 필요)"
    skip "$WATCH_LABEL 상주 상태 (root 필요)"
fi

# brew 가 만든 사용자 도메인 에이전트가 남아 있으면 훅이 중복 발화한다 (install.sh 1 단계).
if launchctl print "gui/$OWNER_UID/homebrew.mxcl.sleepwatcher" >/dev/null 2>&1; then
    fail "brew 사용자 도메인 sleepwatcher 가 로드되어 있음 — 훅 중복 발화" \
         "brew services stop sleepwatcher"
else
    ok "brew 중복 에이전트 없음"
fi
if [ -e "$OWNER_HOME/Library/LaunchAgents/homebrew.mxcl.sleepwatcher.plist" ]; then
    warn "brew sleepwatcher plist 잔재: $OWNER_HOME/Library/LaunchAgents/" \
         "로드되진 않았지만 로그인 시 재적재될 수 있다 — brew services stop sleepwatcher"
fi

# ── 4. 로그 회전 — 권한이 틀리면 말없이 무시된다 ───────────────────────────
section "newsyslog"

ns_out="$(newsyslog -nv 2>/dev/null)"
if [ -z "$ns_out" ]; then
    skip "newsyslog -nv 실행 불가 (root 필요할 수 있음)"
else
    n="$(printf '%s\n' "$ns_out" | grep -Fc "$SMBG_LOGDIR/")"
    if [ "$n" -eq 3 ]; then
        ok "로그 회전 대상 3개 등록"
    else
        fail "로그 회전 대상 ${n}개 (기대 3) — 설정이 말없이 무시되고 있다" \
             "ls -l $NEWSYSLOG 로 root:wheel 644 확인"
    fi
fi

# ── 5. 게스트 ssh — 최우선 검증 (실패하면 시계 교정이 통째로 죽는다) ───────
section "게스트 ssh"

ssh_out=""; ssh_ctx=""
if [ "$IS_ROOT" -eq 1 ]; then
    # root 컨텍스트가 진짜 검증이다 — launchd 훅이 정확히 이 경로(sudo -u 소유자 -H)로
    # 게스트에 접속한다. -H 없이는 root 의 ~/.ssh 를 보게 되어 별칭이 해석되지 않는다.
    ssh_ctx="root→소유자"
    ssh_out="$(sudo -u "$SMBG_OWNER" -H ssh -o BatchMode=yes -o ConnectTimeout=3 "$SMBG_HOST" 'date +%s' 2>/dev/null)"
elif [ "$(id -u)" -eq "$OWNER_UID" ]; then
    ssh_ctx="소유자"
    ssh_out="$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$SMBG_HOST" 'date +%s' 2>/dev/null)"
else
    skip "게스트 ssh (소유자도 root 도 아님)"
fi
if [ -n "$ssh_ctx" ]; then
    case "$ssh_out" in
        ''|*[!0-9]*)
            fail "게스트 ssh 실패 ($ssh_ctx 컨텍스트): $SMBG_HOST" \
                 "docs/install.md '검증 0' — 이게 죽으면 시계 교정 전체가 무력화된다" ;;
        *)
            if [ "$ssh_ctx" = "root→소유자" ]; then
                ok "게스트 ssh OK (root 컨텍스트)"
            else
                ok "게스트 ssh OK (소유자 컨텍스트 — root 컨텍스트 검증은 sudo 실행 시)"
            fi ;;
    esac
fi

# ── 6. 마운트 상태 ─────────────────────────────────────────────────────────
section "마운트"

# common.sh 의 smbg_state 와 같은 판정을 자체 구현한다 — 배치본이 깨진 상황에서도
# 이 도구는 동작해야 하므로 배치본을 source 하지 않는다.
mnt="$(mount | grep -F " on $SMBG_MP (smbfs" || true)"
if [ -z "$mnt" ]; then
    warn "마운트 부재 (ABSENT)" "sudo smb-guard --ensure"
elif [ "${mnt#*mounted by $SMBG_OWNER}" != "$mnt" ]; then
    ok "마운트 HEALTHY (mounted by $SMBG_OWNER)"
else
    fail "마운트 FOREIGN — 소유권 하이재킹 상태" "sudo smb-guard --ensure"
fi

# ── 판정 ───────────────────────────────────────────────────────────────────
printf '\n정상 %s건 / 이상 %s건 / 주의 %s건 / 건너뜀 %s건\n' "$N_OK" "$N_FAIL" "$N_WARN" "$N_SKIP"

if [ "$N_FAIL" -gt 0 ]; then
    echo "→ 이상이 있습니다. 항목별 처방을 따르거나, 배치물 이상이면 sudo ./host/install.sh 를 재실행하세요."
    exit 1
fi
if [ "$N_SKIP" -gt 0 ]; then
    echo "→ 이상은 없으나 판정이 불완전합니다. sudo $0 으로 다시 돌리세요."
    exit 2
fi
echo "→ 정상입니다."
exit 0
