#!/bin/bash
# probe-layer4b.sh v2 — 층 4-b 원인 판별 일회용 진단.  sudo ./probe-layer4b.sh
#
# 배경: 데몬 컨텍스트(smb-guard watch)에서만 `umount -f` 가 EPERM이었다(08-08 12:19, 1회).
# 남은 가설:
#   (a) 실행 컨텍스트 — launchd system 도메인 vs 로그인 세션
#   (c) 타이밍       — 마운트 직후(이벤트 발생 순간)에는 언마운트가 거부된다
# 기각: TCC/FDA(관측 5), 마운트 소유자(08-08 Terminal.app에서 root 마운트 umount 성공)
#
# v2 변경 — 08-08 1차 실행에서 드러난 문제:
#   · **FOREIGN 생성은 경합이다.** 언마운트 후 빈 창에서 root의 ls 와 sanha 프로세스가
#     경쟁하며, sanha가 이기면 HEALTHY가 되어 측정이 불가능하다. 재시도를 넣는다.
#   · 가설 (c) 검증용으로 "즉시 umount" 라운드를 추가한다.
set -u

PLIST=/Library/LaunchDaemons/io.stewardlabs.smb-guard.plist
LABEL=system/io.stewardlabs.smb-guard
MP=/opt/stewardlabs
OWNER=sanha
RETRIES=5

[ "$(id -u)" -eq 0 ] || { echo "sudo ./probe-layer4b.sh 로 실행하세요" >&2; exit 1; }

state() {
    local line
    line="$(mount | grep -F " on $MP (smbfs" || true)"
    if   [ -z "$line" ];                        then echo ABSENT
    elif [[ "$line" == *"mounted by $OWNER"* ]]; then echo HEALTHY
    else                                             echo FOREIGN
    fi
}

restored=0
restore() {
    [ "$restored" -eq 1 ] && return 0
    restored=1
    echo
    echo "== 복구 =="
    /usr/local/sbin/smb-guard --remount >/dev/null 2>&1 || true
    echo "-- 마운트: state=$(state)"
    launchctl bootstrap system "$PLIST" 2>/dev/null || true
    if launchctl print "$LABEL" >/dev/null 2>&1; then
        echo "-- guard 데몬: OK"
    else
        echo "-- guard 데몬: !! 재적재 실패. 수동 실행 필요:"
        echo "     sudo launchctl bootstrap system $PLIST"
    fi
}
trap restore EXIT INT TERM

# FOREIGN 마운트를 만든다. 경합에 져서 HEALTHY가 되면 재시도. 0=성공 1=실패
make_foreign() {
    local i s
    for i in $(seq 1 "$RETRIES"); do
        diskutil unmount force "$MP" >/dev/null 2>&1 || umount -f "$MP" >/dev/null 2>&1 || true
        sleep 1
        if [ "$(state)" != "ABSENT" ]; then
            echo "   [$i] 언마운트 실패 (state=$(state))"
            continue
        fi
        /bin/ls "$MP" >/dev/null 2>&1 || true     # root 컨텍스트 디렉터리 open
        sleep 2
        s="$(state)"
        if [ "$s" = "FOREIGN" ]; then
            [ "$i" -gt 1 ] && echo "   [$i] FOREIGN 생성 성공"
            return 0
        fi
        echo "   [$i] 경합 패배 — sanha 프로세스가 먼저 트리거함 (state=$s), 재시도"
    done
    return 1
}

echo "== 사전 상태 =="
echo "   state=$(state)"
mount | grep -F " on $MP " | sed 's/^/   /'

echo
echo "== 1. watch 데몬 정지 (측정 중 자동 교정 방지) =="
launchctl bootout "$LABEL" 2>/dev/null || true
sleep 1
if launchctl print "$LABEL" >/dev/null 2>&1; then
    echo "   !! 정지 실패 — 중단합니다"; exit 1
fi
echo "   정지 확인"

# ── 라운드 1: 지연 후 umount — 가설 (a) 검증 ────────────────────────────────
echo
echo "== 2. 라운드 1 — FOREIGN 생성 후 3초 지연, umount -f =="
if ! make_foreign; then
    echo "   !! ${RETRIES}회 모두 경합 패배 — FOREIGN을 만들 수 없습니다."
    echo "      /opt/stewardlabs 를 만지는 sanha 프로세스가 있습니다."
    echo "      에디터·LSP·파일 감시기·다른 셸의 cwd 를 정리한 뒤 다시 실행하세요."
    echo "      (이 경합 자체가 층 4 하이재킹이 간헐적인 이유입니다 — 정상 현상)"
    exit 1
fi
mount | grep -F " on $MP (smbfs" | sed 's/^/   /'
sleep 3
out1="$(umount -f "$MP" 2>&1)"; rc1=$?
echo "   지연 후 umount -f: exit=$rc1${out1:+  출력: $out1}"

# ── 라운드 2: 즉시 umount — 가설 (c) 검증 ───────────────────────────────────
echo
echo "== 3. 라운드 2 — FOREIGN 생성 직후 지연 없이 umount -f =="
echo "   (데몬의 StartOnMount 발화 시점을 근사한다. 셸 경유라 완전한 재현은 아니다)"
rc2=""
if make_foreign; then
    out2="$(umount -f "$MP" 2>&1)"; rc2=$?
    echo "   즉시 umount -f: exit=$rc2${out2:+  출력: $out2}"
else
    echo "   !! FOREIGN 생성 실패 — 라운드 2 생략"
fi

# ── 판정 ────────────────────────────────────────────────────────────────────
echo
echo "== 판정 =="
if [ "$rc1" -ne 0 ]; then
    echo "   라운드 1 실패 → 로그인 세션에서도 root 마운트 언마운트 불가."
    echo "   가설 (b) 마운트 소유자가 되살아난다. 문서 재검토 필요."
elif [ -n "$rc2" ] && [ "$rc2" -ne 0 ]; then
    cat <<'MSG'
   라운드 1 성공 / 라운드 2 실패 → **가설 (c) 타이밍 지지.**
   마운트 직후에는 언마운트가 거부된다. 데몬이 StartOnMount로 마운트 발생 순간에
   발화하므로 항상 이 조건에 걸린 것이다. 실행 컨텍스트와 무관하다.
   → 문서 §1 층 4-b 를 "타이밍" 으로 확정하고, diskutil 우선 정책 근거를 갱신할 것.
MSG
elif [ -n "$rc2" ]; then
    cat <<'MSG'
   라운드 1·2 모두 성공 → 타이밍도 아니다. 남는 것은 (a) 실행 컨텍스트뿐이며,
   셸에서는 재현할 수 없다. 추가 규명은 일회용 LaunchDaemon이 필요하다.

   **여기서 조사를 종료할 것을 권한다.** 기능 영향이 없고(diskutil이 1단계),
   남은 가설의 검증 비용이 얻는 진단 가치를 넘는다. 미결로 기록하고 재발 시 재개.
MSG
else
    echo "   라운드 2 미측정 — 판정 보류."
fi
echo
echo "   이 출력을 핸드오프 문서 §1 부기의 관측표에 추가하세요."
exit 0
