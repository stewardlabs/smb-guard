#!/bin/bash
# host/install.sh — 호스트(macOS) 측 배치.  sudo ./host/install.sh [옵션]
#
# 권한이 중요하다. 이 체계의 지배적 실패 모드가 "권한이 틀리면 조용히 무시된다"이기
# 때문에, 배치를 손으로 하지 않고 스크립트로 한다:
#   · LaunchDaemon plist 가 root:wheel 644 가 아니면 launchd 가 로드를 거부한다.
#   · /usr/local/sbin 의 스크립트에 다른 사용자 쓰기 권한이 있으면 root 권한 상승
#     취약점이 된다.
#   · /etc/newsyslog.d/*.conf 도 root:wheel 644 가 아니면 newsyslog 가 **말없이**
#     무시한다 — 로그가 무한 증식하는데 아무 증상이 없다.
#
# 멱등하다. 재실행하면 bootout → 재배치 → bootstrap 이 다시 수행된다.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: sudo ./host/install.sh [--config <경로>] [--dry-run]

  --config <경로>  설정 파일 (기본: 레포 루트의 smb-guard.conf,
                   없으면 이미 배치된 /usr/local/etc/smb-guard.conf)
  --dry-run        배치하지 않고 계획만 출력한다. root 가 아니어도 된다.
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
        *) echo "알 수 없는 옵션: $1" >&2; usage ;;
    esac
done

DEST_CONF="/usr/local/etc/smb-guard.conf"
if [ -z "$CONF" ]; then
    if   [ -r "$ROOT/smb-guard.conf" ]; then CONF="$ROOT/smb-guard.conf"
    elif [ -r "$DEST_CONF" ];           then CONF="$DEST_CONF"
    else
        echo "설정 파일이 없습니다. smb-guard.conf.example 을 복사해 값을 채우세요:" >&2
        echo "  cp $ROOT/smb-guard.conf.example $ROOT/smb-guard.conf" >&2
        exit 78   # EX_CONFIG
    fi
fi
[ -r "$CONF" ] || { echo "설정 파일을 읽을 수 없습니다: $CONF" >&2; exit 78; }

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "sudo ./host/install.sh 로 실행하세요 (계획만 보려면 --dry-run)" >&2
    exit 1
fi

# ── 설정 로드·검증 ─────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_OWNER:?$CONF: SMBG_OWNER 미설정}"
: "${SMBG_MP:?$CONF: SMBG_MP 미설정}"
: "${SMBG_HOST:?$CONF: SMBG_HOST 미설정}"
: "${SMBG_SHARE:?$CONF: SMBG_SHARE 미설정}"
: "${SMBG_SHARE_SUBPATH:=}"
: "${SMBG_LABEL_PREFIX:=io.stewardlabs}"
: "${SMBG_LOGDIR:=/var/log/smb}"

# 배치 계획 출력용. 런타임 조립은 lib/common.sh 가 한다 — 정의를 두 곳에 두지 않도록
# 여기서는 표시만 하고, 스크립트들은 common.sh 의 값을 쓴다.
SMBG_SHARE_PATH="$SMBG_SHARE${SMBG_SHARE_SUBPATH:+/$SMBG_SHARE_SUBPATH}"

id -u "$SMBG_OWNER" >/dev/null 2>&1 || {
    echo "계정 '$SMBG_OWNER' 이(가) 존재하지 않습니다 ($CONF)" >&2; exit 78; }

GUARD_LABEL="$SMBG_LABEL_PREFIX.smb-guard"
WATCH_LABEL="$SMBG_LABEL_PREFIX.sleepwatcher"
GUARD_PLIST="/Library/LaunchDaemons/$GUARD_LABEL.plist"
WATCH_PLIST="/Library/LaunchDaemons/$WATCH_LABEL.plist"
NEWSYSLOG="/etc/newsyslog.d/$SMBG_LABEL_PREFIX.smb.conf"

# ── sleepwatcher 바이너리 탐지 ─────────────────────────────────────────────
# Homebrew 는 sbin 에 설치하는데 그 경로가 PATH 에 없는 경우가 흔하다. 아키텍처별
# 접두사가 다르므로 두 곳을 직접 본 뒤 PATH 를 마지막 수단으로 쓴다.
SW=""
for c in /opt/homebrew/sbin/sleepwatcher /usr/local/sbin/sleepwatcher; do
    [ -x "$c" ] && { SW="$c"; break; }
done
[ -n "$SW" ] || SW="$(command -v sleepwatcher 2>/dev/null || true)"
if [ -z "$SW" ]; then
    echo "!! sleepwatcher 를 찾지 못했습니다. 설치 후 다시 실행하세요:" >&2
    echo "     brew install sleepwatcher" >&2
    echo "   (brew 서비스로 등록하지는 마세요 — 이 스크립트가 자체 LaunchDaemon 으로" >&2
    echo "    배치합니다. 이유는 docs/decisions.md 참조)" >&2
    exit 1
fi

# ── 렌더링 ─────────────────────────────────────────────────────────────────
# 템플릿의 @PLACEHOLDER@ 를 설정값으로 채운다. 값에 '|' 가 들어가면 sed 구분자와
# 충돌하므로 미리 막는다 — 경로·라벨에 쓰일 문자가 아니다.
case "$SMBG_LABEL_PREFIX$SMBG_LOGDIR$SW" in
    *"|"*) echo "설정값에 '|' 문자를 쓸 수 없습니다" >&2; exit 78 ;;
esac

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smb-guard-render.XXXXXX")"
cleanup_stage() { rm -rf "$STAGE"; }
trap cleanup_stage EXIT

render() {   # render <템플릿> <출력경로>
    sed -e "s|@LABEL_PREFIX@|$SMBG_LABEL_PREFIX|g" \
        -e "s|@LOGDIR@|$SMBG_LOGDIR|g" \
        -e "s|@SLEEPWATCHER_BIN@|$SW|g" \
        "$1" > "$2"
}

render "$HERE/LaunchDaemons/smb-guard.plist.in"    "$STAGE/guard.plist"
render "$HERE/LaunchDaemons/sleepwatcher.plist.in" "$STAGE/watch.plist"
render "$HERE/newsyslog.d/smb.conf.in"             "$STAGE/newsyslog.conf"

# 렌더링 결과에 미치환 플레이스홀더가 남으면 그대로 배치되어 조용히 오작동한다.
if grep -l '@[A-Z_]\{3,\}@' "$STAGE"/* >/dev/null 2>&1; then
    echo "!! 치환되지 않은 플레이스홀더가 남았습니다:" >&2
    grep -n '@[A-Z_]\{3,\}@' "$STAGE"/* >&2
    exit 1
fi

# ── 계획 출력 ──────────────────────────────────────────────────────────────
cat <<PLAN
== 배치 계획 ==
  설정        $CONF
              → $DEST_CONF                                   (root:wheel 644)
  라이브러리  host/lib/common.sh
              → /usr/local/lib/smb-guard/common.sh            (root:wheel 644, 실행비트 없음)
  실행 파일   host/sbin/{smb-guard,smb-guard-sleep,smb-guard-wakeup,smbfix}
              → /usr/local/sbin/                              (root:wheel 755)
  LaunchDaemon
              → $GUARD_PLIST   (root:wheel 644)
              → $WATCH_PLIST   (root:wheel 644)
  로그 회전   → $NEWSYSLOG   (root:wheel 644)
  로그 디렉터리 $SMBG_LOGDIR                                   (root:wheel 755)

  소유자      $SMBG_OWNER (uid $(id -u "$SMBG_OWNER"))
  마운트 지점 $SMBG_MP
  게스트      $SMBG_HOST : $SMBG_SHARE_PATH
  sleepwatcher $SW
PLAN

if [ "$DRY" -eq 1 ]; then
    echo
    echo "(--dry-run — 아무것도 배치하지 않았습니다)"
    exit 0
fi

# set -e 로 중단될 때 침묵하지 않도록. 부분 배치 상태는 반드시 알려야 한다.
trap 'rc=$?; cleanup_stage; if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "!! 설치가 중단되었습니다 (exit=$rc). 부분 배치 상태일 수 있습니다." >&2
    echo "   현재 상태:  sudo launchctl print system/'"$GUARD_LABEL"'" >&2
    echo "               ls -l /usr/local/sbin/smb-guard*" >&2
fi' EXIT

echo
echo "== 1. 기존 잡 정지 =="
launchctl bootout "system/$WATCH_LABEL" 2>/dev/null || true
launchctl bootout "system/$GUARD_LABEL" 2>/dev/null || true
# brew 가 만든 사용자 도메인 에이전트가 남아 있으면 훅이 중복 발화한다.
OWNER_UID="$(id -u "$SMBG_OWNER")"
launchctl bootout "gui/$OWNER_UID/homebrew.mxcl.sleepwatcher" 2>/dev/null || true
sudo -u "$SMBG_OWNER" -H brew services stop sleepwatcher 2>/dev/null || true

echo "== 2. 디렉터리 =="
install -d -o root -g wheel -m 755 /usr/local/sbin
install -d -o root -g wheel -m 755 /usr/local/etc
install -d -o root -g wheel -m 755 /usr/local/lib/smb-guard
install -d -o root -g wheel -m 755 "$SMBG_LOGDIR"

echo "== 3. 설정 =="
# 심볼릭 링크가 아니라 복사다. 이 체계가 복구하는 대상이 워크스페이스 마운트이므로,
# 설정이 그 마운트 안을 가리키면 마운트가 끊긴 순간 복구 수단이 함께 사라진다.
if [ "$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")" != "$DEST_CONF" ]; then
    install -o root -g wheel -m 644 "$CONF" "$DEST_CONF"
    echo "   $DEST_CONF"
else
    echo "   $DEST_CONF (이미 배치된 파일을 사용 — 변경 없음)"
fi

echo "== 4. 라이브러리 (실행 비트 없음 — source 전용) =="
install -o root -g wheel -m 644 "$HERE/lib/common.sh" /usr/local/lib/smb-guard/common.sh

echo "== 5. 실행 파일 =="
for f in smb-guard smb-guard-sleep smb-guard-wakeup smbfix; do
    install -o root -g wheel -m 755 "$HERE/sbin/$f" "/usr/local/sbin/$f"
    echo "   /usr/local/sbin/$f"
done

echo "== 6. plist =="
install -o root -g wheel -m 644 "$STAGE/guard.plist" "$GUARD_PLIST"
install -o root -g wheel -m 644 "$STAGE/watch.plist" "$WATCH_PLIST"
plutil -lint "$GUARD_PLIST"
plutil -lint "$WATCH_PLIST"

echo "== 7. 로그 회전 =="
install -o root -g wheel -m 644 "$STAGE/newsyslog.conf" "$NEWSYSLOG"

echo "== 8. 구문 검사 =="
for f in /usr/local/sbin/smb-guard /usr/local/sbin/smb-guard-sleep \
         /usr/local/sbin/smb-guard-wakeup /usr/local/sbin/smbfix; do
    bash -n "$f" && echo "   $f OK"
done

echo "== 9. 등록 =="
launchctl bootstrap system "$GUARD_PLIST"
launchctl bootstrap system "$WATCH_PLIST"

cat <<DONE

완료. 확인:
  launchctl print system/$GUARD_LABEL | head -20
  launchctl print system/$WATCH_LABEL | head -20
  smb-guard --state
  sudo newsyslog -nv | grep $SMBG_LOGDIR

최우선 검증 — root 컨텍스트에서 게스트 ssh 가 되는지 (실패하면 시계 교정이 통째로 죽는다):
  sudo -u $SMBG_OWNER -H ssh -o BatchMode=yes -o ConnectTimeout=3 $SMBG_HOST 'date +%s'
DONE

exit 0
