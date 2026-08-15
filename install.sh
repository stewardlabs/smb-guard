#!/bin/bash
# install.sh — 호스트·게스트 배치 오케스트레이터.  ./install.sh [옵션]
#
# **일반 사용자로 실행한다 (sudo 를 붙이지 않는다).** 권한 승격은 각 단계에서 따로
# 일어난다: 호스트는 sudo, 게스트는 `ssh -t … sudo`. 이 스크립트 전체를 root 로 돌리면
# ssh 가 root 의 ~/.ssh 를 보게 되어 게스트 별칭·키가 해석되지 않는다. 같은 이유로
# 웨이크 훅도 root 컨텍스트에서 `sudo -u <소유자> -H ssh` 로 자격을 되돌린다.
#
#   ./install.sh              설정 확인 → 호스트 → 게스트
#   ./install.sh --host       호스트만
#   ./install.sh --guest      게스트만
#   ./install.sh --dry-run    배치 없이 양쪽 계획만 출력
#
# 게스트 배치는 Samba·systemd 를 건드리므로 실패 시 그 자리에서 멈추고 부분 적용
# 사실을 알린다. 호스트가 먼저인 이유는 되돌리기가 더 쉽기 때문이다.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: ./install.sh [--host｜--guest] [--config <경로>] [--samba] [--dry-run]

  (옵션 없음)      호스트 → 게스트 순으로 배치
  --host           호스트(macOS)만
  --guest          게스트(Linux)만 — ssh 로 전송·실행한다
  --config <경로>  설정 파일 (기본: 이 디렉터리의 smb-guard.conf)
  --samba          게스트의 /etc/samba/smb.conf 까지 배치 (기본은 출력만)
  --dry-run        배치하지 않고 계획만 출력
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
        *) echo "알 수 없는 옵션: $1" >&2; usage ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "!! 이 스크립트는 일반 사용자로 실행하세요 (sudo 없이)." >&2
    echo "   root 로 돌리면 게스트 ssh 가 root 의 ~/.ssh 를 보게 되어 실패합니다." >&2
    exit 1
fi

[ -n "$CONF" ] || CONF="$ROOT/smb-guard.conf"
if [ ! -r "$CONF" ]; then
    cat >&2 <<EOF
설정 파일이 없습니다: $CONF

  cp $ROOT/smb-guard.conf.example $ROOT/smb-guard.conf
  \$EDITOR $ROOT/smb-guard.conf

계정·마운트 지점·게스트 별칭·공유명 네 가지는 반드시 채워야 합니다.
EOF
    exit 78
fi

# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_HOST:?$CONF: SMBG_HOST 미설정}"

DRYOPT=""
[ "$DRY" -eq 1 ] && DRYOPT="--dry-run"

# ── 호스트 ─────────────────────────────────────────────────────────────────
if [ "$DO_HOST" -eq 1 ]; then
    echo "########## 호스트 (macOS) ##########"
    if [ "$DRY" -eq 1 ]; then
        "$ROOT/host/install.sh" --config "$CONF" --dry-run
    else
        sudo "$ROOT/host/install.sh" --config "$CONF"
    fi
    echo
fi

# ── 게스트 ─────────────────────────────────────────────────────────────────
if [ "$DO_GUEST" -eq 1 ]; then
    echo "########## 게스트 ($SMBG_HOST) ##########"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" true 2>/dev/null; then
        echo "!! ssh $SMBG_HOST 에 접속할 수 없습니다." >&2
        echo "   ~/.ssh/config 의 별칭과 게스트 상태를 확인하세요." >&2
        echo "   (호스트만 배치하려면 --host)" >&2
        exit 1
    fi

    # 실배치에는 원격 sudo 가 필요하고, sudo 는 비밀번호 입력을 위해 TTY 를 요구한다.
    # 여기서 미리 막지 않으면 파일을 다 전송한 뒤에야 실패한다.
    if [ "$DRY" -eq 0 ] && [ ! -t 0 ]; then
        echo "!! 게스트 배치에는 터미널이 필요합니다 (원격 sudo 비밀번호 입력)." >&2
        echo "   터미널에서 직접 실행하거나, 게스트에 로그인해 아래를 실행하세요:" >&2
        echo "     sudo ./guest/install.sh --config <설정파일>" >&2
        exit 1
    fi

    # 전송과 실행을 나눈다: `ssh -t` 는 stdin 을 TTY 로 잡으므로 tar 스트림과 공존할 수
    # 없다. 먼저 TTY 없이 전송하고, 그 다음 TTY 를 할당해 sudo 프롬프트를 받는다.
    STAGE="/tmp/smb-guard-install.$$"
    echo "-- 전송: $STAGE"
    ssh "$SMBG_HOST" "mkdir -p '$STAGE'"
    # macOS 의 확장 속성(provenance/quarantine)을 빼고 보낸다. 넣어 보내면 GNU tar 가
    # 항목마다 경고를 뱉어 실제 오류가 묻힌다. COPYFILE_DISABLE 은 ._* 동봉을 막는다.
    COPYFILE_DISABLE=1 tar --no-xattrs -C "$ROOT" -cf - guest \
        | ssh "$SMBG_HOST" "tar -C '$STAGE' -xf -"
    # shellcheck disable=SC2002
    cat "$CONF" | ssh "$SMBG_HOST" "cat > '$STAGE/smb-guard.conf'"

    # 스테이징 디렉터리는 성공·실패와 무관하게 지우고, 원격 종료 코드를 그대로 전달한다.
    set +e
    if [ "$DRY" -eq 1 ]; then
        # 계획만 출력하므로 root 가 필요 없다 → sudo 도 TTY 도 붙이지 않는다.
        ssh "$SMBG_HOST" \
            "'$STAGE/guest/install.sh' --config '$STAGE/smb-guard.conf' $SAMBA --dry-run; \
             rc=\$?; rm -rf '$STAGE'; exit \$rc"
    else
        echo "-- 실행 (게스트의 sudo 비밀번호를 물을 수 있습니다)"
        # -t 로 TTY 를 할당해야 원격 sudo 의 비밀번호 프롬프트가 이 터미널에 뜬다.
        ssh -t "$SMBG_HOST" \
            "sudo '$STAGE/guest/install.sh' --config '$STAGE/smb-guard.conf' $SAMBA; \
             rc=\$?; rm -rf '$STAGE'; exit \$rc"
    fi
    grc=$?
    set -e
    if [ "$grc" -ne 0 ]; then
        echo "!! 게스트 배치 실패 (exit=$grc)." >&2
        [ "$DO_HOST" -eq 1 ] && echo "   호스트 배치는 이미 완료된 상태입니다." >&2
        exit "$grc"
    fi
fi

echo
if [ "$DRY" -eq 1 ]; then
    echo "(--dry-run — 아무것도 배치하지 않았습니다)"
else
    echo "배치 완료. 검증 절차는 docs/install.md 를 따르세요."
fi
exit 0
