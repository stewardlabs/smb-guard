# smb-guard

macOS 호스트에 SMB 로 마운트한 작업 디렉터리가 **조용히 망가지는 것**을 막는다.
자동 마운트(autofs) 위에서 마운트 소유권을 감시·교정하고, 가상 게스트의 시계를 웨이크
직후 되돌리며, Finder 가 남기는 잔재를 서버측에서 사후 회수한다.

macOS 호스트에서 개발하고 파일은 Linux VM(또는 파일 서버)에 두는 구성 — 즉
**호스트의 편집기와 게스트의 툴체인이 같은 트리를 봐야 하는 환경**을 대상으로 한다.

## 무엇이 문제인가

SMB 마운트는 "끊어지거나 붙어 있거나" 둘 중 하나가 아니다. 그 사이에 **무증상 고장**들이 있다.

- **소유권 하이재킹** — Time Machine 의 `backupd` 같은 root 프로세스가 자동 마운트를
  먼저 건드리면, 마운트가 root 소유로 성립한다. 사용자 프로세스는 그때부터 `EACCES` 를
  받는다. 사용자별 마운트가 공존하지 못하므로 스스로 낫지 않는다.
- **유휴 만료 창** — autofs 는 마지막 사용이 아니라 **마운트 시각** 기준으로 만료시킨다.
  기본 1시간이라 하이재킹 창이 매시간 열린다.
- **게스트 시계 정지** — 호스트가 자면 게스트 시계도 멈춘다. 깨어난 뒤 수천 초 어긋난
  시계로 파일을 쓰면 mtime 이 미래가 되고, mtime 기반 빌드 도구(cargo 등)가 소스 변경을
  **침묵 무시**한다.
- **부수 파일 차단이 주 기능을 죽인다** — 서버에서 `.DS_Store` 쓰기를 막으면 Finder
  CopyEngine 이 복사 작업 **전체**를 실패시킨다(오류 `-8062`). 대화상자는 실패한 경로를
  알려주지 않아 권한·용량 문제로 오진하기 쉽다.

전부 "로그를 안 보면 모르는" 종류다. 자세한 인과와 실측 근거는
[docs/failure-model.md](docs/failure-model.md) 를 볼 것 — 6개 층으로 정리했다.

## 무엇을 하는가

| 구성요소 | 위치 | 트리거 | 역할 |
|---|---|---|---|
| `smb-guard` | 호스트 | 마운트 이벤트 (`StartOnMount`) | 소유권 판정, 하이재킹 즉시 교정 — **유일한 교정 주체** |
| `smb-guard-sleep` | 호스트 | 수면 직전 | 직전 수면 시각 기록 (기록만 한다) |
| `smb-guard-wakeup` | 호스트 | 웨이크 | 네트워크 대기 → 시계 교정 → 마운트 보장 → 생존성 확인 |
| `smbfix` | 호스트 | 사람 | 자동 복구가 실패했을 때의 수동 도구 |
| `clockfix` | 게스트 | 호스트 훅이 ssh 로 호출 | resume 직후 시계 step |
| `mac-cruft-cleanup` | 게스트 | systemd 타이머 (15분) | macOS 잔재 사후 회수 |

설계 계약 세 가지가 이 체계를 지탱한다.

- **판정은 mount 테이블만 읽는다.** 경로 접근(`ls`/`stat`)은 판정에 쓰지 않는다 — 그
  자체가 자동 마운트를 트리거해 측정 대상을 바꾸고, 데몬 컨텍스트에서는 TCC 가 `readdir`
  를 거부해 "마운트 실패"로 오판하게 만든다.
- **교정 주체는 하나다.** 웨이크 훅도 수동 도구도 자체 마운트 로직을 갖지 않고
  `smb-guard` 에 위임한다.
- **차단이 아니라 정리로 청결을 얻는다.** 정리는 실패해도 아무것도 깨뜨리지 않지만,
  차단은 실패하는 것이 곧 남의 기능이다.

## 요구사항

- **호스트**: macOS, [sleepwatcher](https://www.bernhard-baehr.de/) (`brew install sleepwatcher`
  — brew 서비스로 등록하지 말 것, 이 레포가 자체 LaunchDaemon 으로 배치한다)
- **게스트**: Linux + Samba, systemd, 호스트에서 키 기반 ssh 로그인
- 워크스페이스가 호스트에 **autofs 직접 맵**으로 마운트되어 있을 것

물리 Linux 서버에도 쓸 수 있다. 그 경우 `clockfix` 와 chrony 설정은 불필요하다 —
시계가 멈추는 것은 가상 게스트 고유의 문제다.

## 빠른 시작

```bash
git clone https://github.com/stewardlabs/smb-guard.git
cd smb-guard
cp smb-guard.conf.example smb-guard.conf
$EDITOR smb-guard.conf          # 계정·마운트 지점·게스트 별칭·공유명

./install.sh --dry-run          # 무엇을 어디에 배치할지 먼저 확인
./install.sh                    # 호스트(sudo) → 게스트(ssh -t sudo)
```

`install.sh` 는 **일반 사용자로** 실행한다. 권한 승격은 각 단계에서 따로 일어난다 —
전체를 `sudo` 로 돌리면 ssh 가 root 의 `~/.ssh` 를 보게 되어 게스트 별칭이 해석되지 않는다.

설치를 마쳤으면 **가장 먼저 이것을 확인한다.** 실패하면 시계 교정이 통째로 무력화된다:

```bash
sudo -u <소유자> -H ssh -o BatchMode=yes -o ConnectTimeout=3 <게스트> 'date +%s'
```

설치 스크립트를 쓰지 않고 손으로 배치해도 된다 — [docs/install.md](docs/install.md) 에
파일·목적지·소유자·권한 대조표가 있다. 다만 **권한을 정확히 맞춰야 한다.** 이 체계의
지배적 실패 모드가 "권한이 틀리면 조용히 무시된다"이다: `newsyslog` 설정이 `root:wheel
644` 가 아니면 말없이 무시되고, LaunchDaemon plist 가 그렇지 않으면 launchd 가 로드를
거부한다.

## 문서

| 문서 | 내용 |
|---|---|
| [docs/failure-model.md](docs/failure-model.md) | 6층 고장 모델과 에러 코드 지도 — **먼저 읽을 것** |
| [docs/architecture.md](docs/architecture.md) | 구성 전문, 역할 분담, 설계 계약 |
| [docs/install.md](docs/install.md) | 설치·검증 절차, 수동 배치 대조표 |
| [docs/operations.md](docs/operations.md) | 관찰 항목과 진단 도구 |
| [docs/decisions.md](docs/decisions.md) | 결정 기록과 설계 원칙 27개 |
| [docs/open-questions.md](docs/open-questions.md) | 미결 과제와 잠복 위험 |
| [docs/history/](docs/history/) | 개발 이력 원장 (실측 로그·기각된 가설 포함) |

이 프로젝트의 가치는 스크립트보다 **고장 모델과 기각된 가설의 기록**에 있다. 같은 증상을
겪는 사람이 이미 반증된 가설을 다시 검증하지 않아도 되게 하는 것이 목적이다.

## 라이선스

[MIT](LICENSE)
