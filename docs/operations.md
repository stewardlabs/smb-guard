# 운영 — 관찰과 진단

## 관찰 항목

정상일 때 **조용한** 항목과, 조용하면 **오히려 이상한** 항목을 구분한다. 침묵이
"무사건"인지 "채널 밖"인지 구분하지 못하는 것이 이 체계에서 가장 흔한 오판이다.

| 항목 | 확인 | 정상 |
|---|---|---|
| 교정 발화 빈도 | `grep '감지' /var/log/smb/smb-guard.log` | **0 에 수렴.** 0이 아니면 만료 외의 언마운트 경로가 있다는 신호 |
| 교정 실패 | 같은 로그의 `교정 실패` | 0건. 나오면 즉시 조사 |
| 유령 잠금 제거 | `grep 'stale lock'` | 0건. 나타나면 인스턴스가 비정상 종료하고 있다 |
| GUI 세션 부재 | `grep 'GUI 세션 없음'` | 로그아웃 상태의 웨이크에서는 정상. **로그인 상태인데 나오면** `launchctl asuser` 경로 문제 |
| 웨이크 후 재접속 지연 | `grep 'mount HEALTHY'` 의 `(ls ok, Ns)` | N 이 한 자리 초 |
| `umount -f 폴백` 출현 | 같은 로그 | **0건.** 나오면 `diskutil` 이 실패했다는 뜻 — 관측된 적 없는 상황 |
| 로그 회전 | `ls -la /var/log/smb/` | `.0.bz2` 세대가 생긴다. 안 생기면 newsyslog 설정 권한 확인 |
| 잔재 유입량 | `journalctl -u mac-cruft-cleanup --since -7d` | 매번 다량이면 클라이언트 억제가 실효 중이지 않다는 신호 (고장은 아니다 — 정리가 받아내고 있다) |
| 타이머 생존 | `systemctl list-timers mac-cruft-cleanup.timer` | `NEXT` 가 채워져 있다 |
| 게스트 시계 | `chronyc tracking` | System time ms 대, Frequency 한 자리 ppm |
| 각성 중 step | `journalctl -u chrony \| grep -i stepped` | **0건.** 찍히면 resume step 이 밀린 것이다 |
| 호스트 시계 건전성 | 월 1회 `sntp time.apple.com` | 수십 ms. 초 단위로 틀어져 있으면 게스트를 틀리게 맞추게 된다 |
| SMB 세션 누수 | 주 1~2회 `sudo smbstatus -b` (게스트) | 세션 수가 단조 증가하지 않는다 |
| 구성 생존 | **OS 메이저 업그레이드 직후** `sudo ./tools/doctor.sh` | 종료 코드 0. 업그레이드는 autofs 3종을 기본값으로 되돌리거나 BTM 승인을 리셋해 잡을 "파일은 있는데 로드 안 됨"으로 만들 수 있다 |

### 이벤트 소스를 봐야 하는 경우

감시 데몬은 **이상 상태에만 로깅한다.** 정상·부재는 침묵하므로, 만료·재활용 같은
이벤트는 자체 로그에 나타나지 않는다. 실제로 이벤트가 5건 발생하는 동안 관찰자가
"아무 일도 없다"고 결론낸 사례가 있다.

만료·재활용의 이벤트 소스는 DiskArbitration 로그다. **수면 구간을 포함해 사후 전수 조회가
가능**하고, 마운트 소유자가 `?owner=UID` 로 직접 기록된다(0 = root, 그 외 = 사용자).

```bash
log show --last 24h \
  --predicate 'process == "diskarbitrationd" AND eventMessage CONTAINS "<공유명>"' \
  --info --style compact | grep -E 'created disk|removed disk'
```

> 이 로그의 **순서를 액면 그대로 읽지 말 것.** DiskArbitration 의 비동기 전달 지연으로
> `created` 가 `removed` 뒤에 기록되는 경우가 있다. owner 와 전후 관계로 재구성한다.

---

## 진단 도구

### 호스트

```bash
sudo ./tools/doctor.sh     # 구성 생존 점검 — 읽기 전용, 한 번에 훑는다
smb-guard --state          # 부작용 없는 상태 조회 (root 불필요)
mount | grep <마운트지점>   # 소유자 판정은 `mounted by` 필드로만
tail -50 /var/log/smb/smb-guard.log
smbfix                     # 자동 복구가 실패했을 때
smbutil statshares -a
```

**`//계정@호스트/공유` 표기는 함정이다** — SMB 인증 계정일 뿐 마운트 소유자가 아니다.

```bash
# 자동 마운트 계층
log show --last 10m --predicate 'process == "automountd" OR process == "mount_smbfs"' --info

# 전원 이벤트 (층 2 판정의 1차 증거)
pmset -g log | grep -E "Entering Sleep|Wake from|DarkWake" | tail

# 잡 상주 여부·마지막 종료 코드
launchctl print system/<접두사>.sleepwatcher

# 실시간 파일 접근 추적
sudo fs_usage -w -f filesys | grep '<마운트지점>'
```

`fs_usage` 를 쓸 때는 **시스템 설정의 Time Machine 패널을 닫을 것.** 열려 있으면 64초
주기 폴링이 로그의 90% 이상을 차지한다.

`does not support SMB FullFSync` 는 Time Machine 계열의 프로브 흔적이다.

### Finder 복사 실패 (-8062)

**Finder 대화상자는 실패 경로를 알려주지 않는다.** 이 채널 없이는 권한·용량 문제로
오진하게 된다.

```bash
log stream --predicate 'subsystem == "com.apple.DesktopServices"' --info
#  재현하면:  Error -8062 at path: <경로> on write

# 사후 조회
log show --last 30m --predicate 'subsystem == "com.apple.DesktopServices"' --info \
  --style compact | grep -E '8062|on write'
```

클라이언트 억제 설정의 실효 확인:

```bash
defaults read /Library/Preferences/com.apple.desktopservices DSDontWriteNetworkStores  # system
defaults read com.apple.desktopservices DSDontWriteNetworkStores                       # user
```

**둘 중 하나가 1이어도 CopyEngine 은 `.DS_Store` 를 쓸 수 있다.** "설정했으니 안 생긴다"의
근거로 쓰지 말 것 — 소스에 이미 있는 파일은 억제의 관할 밖이다.

### 게스트

```bash
journalctl -o short-iso --since "<t1>" --until "<t2>"
#   `Clock change detected` = step 순간,  smbd pam_unix = 세션 개폐
sudo smbstatus -b
chronyc tracking
journalctl -u mac-cruft-cleanup -n 20
sudo /usr/local/sbin/mac-cruft-cleanup <경로>     # 수동 1회 (멱등)
testparm -s 2>/dev/null | grep -E '^\s*veto files'   # 0줄이어야 한다
```

**함정 3종:**

- 저널 시각은 스큐 중에는 **게스트 시계 기준**이다. 호스트 로그와 대조할 때 주의.
- `--since` 에 날짜를 명시할 것 (자정 함정).
- `pmset sleepnow` 가 실제 수면으로 이어지지 않을 수 있다 — 사후 `pmset -g log` 로 확인.

### 시간 동기 판정

`systemctl status prltoolsd` 와 `ss --vsock` 은 **보장 지표가 아니다.** 초록불 상태로
21시간 스큐가 통과했다.

1차 지표는 게스트의 `journalctl | grep 'Clock change'` 와 `chronyc tracking` 이고,
직접 대조는 호스트/게스트에서 각각 `date` 를 찍는 것이다.

---

## 참고

`sudo` 인증 캐시는 tty 별 5분이다(`timestamp_timeout` 기본값). 연속 테스트 중 비밀번호를
묻지 않는 것은 이 캐시 때문이며, 규칙이 유효해서가 아니다. 즉시 만료는 `sudo -k`.

`sudo` 런타임과 `visudo -c` 의 권한 기준은 다르다. `visudo` 는 0440 을 요구하지만 sudo 의
실질 검사는 "group/other 쓰기 가능" 여부다 — 0640 파일이 유효하게 동작한 사례가 있다.
**경고를 "규칙이 무효"로 읽으면 오판이다.** 실효는 `sudo -l -U <계정>` 으로 직접 조회한다.
