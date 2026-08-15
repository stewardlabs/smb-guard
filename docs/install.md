# 설치와 검증

## 사전 조건

**호스트(macOS)**

- 워크스페이스가 **autofs 직접 맵**으로 마운트되어 있을 것
- `brew install sleepwatcher` — **brew 서비스로 등록하지 말 것.** 이 레포가 자체
  LaunchDaemon 으로 배치한다 (이유는 [decisions.md](decisions.md))
- 게스트로 **키 기반·비대화형** ssh 가 될 것

**게스트(Linux)**

- Samba, systemd
- 워크스페이스 경로가 존재할 것

### autofs 설정 — 이 레포가 건드리지 않는 부분

마운트 자체는 autofs 소관이고 smb-guard 는 그 위에서 동작한다. 세 파일을 먼저 맞춘다.

```text
# /etc/auto_master  — 직접 맵 등록
/-    auto_smb    -nosuid
```

```text
# /etc/auto_smb  (600 root)
<마운트지점>  -fstype=smbfs,soft  ://<계정>:<URL인코딩비번>@<게스트>/<공유명>
```

`soft` 가 **필수**다. 서버 부재 시 무한 대기 대신 유한 시간 내 실패해야 하며,
`SMBG_TRIGGER_TIMEOUT` 과 웨이크 훅의 대기 상한이 성립하는 전제다.

```ini
# /etc/autofs.conf
AUTOMOUNT_TIMEOUT=604800     # 만료 창 제거 (기본 3600 — failure-model.md 층 0)
AUTOMOUNTD_MNTOPTS=nosuid,nodev
AUTOMOUNTD_NOSUID=TRUE
```

**파일만 고치면 반영되지 않는다.** 트리거 재생성 시점에 값이 박히므로 `sudo automount -vc`
가 필수다. `AUTOMOUNT_TIMEOUT` 은 전역 설정임에 유의.

---

## 설치

```bash
cp smb-guard.conf.example smb-guard.conf
$EDITOR smb-guard.conf

./install.sh --dry-run        # 배치 계획 확인
./install.sh                  # 호스트(sudo) → 게스트(ssh -t sudo)
```

**일반 사용자로 실행한다.** 권한 승격은 각 단계에서 따로 일어난다 — 전체를 `sudo` 로
돌리면 ssh 가 root 의 `~/.ssh` 를 보게 되어 게스트 별칭이 해석되지 않는다.

게스트 배치는 원격 sudo 비밀번호 입력을 위해 **터미널(TTY)이 필요하다.** 스크립트로
감싸 돌리는 등 TTY 가 없는 환경에서는 미리 중단하고 안내한다.

부분 실행:

```bash
./install.sh --host           # 호스트만
./install.sh --guest          # 게스트만
./install.sh --guest --samba  # 게스트 + Samba 설정까지 배치 (기존 파일 백업)
```

Samba 설정은 기본적으로 배치하지 않고 **치환 결과를 출력**한다. 기존 `smb.conf` 를
통째로 덮으면 이 공유와 무관한 설정이 사라지기 때문이다.

## 수동 배치

스크립트를 쓰지 않아도 된다. 다만 **권한을 정확히 맞춰야 한다** — 틀리면 조용히 무시된다.

**호스트**

| 원본 | 목적지 | 소유자·권한 | 틀리면 |
|---|---|---|---|
| `smb-guard.conf` | `/usr/local/etc/smb-guard.conf` | `root:wheel 644` | 스크립트가 시작 시 실패 |
| `host/lib/common.sh` | `/usr/local/lib/smb-guard/common.sh` | `root:wheel 644` (**실행 비트 없음**) | — |
| `host/sbin/*` | `/usr/local/sbin/` | `root:wheel 755` | group/other 쓰기 시 권한 상승 취약점 |
| `host/LaunchDaemons/smb-guard.plist.in` | `/Library/LaunchDaemons/<접두사>.smb-guard.plist` | `root:wheel 644` | **launchd 가 로드 거부** |
| `host/LaunchDaemons/sleepwatcher.plist.in` | `/Library/LaunchDaemons/<접두사>.sleepwatcher.plist` | `root:wheel 644` | 상동 |
| `host/newsyslog.d/smb.conf.in` | `/etc/newsyslog.d/<접두사>.smb.conf` | `root:wheel 644` | **말없이 무시 — 로그 무한 증식** |

`*.in` 은 템플릿이다. `@LABEL_PREFIX@` `@LOGDIR@` `@SLEEPWATCHER_BIN@` 을 실제 값으로
바꾼다. **plist 파일명과 내부 `Label` 값이 일치해야 한다.**

sleepwatcher 경로는 아키텍처마다 다르다 — Apple Silicon `/opt/homebrew/sbin/sleepwatcher`,
Intel `/usr/local/sbin/sleepwatcher`.

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/<접두사>.smb-guard.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/<접두사>.sleepwatcher.plist
```

**게스트**

| 원본 | 목적지 | 소유자·권한 |
|---|---|---|
| `smb-guard.conf` | `/etc/smb-guard.conf` | `root:root 644` |
| `guest/sbin/*` | `/usr/local/sbin/` | `root:root 755` |
| `guest/systemd/*.in`, `*.timer` | `/etc/systemd/system/` | `root:root 644` |
| (생성) | `/etc/sudoers.d/clockfix` | `root:root 0440` ← **0440 이 아니면 sudo 가 거부** |
| `guest/samba/smb.conf.in` | `/etc/samba/smb.conf` 에 병합 | `root:root 644` |

```text
# /etc/sudoers.d/clockfix — 인자 와일드카드는 epoch 값(정수·소수점)을 받기 위함
<ssh계정> ALL=(root) NOPASSWD: /usr/local/sbin/clockfix *
```

```bash
sudo visudo -c -f /etc/sudoers.d/clockfix     # 배치 전에 검사할 것
sudo systemctl daemon-reload
sudo systemctl enable --now mac-cruft-cleanup.timer
```

---

## 검증

### 0. 최우선 — root 컨텍스트의 게스트 ssh

**실패하면 여기서 멈춘다.** 시계 교정이 통째로 무력화된다.

```bash
sudo -u <소유자> -H ssh -o BatchMode=yes -o ConnectTimeout=3 <게스트> 'date +%s'
#  기대: epoch 숫자
```

### 1. 잡 등록 상태

```bash
sudo launchctl print system/<접두사>.sleepwatcher | grep -Ei 'state|last exit'
#  기대: state = running   (KeepAlive 상주)

sudo launchctl print system/<접두사>.smb-guard | grep -Ei 'state|last exit|runs'
#  기대: state = not running / last exit code = 0
```

**`not running` 이 정상이다.** launchd 의 state 는 "지금 프로세스가 떠 있는가"만
나타내며 "이벤트 대기 중"이라는 상태는 없다. 마운트 훅은 평소 프로세스 0개가 정상이다.

> `StartOnMount` 는 launchd 내부 처리 키라 `print` 출력에 이벤트 채널로 노출되지 않는다.
> **"등록됐지만 훅이 안 걸린" 상태와 정상을 `print` 로는 구분할 수 없다** — 실제 마운트를
> 일으켜 보는 것이 유일한 검증이다(아래 2).

### 2. 훅이 실제로 걸렸는지 — 무관한 마운트로 확인

```bash
hdiutil create -size 10m -fs APFS -volname SGTEST /tmp/sgtest.dmg
hdiutil attach /tmp/sgtest.dmg
sleep 3
sudo launchctl print system/<접두사>.smb-guard | grep -Ei 'runs|last exit'
#  기대: runs 증가 (= 훅이 걸려 있다), last exit code = 0
tail -5 /var/log/smb/smb-guard.log
#  기대: 새 항목 없음 (무관한 마운트에는 침묵한다)
hdiutil detach /Volumes/SGTEST && rm /tmp/sgtest.dmg
```

`ThrottleInterval 5s` 때문에 직전 실행 후 5초 내 마운트는 발화가 지연될 수 있다.

### 3. 상태 조회와 로그 회전

```bash
smb-guard --state                     # 기대: HEALTHY
sudo newsyslog -nv | grep /var/log/smb # 기대: 3개 파일이 나열됨
```

3개가 안 나오면 `newsyslog` 설정 파일의 권한을 확인한다(`root:wheel 644`).

### 4. 교정 동작 — 인위적 하이재킹

```bash
sudo umount -f <마운트지점>
sudo /bin/ls <마운트지점> > /dev/null       # root 소유 마운트 유발
sleep 8
mount | grep <마운트지점>                    # 기대: mounted by <소유자>
tail -5 /var/log/smb/smb-guard.log          # 기대: 감지 → 교정 완료
```

**재현이 실패할 수 있다** — 빈 창에서 사용자 프로세스가 먼저 트리거하면 하이재킹이
성립하지 않는다. 그것은 고장이 아니라 [경합](failure-model.md#층-4--root-소유-마운트-하이재킹)의
정상 동작이다. 확실히 재현하려면 워크스페이스를 만지는 프로세스(에디터·LSP·파일 감시기·
다른 셸의 cwd)를 먼저 정리한다.

### 5. 부재에서 생성

```bash
sudo umount -f <마운트지점> && sudo smb-guard --ensure
smb-guard --state                            # 기대: HEALTHY
```

### 6. 실수면 — 훅 발화

```bash
# 뚜껑을 닫아서 실제로 재운다
tail -40 /var/log/smb/smb-guard.log
#  기대: [sleep] 1줄 → [wakeup +Ns] 다수 → mount HEALTHY (ls ok, Ns)
```

> **함정**: `slept for 1s` 로 게이트가 스킵되면 미수면을 의심한다. AC 전원에서는 "화면
> 잠금 후 미수면" 정책이 재수면을 막으므로, `pmset sleepnow` 로 한 번 강제 수면 → 즉시
> 웨이크하면 그대로 깨어 있는 상태가 된다. 이후 키를 눌러도 wake 이벤트가 없어 로그가
> 더 찍히지 않는다 — **훅 고장이 아니다.**
>
> 판별: `pmset -g log | grep -E "Entering Sleep|Wake from|DarkWake" | tail` 에
> `Entering Sleep` 이 1회뿐이면 미수면이다.

### 7. 만료 창 제거 확인

마운트 후 65분 이상 방치한 뒤:

```bash
log show --last 2h --predicate 'process == "diskarbitrationd" AND eventMessage CONTAINS "<공유명>"' \
  --info --style compact | grep -E 'created|removed'
#  기대: removed 없음
```

### 8. 게스트

```bash
ssh <게스트> 'systemctl list-timers mac-cruft-cleanup.timer'   # NEXT 가 채워져야 한다
ssh <게스트> 'sudo -n /usr/local/sbin/clockfix $(date +%s)'    # NOPASSWD 동작
ssh <게스트> 'testparm -s 2>/dev/null | grep -E "^\s*veto files"'   # 0줄이어야 한다
```

마지막 것을 `grep -i veto` 로 하지 말 것 — `fruit:veto_appledouble = no` 가 이름 때문에
잡히는데, 그 줄은 차단이 아니라 **차단 해제**이며 반드시 남아 있어야 한다.

### 9. Finder 복사 (층 5 해소 확인)

```bash
# 터미널 A
log stream --predicate 'subsystem == "com.apple.DesktopServices"' --info
# 터미널 B / Finder: Finder 로 열어본 적 있는 폴더(= .DS_Store 가 든 폴더)를 복사
#  기대: -8062 0건, 팝업 없음
```

15분 뒤 회수를 확인한다. **회수 대상을 지우지 말고 남겨 둘 것** — 정리 스크립트는 0건이면
침묵하도록 설계되어 있어, 대상이 없어서 조용한 것과 고장나서 조용한 것이 구분되지 않는다.

```bash
ssh <게스트> 'journalctl -u mac-cruft-cleanup -n 5'
```

---

## 게스트 시계

각성 중 상시 보정은 NTP 데몬의 몫이다. install 이 자동 배치하지 않는다 — 시스템 시계
정책이라 잘못 건드리면 손해가 크다. 참조 설정과 근거는 [guest/chrony/](../guest/chrony/) 에 있다.

핵심 두 가지:

- **하이퍼바이저의 게스트 시간 동기화를 끈다.** 게스트 NTP 와 배타적일 수 있다
  ([failure-model.md](failure-model.md) 층 1).
- **횟수 제한 없는 step 을 허용한다**(`makestep 1 -1`). 가상 게스트는 호스트 수면 중
  시계가 통째로 멈추므로 큰 오차가 일상이다.

## 롤백

```bash
sudo launchctl bootout system/<접두사>.smb-guard
sudo launchctl bootout system/<접두사>.sleepwatcher
```

게스트:

```bash
sudo systemctl disable --now mac-cruft-cleanup.timer
sudo cp -a /etc/samba/smb.conf.bak-<타임스탬프> /etc/samba/smb.conf && sudo systemctl restart smbd
```

**Samba 롤백은 `-8062` 의 복원이다** — 다른 원인이 밝혀진 경우에만 의미가 있다.
