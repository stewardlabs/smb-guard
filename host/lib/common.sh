#!/bin/bash
# /usr/local/lib/smb-guard/common.sh
# smb-guard 계열 공용부 — source 전용. 실행 파일이 아니다.
#
# 구성원:
#   /usr/local/sbin/smb-guard          마운트 이벤트 훅(StartOnMount) + 유일한 교정 엔진
#   /usr/local/sbin/smb-guard-sleep    sleepwatcher -s  (기록만)
#   /usr/local/sbin/smb-guard-wakeup   sleepwatcher -w
#   /usr/local/sbin/smbfix             수동 복구 (대화형)
#
# 경계 원칙 — 이 파일에는 "읽기 전용"만 둔다:
#   상수 · 로깅 · 상태 판정 · 자격 전환 래퍼.
#   마운트를 실제로 바꾸는 코드(force_umount / trigger / 재시도)는 smb-guard 안에만 있다.
#   교정 주체를 하나로 유지하는 것이 이 체계의 핵심 불변식이며,
#   판정 로직을 공유하는 것은 그 불변식을 깨지 않는다 — 오히려 판정 기준의 분기를 막는다.
#
# 대상 셸: bash 3.2 (macOS 기본 /bin/bash). zsh 전용 문법 금지.

# ── 설정 로드 ──────────────────────────────────────────────────────────────
# 환경 고유 값(계정·마운트 지점·호스트 별칭·공유명)은 이 파일이 아니라 설정 파일에서
# 온다. 코드와 환경을 분리해 두어야 배포본을 갱신해도 로컬 값이 살아남는다.
#
# **설정 파일은 심볼릭 링크로 배포하지 않는다 — 순환 의존이 된다.**
# 이 체계가 복구하는 대상이 바로 워크스페이스 마운트인데, 설정을 그 마운트 안의 정본에
# 링크하면 마운트가 끊긴 순간 복구 수단이 함께 사라진다. 반드시 실파일로 둔다.
SMBG_CONF="${SMBG_CONF:-/usr/local/etc/smb-guard.conf}"
if [ -r "$SMBG_CONF" ]; then
  . "$SMBG_CONF"
fi

# 로그 경로는 필수값 검증보다 **먼저** 확정한다. 검증이 실패할 때 그 사실을 어디에
# 남길지가 로그 설정에 달려 있기 때문이다.
: "${SMBG_LOGDIR:=/var/log/smb}"
SMBG_LOG="$SMBG_LOGDIR/smb-guard.log"       # 4개 스크립트 통합 이벤트 로그

# ── 필수 설정 ──────────────────────────────────────────────────────────────
# 값이 없으면 여기서 죽는다. 기본값으로 넘어가면 "남의 계정으로 남의 마운트를 건드리는"
# 동작이 되므로, 침묵 성공보다 명시적 실패가 옳다 (설계 원칙 9).
: "${SMBG_OWNER:?smb-guard: SMBG_OWNER 미설정 — $SMBG_CONF 를 확인하세요}"
: "${SMBG_MP:?smb-guard: SMBG_MP 미설정 — $SMBG_CONF 를 확인하세요}"
: "${SMBG_HOST:?smb-guard: SMBG_HOST 미설정 — $SMBG_CONF 를 확인하세요}"
: "${SMBG_SHARE:?smb-guard: SMBG_SHARE 미설정 — $SMBG_CONF 를 확인하세요}"

# ── 선택 설정 (기본값) ─────────────────────────────────────────────────────
# launchd Label 접두사. plist 파일명과 Label 이 일치해야 하므로 install.sh 가 양쪽을
# 함께 생성한다. 여기서는 스크립트가 잡을 조회할 때 쓴다.
: "${SMBG_LABEL_PREFIX:=io.stewardlabs}"

# 트리거 ls 의 상한. 맵의 soft 옵션이 전제다 — 서버 부재 시에도 유한 시간 내 실패한다.
# hard 마운트에서는 이 값이 무의미하므로 맵을 먼저 확인할 것.
: "${SMBG_TRIGGER_TIMEOUT:=15}"

# 스퓨리어스 웨이크 게이트. 이보다 짧게 잔 것은 sleep-transition darkwake 로 보고
# 웨이크 처리를 통째로 건너뛴다.
: "${SMBG_SLEEP_GATE:=30}"

# 웨이크 시 소유자 GUI 세션에서 열 사용자 훅 (선택). 로컬 볼륨 마운트 앱 등.
# 값이 없으면 무동작이다. 경로가 존재할 때만 실행한다.
: "${SMBG_WAKE_USER_HOOK:=}"

# SMB 인증 계정. 로컬 소유자 계정과 다를 수 있다 — **마운트 소유자 판정(`mounted by`)은
# SMBG_OWNER 로, 서버 인증은 이 값으로 한다.** 둘을 섞으면 `//계정@호스트/공유` 표기를
# 소유자 판정에 쓰는 오진이 생긴다(그 표기는 인증 계정일 뿐 마운트 소유자가 아니다).
: "${SMBG_SMB_USER:=$SMBG_OWNER}"

# 게스트 안에서의 워크스페이스 경로. 원격 진단 명령(smbfix 의 미래 mtime 점검 등)이
# 게스트 파일시스템을 대상으로 할 때 쓴다. 호스트 마운트 지점과 값이 같을 필요가 없다 —
# 서로 다른 파일시스템의 경로다. 미설정 시 호스트 경로로 폴백한다.
: "${SMBG_GUEST_ROOT:=$SMBG_MP}"

# 마운트 URL 에서 공유명 뒤에 붙는 경로. 공유 루트를 워크스페이스보다 위로 두는 배치에서
# **공유의 하위 디렉터리를 마운트**하기 위한 값이다 (게스트측 근거는 smb.conf.in 헤더).
# 예: SMBG_SHARE=ws, SMBG_SHARE_SUBPATH=stewardlabs → //계정@호스트/ws/stewardlabs
# 비워 두면 공유 루트를 그대로 마운트한다 — 기존 배포의 동작이 바뀌지 않는다.
: "${SMBG_SHARE_SUBPATH:=}"

# ── 파생 값 ────────────────────────────────────────────────────────────────
# 마운트 URL 의 경로부. autofs 맵과 smbfix 의 마운트 프로브가 같은 값을 써야 하므로
# 여기서 한 번만 조립한다.
SMBG_SHARE_PATH="$SMBG_SHARE${SMBG_SHARE_SUBPATH:+/$SMBG_SHARE_SUBPATH}"

# UID 조회 실패는 "그 계정이 없다"는 뜻이다. 폴백 UID 를 쓰면 무관한 사용자의 자격으로
# 마운트를 건드리게 되므로 실패시킨다.
SMBG_OWNER_UID="$(id -u "$SMBG_OWNER" 2>/dev/null)"
if [ -z "$SMBG_OWNER_UID" ]; then
  echo "smb-guard: 계정 '$SMBG_OWNER' 을(를) 찾을 수 없습니다 ($SMBG_CONF)" >&2
  exit 78   # EX_CONFIG
fi

SMBG_OWNER_HOME="$(dscl . -read "/Users/$SMBG_OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
: "${SMBG_OWNER_HOME:=/Users/$SMBG_OWNER}"

SMBG_GUARD="/usr/local/sbin/smb-guard"

# ── 런타임 경로 ────────────────────────────────────────────────────────────
SMBG_RUNDIR="/var/run/smb-guard"            # 재부팅 시 소멸 — 의도된 동작
SMBG_LOCKDIR="$SMBG_RUNDIR/lock"
SMBG_LAST_SLEEP="$SMBG_RUNDIR/last_sleep"

if [ "$(id -u)" -eq 0 ]; then
  [ -d "$SMBG_LOGDIR" ] || install -d -o root -g wheel -m 755 "$SMBG_LOGDIR"
  [ -d "$SMBG_RUNDIR" ] || install -d -o root -g wheel -m 755 "$SMBG_RUNDIR"
fi

# ── 로깅 ──────────────────────────────────────────────────────────────────
# 형식:  2026-08-08 14:23:01 [tag] 메시지
# 태그로 4개 스크립트를 구분하므로 파일은 하나로 합친다. wake → guard 발화 → smbfix가
# 인과적으로 얽혀 있어, 시간순 단일 스트림이 아니면 사후 추적에 타임스탬프 대조가 필요해진다.
: "${SMBG_TAG:=$(basename -- "$0")}"

# 태그 계산 훅. 경과시간 등을 붙이려면 호출 측에서 재정의한다.
#   예)  smbg_tag() { printf 'wakeup +%ss' $(( $(date +%s) - T0 )); }
smbg_tag() { printf '%s' "$SMBG_TAG"; }

# 로그 파일에만 기록 (비대화형 훅용)
log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$(smbg_tag)" "$*" >> "$SMBG_LOG" 2>/dev/null
}

# 터미널 + 로그 (대화형 도구용)
say() { printf '%s\n' "$*"; log "$*"; }

# ── 권한 ──────────────────────────────────────────────────────────────────
smbg_is_root()  { [ "$(id -u)" -eq 0 ]; }
smbg_is_owner() { [ "$(id -u)" -eq "$SMBG_OWNER_UID" ]; }

# 소유자 자격으로 실행 (GUI 세션 불필요 — ssh 등).
# -H 로 HOME을 소유자 것으로 맞춰야 ~/.ssh/config 의 게스트 별칭이 해석된다.
smbg_as_owner() {
  if smbg_is_owner; then "$@"
  else sudo -u "$SMBG_OWNER" -H "$@"
  fi
}

# 소유자의 GUI 세션 컨텍스트로 실행 (Mach 부트스트랩 · 로그인 키체인 필요 시).
# autofs 트리거(automountd 대화), open(1), mount_smbfs 의 키체인 조회가 여기에 해당한다.
smbg_in_session() {
  if smbg_is_root; then
    launchctl asuser "$SMBG_OWNER_UID" sudo -u "$SMBG_OWNER" -H "$@"
  else
    "$@"
  fi
}

# GUI 세션 존재 여부. 로그아웃/로그인 화면 상태에서는 실패한다.
smbg_session_active() { launchctl print "gui/$SMBG_OWNER_UID" >/dev/null 2>&1; }

# guard 호출 래퍼 — system 도메인(root)과 user 도메인(sudo -n) 양쪽에서 동작한다.
smbg_guard() {
  if smbg_is_root; then "$SMBG_GUARD" "$@"
  else sudo -n "$SMBG_GUARD" "$@"
  fi
}

# ── 상태 판정 ─────────────────────────────────────────────────────────────
# 트리거를 유발하지 않는 판정: mount 테이블만 읽는다.
# 경로 접근(stat/ls)은 판정에 쓰지 않는다 — autofs 트리거를 유발할 수 있고,
# launchd 컨텍스트에서는 TCC EPERM으로 오판을 낳는다. "ls 실패 ≠ 마운트 실패".
# autofs 트리거 라인은 제외하고 smbfs 라인만 본다.
# root 마운트에는 'mounted by' 필드 자체가 없다.
smbg_state() {
  local line
  line="$(mount | grep -F " on $SMBG_MP (smbfs" || true)"
  if   [ -z "$line" ];                              then echo ABSENT
  elif [[ "$line" == *"mounted by $SMBG_OWNER"* ]]; then echo HEALTHY
  else                                                   echo FOREIGN
  fi
}

# ── 서브커맨드 출력 정리 ──────────────────────────────────────────────────
# 서브커맨드의 stdout/stderr를 로그에 그대로 흘리면 태그 없는 원문이 태그 줄 사이에
# 끼어들어, 예상된 실패(폴백 유발)와 진짜 실패를 구분할 수 없게 된다 — 08-08 시나리오 A에서
# "umount 실패 → 성공 → ls 실패 → 교정 완료" 가 모순처럼 읽힌 원인.
# 원문은 버리지 않되 한 줄로 눌러 담아 log()의 태그 안에 넣는다.
smbg_oneline() {
  printf '%s' "$1" | tr -s ' \t\n' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}
