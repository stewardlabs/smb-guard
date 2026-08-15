#!/bin/bash
# guest/install.sh — 게스트(Linux, Samba 서버) 측 배치.
#
#   게스트에서 직접:  sudo ./guest/install.sh [옵션]
#   호스트에서 원격:  ./install.sh --guest      (최상위 오케스트레이터가 전송·실행한다)
#
# 배치 대상:
#   /usr/local/sbin/clockfix              resume 직후 시계 step (호스트 훅이 ssh 로 호출)
#   /usr/local/sbin/mac-cruft-cleanup     macOS 잔재 사후 정리
#   /etc/systemd/system/mac-cruft-cleanup.{service,timer}
#   /etc/sudoers.d/clockfix               호스트 훅이 비밀번호 없이 clockfix 를 부르기 위함
#   /etc/smb-guard.conf                   설정
#
# Samba 설정은 **기본적으로 배치하지 않는다** (--samba 로 명시). 기존 smb.conf 를
# 통째로 덮으면 이 공유와 무관한 설정이 사라지기 때문이다. 기본 동작은 치환 결과를
# 출력해 사람이 병합하게 하는 것이다.
#
# 멱등하다.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: sudo ./guest/install.sh [--config <경로>] [--sudo-user <계정>] [--samba] [--dry-run]

  --config <경로>     설정 파일 (기본: 스크립트 상위의 smb-guard.conf,
                      없으면 이미 배치된 /etc/smb-guard.conf)
  --sudo-user <계정>  clockfix NOPASSWD 를 부여할 계정. 호스트 웨이크 훅이 ssh 로
                      로그인하는 그 계정이다. 기본값은 $SUDO_USER.
  --samba             smb.conf 를 배치한다 (기존 파일은 .bak-<타임스탬프> 로 백업).
                      지정하지 않으면 치환 결과를 출력만 한다.
  --dry-run           배치하지 않고 계획만 출력한다.
USAGE
    exit 2
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CONF=""; SUDO_TARGET="${SUDO_USER:-}"; DO_SAMBA=0; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config)    [ $# -ge 2 ] || usage; CONF="$2"; shift 2 ;;
        --sudo-user) [ $# -ge 2 ] || usage; SUDO_TARGET="$2"; shift 2 ;;
        --samba)     DO_SAMBA=1; shift ;;
        --dry-run)   DRY=1; shift ;;
        -h|--help)   usage ;;
        *) echo "알 수 없는 옵션: $1" >&2; usage ;;
    esac
done

DEST_CONF="/etc/smb-guard.conf"
if [ -z "$CONF" ]; then
    if   [ -r "$ROOT/smb-guard.conf" ]; then CONF="$ROOT/smb-guard.conf"
    elif [ -r "$DEST_CONF" ];           then CONF="$DEST_CONF"
    else
        echo "설정 파일이 없습니다. smb-guard.conf.example 을 복사해 값을 채우세요." >&2
        exit 78
    fi
fi
[ -r "$CONF" ] || { echo "설정 파일을 읽을 수 없습니다: $CONF" >&2; exit 78; }

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "sudo ./guest/install.sh 로 실행하세요 (계획만 보려면 --dry-run)" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_GUEST_ROOT:?$CONF: SMBG_GUEST_ROOT 미설정}"
: "${SMBG_SHARE:?$CONF: SMBG_SHARE 미설정}"
: "${SMBG_OWNER:?$CONF: SMBG_OWNER 미설정}"
: "${SMBG_SMB_USER:=$SMBG_OWNER}"

# SMB 로 내보낼 루트. 워크스페이스 자신이 아니라 **그 상위**를 내보내는 것이 기본
# 의도다 — Samba 가 파일 삭제 시 스트림을 지우며 basename 을 공유 루트 기준으로
# 해석하는 결함이 있어, 공유 루트에 있는 이름과 같은 basename 을 가진 파일은
# 트리 어디에서도 덮어쓰거나 지울 수 없게 된다 (docs/failure-model.md).
# 미설정 시 워크스페이스 자신으로 폴백한다 — 기존 배포의 동작이 바뀌지 않는다.
: "${SMBG_EXPORT_ROOT:=$SMBG_GUEST_ROOT}"

case "$SMBG_GUEST_ROOT$SMBG_EXPORT_ROOT$SMBG_SHARE$SMBG_SMB_USER" in
    *"|"*) echo "설정값에 '|' 문자를 쓸 수 없습니다" >&2; exit 78 ;;
esac

# 클라이언트가 마운트할 하위경로. 호스트측 SMBG_SHARE_SUBPATH 와 **같은 값이어야 한다** —
# 맥은 //계정@호스트/<공유명>/<이 값> 을 마운트하므로, 서버에 그 경로가 없으면 마운트가
# 실패한다. 미설정 시 워크스페이스 이름을 기본으로 삼는다.
: "${SMBG_SHARE_SUBPATH:=$(basename "$SMBG_GUEST_ROOT")}"

# 공유 루트를 올렸다면 워크스페이스가 실제로 그 아래 보여야 한다. 이 레포는 fstab 을
# 건드리지 않으므로(autofs 를 건드리지 않는 것과 같은 방침) 확인만 하고 안내한다.
if [ "$SMBG_EXPORT_ROOT" != "$SMBG_GUEST_ROOT" ]; then
    _leaf="$SMBG_EXPORT_ROOT/$SMBG_SHARE_SUBPATH"
    if [ ! -d "$_leaf" ]; then
        echo "!! $_leaf 가 없습니다." >&2
        echo "   SMBG_EXPORT_ROOT 를 쓰려면 워크스페이스가 그 아래에 보여야 합니다:" >&2
        echo "     sudo install -d -o $SMBG_OWNER -g $SMBG_OWNER -m 755 $SMBG_EXPORT_ROOT $_leaf" >&2
        echo "     echo '$SMBG_GUEST_ROOT $_leaf none bind,x-systemd.requires-mounts-for=$SMBG_GUEST_ROOT 0 0' | sudo tee -a /etc/fstab" >&2
        echo "     sudo systemctl daemon-reload && sudo mount $_leaf" >&2
        exit 78
    fi
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smb-guard-render.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

render() {   # render <템플릿> <출력경로>
    sed -e "s|@GUEST_ROOT@|$SMBG_GUEST_ROOT|g" \
        -e "s|@EXPORT_ROOT@|$SMBG_EXPORT_ROOT|g" \
        -e "s|@SHARE@|$SMBG_SHARE|g" \
        -e "s|@SMB_USER@|$SMBG_SMB_USER|g" \
        "$1" > "$2"
}

render "$HERE/systemd/mac-cruft-cleanup.service.in" "$STAGE/cleanup.service"
render "$HERE/samba/smb.conf.in"                    "$STAGE/smb.conf"
cp "$HERE/systemd/mac-cruft-cleanup.timer"          "$STAGE/cleanup.timer"

if grep -n '@[A-Z_]\{3,\}@' "$STAGE"/* >/dev/null 2>&1; then
    echo "!! 치환되지 않은 플레이스홀더가 남았습니다:" >&2
    grep -n '@[A-Z_]\{3,\}@' "$STAGE"/* >&2
    exit 1
fi

cat <<PLAN
== 배치 계획 (게스트) ==
  설정        $CONF → $DEST_CONF                              (root:root 644)
  실행 파일   guest/sbin/{clockfix,mac-cruft-cleanup}
              → /usr/local/sbin/                              (root:root 755)
  systemd     → /etc/systemd/system/mac-cruft-cleanup.service (root:root 644)
              → /etc/systemd/system/mac-cruft-cleanup.timer   (root:root 644)
  sudoers     → /etc/sudoers.d/clockfix                       (root:root 0440)
                ${SUDO_TARGET:-<실행 시 \$SUDO_USER 로 결정>} 에게 clockfix NOPASSWD
  Samba       $( [ "$DO_SAMBA" -eq 1 ] && echo "→ /etc/samba/smb.conf (기존 파일 백업 후 교체)" \
                                       || echo "배치하지 않음 (치환 결과만 출력 — --samba 로 배치)" )

  워크스페이스 $SMBG_GUEST_ROOT                       (잔재 정리: 전체 순회)
  공유 루트   $SMBG_EXPORT_ROOT$( [ "$SMBG_EXPORT_ROOT" = "$SMBG_GUEST_ROOT" ] \
                && echo "  (워크스페이스와 동일 — failure-model.md 층 6 참조)" \
                || echo "  (잔재 정리: 깊이 1)" )
  공유        [$SMBG_SHARE]  valid users = $SMBG_SMB_USER
  마운트 URL  //$SMBG_SMB_USER@${SMBG_HOST:-<호스트>}/$SMBG_SHARE$( [ "$SMBG_EXPORT_ROOT" != "$SMBG_GUEST_ROOT" ] && echo "/$SMBG_SHARE_SUBPATH" )
              (맥의 /etc/auto_smb 가 이 경로와 일치해야 한다)
PLAN

if [ "$DRY" -eq 1 ]; then
    echo; echo "(--dry-run — 아무것도 배치하지 않았습니다)"
    exit 0
fi

if [ ! -d "$SMBG_GUEST_ROOT" ]; then
    echo "!! 워크스페이스 경로가 없습니다: $SMBG_GUEST_ROOT" >&2
    echo "   설정의 SMBG_GUEST_ROOT 를 확인하세요." >&2
    exit 1
fi

trap 'rc=$?; rm -rf "$STAGE"; if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "!! 설치가 중단되었습니다 (exit=$rc). 부분 배치 상태일 수 있습니다." >&2
    echo "   확인:  systemctl status mac-cruft-cleanup.timer; ls -l /usr/local/sbin/clockfix" >&2
fi' EXIT

echo
echo "== 1. 설정 =="
install -o root -g root -m 644 "$CONF" "$DEST_CONF"
echo "   $DEST_CONF"

echo "== 2. 실행 파일 =="
install -d -o root -g root -m 755 /usr/local/sbin
for f in clockfix mac-cruft-cleanup; do
    install -o root -g root -m 755 "$HERE/sbin/$f" "/usr/local/sbin/$f"
    echo "   /usr/local/sbin/$f"
done

echo "== 3. sudoers (clockfix) =="
# 호스트의 웨이크 훅은 비대화형이므로 비밀번호를 입력할 수 없다. 인자 와일드카드는
# epoch 값(정수·소수점 모두)을 받기 위한 것이다.
#
# **0440 이 아니면 sudo 가 거부한다.** visudo -c 로 문법을 검사한 뒤에만 배치한다 —
# sudoers 파손은 sudo 자체를 못 쓰게 만들기 때문에, 먼저 쓰고 나중에 검사하면 늦다.
if [ -z "$SUDO_TARGET" ]; then
    echo "   !! --sudo-user 가 지정되지 않았고 \$SUDO_USER 도 비어 있습니다."
    echo "      clockfix NOPASSWD 규칙을 건너뜁니다 — 웨이크 시 시계 교정이 실패합니다."
    echo "      나중에: echo '<계정> ALL=(root) NOPASSWD: /usr/local/sbin/clockfix *' \\"
    echo "               | sudo tee /etc/sudoers.d/clockfix && sudo chmod 0440 /etc/sudoers.d/clockfix"
else
    printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/clockfix *\n' "$SUDO_TARGET" \
        > "$STAGE/clockfix.sudoers"
    if visudo -c -f "$STAGE/clockfix.sudoers" >/dev/null; then
        install -o root -g root -m 0440 "$STAGE/clockfix.sudoers" /etc/sudoers.d/clockfix
        echo "   /etc/sudoers.d/clockfix  ($SUDO_TARGET)"
    else
        echo "   !! sudoers 문법 검사 실패 — 배치하지 않았습니다" >&2
        exit 1
    fi
fi

echo "== 4. systemd 유닛 =="
install -o root -g root -m 644 "$STAGE/cleanup.service" /etc/systemd/system/mac-cruft-cleanup.service
install -o root -g root -m 644 "$STAGE/cleanup.timer"   /etc/systemd/system/mac-cruft-cleanup.timer
systemctl daemon-reload
systemctl enable --now mac-cruft-cleanup.timer
systemctl list-timers mac-cruft-cleanup.timer --no-pager || true

echo "== 5. 잔재 1회 회수 (멱등) =="
/usr/local/sbin/mac-cruft-cleanup "$SMBG_GUEST_ROOT" || true

echo "== 6. Samba =="
if [ "$DO_SAMBA" -eq 1 ]; then
    if [ -f /etc/samba/smb.conf ]; then
        bak="/etc/samba/smb.conf.bak-$(date +%Y%m%d%H%M%S)"
        cp -a /etc/samba/smb.conf "$bak"
        echo "   기존 설정 백업: $bak"
    fi
    install -o root -g root -m 644 "$STAGE/smb.conf" /etc/samba/smb.conf
    testparm -s >/dev/null
    echo "   testparm OK"
    # 차단(veto)이 남아 있으면 macOS Finder 복사가 -8062 로 전량 실패한다.
    # `grep -i veto` 로 검사하면 안 된다 — fruit:veto_appledouble = no 가 이름 때문에
    # 잡히는데 그 줄은 차단이 아니라 차단 해제이며 반드시 남아 있어야 한다.
    if testparm -s 2>/dev/null | grep -qE '^[[:space:]]*veto files'; then
        echo "   !! veto files 가 남아 있습니다 — Finder 복사가 실패합니다" >&2
        exit 1
    fi
    systemctl restart smbd
    echo "   smbd 재시작 완료"
else
    echo "   배치하지 않았습니다. 아래 내용을 기존 /etc/samba/smb.conf 에 병합하세요"
    echo "   (또는 --samba 로 재실행 — 기존 파일은 백업됩니다):"
    echo "   ---------------------------------------------------------------"
    sed 's/^/   /' "$STAGE/smb.conf"
    echo "   ---------------------------------------------------------------"
fi

cat <<DONE

완료. 확인:
  systemctl list-timers mac-cruft-cleanup.timer     # NEXT 가 채워져야 한다
  journalctl -u mac-cruft-cleanup -n 20             # 정리 이력 (0건이면 조용하다)
  sudo -n /usr/local/sbin/clockfix \$(date +%s)      # NOPASSWD 동작 확인
  testparm -s 2>/dev/null | grep -E '^\s*veto files'   # 0줄이어야 한다

시계: 각성 중 상시 보정은 NTP 데몬의 몫이다. chrony 참조 설정이 guest/chrony/ 에 있으며
      자동 배치하지 않는다 (시스템 시계 정책이라 잘못 건드리면 손해가 크다).
      상세는 docs/install.md 의 '게스트 시계' 절을 볼 것.
DONE

exit 0
