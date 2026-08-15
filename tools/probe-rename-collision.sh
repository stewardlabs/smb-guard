#!/bin/bash
# probe-rename-collision.sh — 공유 루트 이름 충돌(층 6) 판별·회귀 확인.
#
# 배경: Samba 는 파일 삭제 시 delete_all_streams() 로 대체 데이터 스트림을 지우는데,
#       그 경로가 basename 만 써서 **공유 루트 기준으로** 해석한다. 공유 루트에 같은
#       이름이 있으면 엉뚱한 객체를 열어 실패하고, 클라이언트에는 ENOENT 로 올라온다.
#       → 공유 루트의 엔트리명과 같은 basename 을 가진 기존 파일은 트리 어디에서도
#         덮어쓰거나 지울 수 없다. `.git/config` 가 걸려 git 이 깨진다.
#       상세는 docs/failure-model.md 층 6.
#
# 이 도구가 하는 일: 공유 루트의 엔트리 이름을 게스트에서 받아, 그 이름들로 마운트 위에서
#       "덮어쓰기 rename" 을 실제로 시도한다. 실패한 이름이 곧 **오염된 basename 집합**이다.
#
# 판정 (종료 코드):
#   0 = 정상. 실패가 없거나, 실패한 것이 **기대된 잔여**뿐이다. 공유 루트를 워크스페이스
#       상위로 올린 배치에서는 워크스페이스 자신의 이름이 반드시 남는다 — 그것은 공유
#       루트의 정당한 엔트리이기 때문이다
#   1 = 이상. 그 밖의 이름이 오염됐다. 공유 루트에 무언가 생겼거나(상향 배치), 애초에
#       워크스페이스를 직접 내보내고 있다(미조치 — 루트의 거의 모든 이름이 실패한다)
#
#   기대된 잔여를 오염으로 보고하지 않는 이유: **정상 상태가 매번 경보를 울리면 진짜
#   이상도 함께 무시된다** (설계 원칙 23).
#
# 읽는 법: 실패가 0건이면 스트림이 없거나(서버가 fruit 없이 동작) 이미 해결된 것이다.
#          **대조군(control) 이 성공해야 측정이 유효하다** — 대조군까지 실패하면 마운트
#          자체나 권한 문제이지 이 결함이 아니다 (원칙 25: 조용함은 두 가지를 뜻한다).
#
# 아무것도 지우지 않는다 — 자기가 만든 임시 디렉터리 안에서만 동작하고 EXIT 에서 회수한다.
# root 불필요. 소유자 계정으로 실행한다.
#
# usage: ./probe-rename-collision.sh [--config <경로>]

set -u

CONF="${SMBG_CONF:-/usr/local/etc/smb-guard.conf}"
[ "${1:-}" = "--config" ] && { CONF="${2:?--config 에 경로가 필요합니다}"; shift 2; }

[ -r "$CONF" ] || { echo "설정을 읽을 수 없습니다: $CONF" >&2; exit 78; }
# shellcheck source=/dev/null
. "$CONF"
: "${SMBG_MP:?$CONF: SMBG_MP 미설정}"
: "${SMBG_HOST:?$CONF: SMBG_HOST 미설정}"
: "${SMBG_GUEST_ROOT:=$SMBG_MP}"
: "${SMBG_EXPORT_ROOT:=$SMBG_GUEST_ROOT}"

# 기대된 잔여 = 공유 루트 아래에서 클라이언트가 마운트하는 이름(= 워크스페이스 자신).
# 게스트측 install 과 같은 규칙으로 정한다 — SMBG_SHARE_SUBPATH 가 정본이고, 없으면
# 워크스페이스 이름을 쓴다. 공유 루트를 올리지 않은 배치에서는 기대된 잔여가 없다.
EXPECTED=""
if [ "$SMBG_EXPORT_ROOT" != "$SMBG_GUEST_ROOT" ]; then
    EXPECTED="${SMBG_SHARE_SUBPATH:-$(basename "$SMBG_GUEST_ROOT")}"
fi

mount | grep -q " on $SMBG_MP (smbfs" || {
    echo "$SMBG_MP 가 smbfs 로 마운트되어 있지 않습니다 — 먼저 마운트하세요" >&2; exit 1; }

# 공유 루트의 엔트리 목록은 서버만 안다. 마운트가 하위 디렉터리를 가리키면 클라이언트에서는
# 보이지 않으므로 ssh 로 받아온다.
names="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" \
         "ls -A -- '$SMBG_EXPORT_ROOT'" 2>/dev/null)"
[ -n "$names" ] || { echo "공유 루트 목록을 받지 못했습니다: $SMBG_HOST:$SMBG_EXPORT_ROOT" >&2; exit 1; }

WORK_LEAF=".probe-rename-collision.$$"
WORK="$SMBG_MP/$WORK_LEAF"
mkdir -p "$WORK" || { echo "작업 디렉터리를 만들 수 없습니다: $WORK" >&2; exit 1; }

# **정리 자체가 이 결함에 걸린다.** 회수 대상에 오염된 basename 이 들어 있으므로 맥에서
# rm -rf 하면 unlink 가 ENOENT 로 실패하고 디렉터리가 그대로 남는다(실측). 게스트는 로컬
# 파일시스템이라 영향이 없으니 그쪽에서 지운다 — 진단 도구가 잔재를 남기면 안 된다.
cleanup() {
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SMBG_HOST" \
           "rm -rf -- '$SMBG_GUEST_ROOT/$WORK_LEAF'" 2>/dev/null; then
        return 0
    fi
    rm -rf "$WORK" 2>/dev/null
    if [ -d "$WORK" ]; then
        echo "!! 임시 디렉터리를 회수하지 못했습니다: $WORK" >&2
        echo "   게스트에서 지우세요: ssh $SMBG_HOST \"rm -rf '$SMBG_GUEST_ROOT/$WORK_LEAF'\"" >&2
    fi
    return 0
}
trap cleanup EXIT

# 대조군: 공유 루트에 없는 것이 확실한 이름. 이것이 실패하면 측정 자체가 무효다.
CONTROL="__probe_control_$$"

# 한 이름에 대해 "대상이 이미 있는 상태에서 덮어쓰기 rename" 을 시도한다.
#   0 = 성공(정상)  /  1 = 실패(오염된 이름)
try_name() {
    local name="$1" d
    d="$WORK/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
    mkdir -p "$d" 2>/dev/null || return 2
    : > "$d/$name"   || return 2          # 대상을 먼저 만든다 (존재해야 재현된다)
    : > "$d/src"     || return 2
    mv -f "$d/src" "$d/$name" 2>/dev/null && return 0
    return 1
}

echo "공유 루트 : $SMBG_HOST:$SMBG_EXPORT_ROOT"
echo "마운트    : $SMBG_MP"
echo

if ! try_name "$CONTROL"; then
    echo "!! 대조군($CONTROL)이 실패했습니다 — 마운트나 권한 문제입니다." >&2
    echo "   이 결함(층 6)의 판정이 아닙니다. 측정 무효." >&2
    exit 1
fi
echo "대조군 OK — 측정 유효"
echo

unexpected=""; n_ok=0; n_fail=0; n_bad=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if try_name "$name"; then
        n_ok=$((n_ok + 1))
        continue
    fi
    n_fail=$((n_fail + 1))
    if [ -n "$EXPECTED" ] && [ "$name" = "$EXPECTED" ]; then
        printf '  FAIL  %-24s (기대된 잔여 — 워크스페이스 자신)\n' "$name"
    else
        n_bad=$((n_bad + 1)); unexpected="$unexpected $name"
        printf '  FAIL  %s\n' "$name"
    fi
done <<EOF
$names
EOF

echo
# 변수 뒤에 한글이 바로 붙으면 **반드시 중괄호를 쓴다.** macOS 의 bash 3.2 는 UTF-8
# 로케일에서 뒤따르는 멀티바이트 문자의 첫 바이트를 변수명에 포함시켜, `${n_ok}` 가
# 아니라 `n_ok` + 0xEA 라는 이름을 찾는다. set -u 와 만나면 unbound variable 로 죽는다.
# LC_ALL=C 에서는 재현되지 않아 로케일이 다른 환경에서만 터진다 — 실제로 그렇게 샜다.
echo "정상 ${n_ok}건 / 실패 ${n_fail}건  (기대된 잔여를 뺀 오염 ${n_bad}건)"

if [ "$n_bad" -eq 0 ]; then
    if [ "$n_fail" -eq 0 ]; then
        echo "→ 정상. 오염된 이름이 없습니다 — 공유 루트에 겹치는 이름 자체가 없습니다."
    else
        echo "→ 정상. 실패한 것은 기대된 잔여 '${EXPECTED}' 뿐입니다."
        echo "   공유 루트 상향 배치가 유지되고 있습니다 (failure-model.md 층 6)."
    fi
    exit 0
fi

echo "→ 예기치 않게 오염된 basename:${unexpected}"
echo "   이 이름을 가진 기존 파일은 트리 어디에서도 덮어쓰거나 지울 수 없습니다."
if [ "$SMBG_EXPORT_ROOT" = "$SMBG_GUEST_ROOT" ]; then
    echo "   공유 루트가 워크스페이스 자신입니다 — 상위로 올리는 것이 처방입니다"
    echo "   (docs/decisions.md '공유 루트를 워크스페이스 자신이 아니라 그 상위에 둔다')."
else
    echo "   공유 루트는 이미 상위입니다. 여기에 워크스페이스 외의 것이 생겼는지 확인하세요"
    echo "   (docs/open-questions.md '공유 루트에 워크스페이스 외의 이름이 생기는 것')."
fi
exit 1
