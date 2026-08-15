> ## 이 문서에 대하여
>
> **개발 이력의 원장이다.** 정리된 결론은 [failure-model.md](../failure-model.md),
> [architecture.md](../architecture.md), [decisions.md](../decisions.md) 에 있고, 이
> 문서는 그 결론에 도달한 **경위**를 담는다 — 날짜별 관측, 세운 가설과 그것이 반증된
> 과정, 실측 로그, 성능 수치.
>
> 결론만 필요하면 위 문서들로 충분하다. 이것을 읽어야 할 때는 두 경우다: ① 어떤 결정의
> 근거를 끝까지 따라가야 할 때 ② 비슷한 증상을 겪는데 우리가 이미 기각한 가설을 다시
> 세우고 있는 것은 아닌지 확인할 때.
>
> ### 경로·계정명을 읽는 법
>
> **본문의 실측 로그와 명령은 특정 환경의 것을 그대로 두었다.** 치환하면 증거의 성격이
> 훼손되기 때문이다 — 이 문서의 가치는 "실제로 이렇게 관측됐다"에 있다. 대신 대응표를
> 둔다. 자신의 환경으로 바꿔 읽으면 된다.
>
> | 이 문서의 표기 | 설정 키 | 의미 |
> |---|---|---|
> | `sanha` | `SMBG_OWNER` | 워크스페이스 소유 계정 |
> | `devm` | `SMBG_HOST` | 게스트 ssh 별칭 |
> | `/opt/stewardlabs` (호스트) | `SMBG_MP` | 호스트 마운트 지점 |
> | `/opt/stewardlabs` (게스트) | `SMBG_GUEST_ROOT` | 게스트 워크스페이스 경로 |
> | `stewardlabs` (공유명) | `SMBG_SHARE` | SMB 공유명 |
> | `io.stewardlabs.*` | `SMBG_LABEL_PREFIX` | launchd Label 접두사 |
> | `10.211.55.4` | — | 게스트 IP (하이퍼바이저가 `/etc/hosts` 에 등록한 값) |
>
> 환경은 macOS 26 + Parallels Desktop 26.4 + Ubuntu 26.04 (ARM64) 였다.
>
> ### 공개판과 달라진 점
>
> 이 문서가 서술하는 스크립트는 공개판에서 **설정 외부화**를 거쳤고, 그 과정에서 결함
> 세 가지를 함께 고쳤다 (`/etc/hosts` 별칭 파싱, 원격 진단의 경로 혼동, 계정 조회 폴백).
> 상세는 [CHANGELOG.md](../../CHANGELOG.md) 를 볼 것. 파일 배치도
> `host/`·`guest/` 로 나뉘었으므로, 본문의 경로는 배포 위치(`/usr/local/sbin` 등)로 읽는다.

---

# devm SMB 워크스페이스 — 핸드오프 v17 (2026-08-14)

**v17 = v16 + Finder 복사 차단(-8062) 해소.** 호스트 Finder에서 공유로 폴더를 복사하면
`오류 코드 -8062` 로 전량 실패하는 현상이 확인됐다. 원인은 서버측 `veto files` 다 —
macOS Finder의 CopyEngine은 `.DS_Store` **쓰기 실패를 복사 작업 전체의 치명적 오류로
취급**한다. 처방은 방어선의 이동이다: **차단(서버 veto) 폐지 → 사후 정리(VM systemd
timer) + git exclude + 클라이언트 억제(system 도메인)**. 상세는 §0-v17 추기, §1 층 5,
§8 v17 결정, §10.6, 부록 A.13/A.16~A.18, 부록 P. **08-15: 적용·검증 완료 — v17 확정.**
`.DS_Store` 3개가 서버에 수용되고 타이머가 회수하는 end-to-end 가 실증됐다
(§0-v17 추기 3). **08-15 추기 2: 자체 환경 재현 확정 + 인과 정밀화** — 치명 트리거는 "Finder의 신규 메타데이터 쓰기"가 아니라
**소스 폴더에 이미 들어 있는 (비어 있지 않은) `.DS_Store` 를 페이로드로 복사하는
경로**다. 처방은 불변, 진단만 정확해졌다(§0-v17 추기 2, 원칙 19). **시계·마운트·훅 체계는 v16에서 변경
없다** — 이 개정은 SMB 공유 정책 한 축에 국한된다.

**v16 = v15 + 시계 계층 재구성.** 08-14에 "chrony가 부팅마다 죽는" 현상을 추적한
결과 3주에 걸친 사건 사슬이 규명되어 시계 아키텍처를 재정의했다: **상시 권위는
chrony 단독**(NTS+kr 소스), **resume step은 clockfix**(소수점 epoch로 정밀화),
**prltimesync는 off**(호스트 `prlctl set devm --time-sync off`). 상세는 §0-v16 추기,
§1 층 1, §8 v16 결정, 부록 O. 마운트·훅 체계는 v15에서 변경 없다.

**이 문서는 확정본이다.** 2026-08-08 하루에 걸친 배치 통일(v14 계열)과 전 항목 검증을
마치고 v15로 봉인한다. 스크립트·plist·설정의 배포 버전도 v15이며, 코드 로직은
v14.11과 동일하다(버전 표기만 갱신). 이후 변경은 v15.x 로 이 문서에 추기한다.

문제 재발·구성 변경 시 이 문서를 새 세션에 첨부할 것. 본문 중 "v14.N" 소절 표제는
당일의 진화 이력이므로 그대로 보존한다.

v13(08-07 운영 개시)을 대체하는 현행본. 문제 재발/구성 변경 시 이 문서를 새 세션에
첨부할 것. 개발환경 전체 문서의 "VM 구축" 섹션 원고를 겸한다 — §2가 구성 전문,
부록 A가 모든 스크립트·설정의 전문이다.

**v13 → v14는 고장 모델·정책의 변경이 아니라 배치(deployment)의 변경이다.**
§1 고장 모델, §7 결정 기록, §8 설계 원칙은 v13에서 그대로 유효하다. 달라진 것은
스크립트가 어디에 놓이고 어떤 권한 도메인에서 실행되며 로그가 어디에 쌓이는가이다.
단, 배치 변경 과정에서 **v13 코드의 실제 버그 2건이 발견되어 함께 고쳤다** (§3.1).

## 0. 최종 상태 — v15 확정 (2026-08-08)

**전 검증 항목 통과. 운영 이행.** 남은 것은 §6의 수 주 관찰뿐이다.

| 검증 | 결과 |
|---|---|
| 배치 통일 (system 도메인 · /usr/local/sbin · 통합 로그 · newsyslog) | 완료 |
| 시나리오 A (watch 교정) | 통과 — 수동 3회 + **실전 1회(backupd, 4초 종결)** |
| 시나리오 B (부재 생성) / C (무해성) | 통과 |
| 시나리오 D (604800 실효) | **확정** — 각성 1h49m 포함 3h52m 무결 생존 (diskarb 대조) |
| 장시간 수면 (1h42m 배터리) / 단거리(75s) / 게이트(4~13s 스킵) | 전건 통과 |
| 성능 목표 wake+6초 | **달성 — 훅 기준 +4초** (v14.0의 15초에서 단축) |
| 시계 3계층 (chrony + clockfix) | -519s → -1s 등 전건 수렴 |
| newsyslog 설정 | 유효 (3파일 파싱, 임계 미달 정상 skip) |
| TIMEOUT=60 실험 되돌림 실효 | **확인** — automount -vc 후 150초 생존(만료 검사 2회+ 통과) |
| 구 배치 정리 + 미사용 sudoers 회수 | 완료 (백업 /var/backups/smb-guard-v13-*) |
| 층 4-b umount EPERM 조사 | 종료 — 가설 5건 기각, 재개 조건 로그 내장(`umount -f 폴백` 출현 시) |

**성능 확정 (08-08 18:49).** 배터리·6151초 실수면에서 웨이크(18:48:58) →
mount HEALTHY(18:49:04) = **wake+6초, 훅 기준 +4초**. §3.7c의 `pmset -g log` 이관이
예측(11초 단축)대로 작동했다 — 관찰 블록은 +4s→+10s 구간, 즉 마운트가 사용 가능해진 뒤에 실행됐다.

### 0-v16 추기 (2026-08-14) — 시계 계층 재구성

| 항목 | 결과 |
|---|---|
| chrony 부팅 시 사망 원인 | **규명·완치** — prltoolsd 기동 시 `timedatectl set-ntp 0` (저널 직접 증거). `prlctl set devm --time-sync off` 로 원인 제거, 웜 재부팅 검증 통과 |
| +76482s (08-07, §11 미결) | **배경 규명** — 08-05 Tools 설치의 첫 `set-ntp 0` 가 chrony를 disable → 08-08 04:28까지 prltimesync 단독 구간에서 발생. 폴백 부재의 이유가 답이었다 |
| drift 오염 (-27905 ppm) + step 루프 | **완치** — 동시 가동 중 오염(추정) → rm 후에도 shutdown 재작성 + 커널 잔류 보정으로 1세대 에코 → 자연 수렴. 현재 3.7 ppm |
| prltimesync | **유휴 실증** — 30초 인위 오프셋 3분 방치 실험으로 무동작 확인. 조회 채널(prlhosttime)은 생존 |
| chrony 소스 | 영국 단일 → **NTS 4 (maxpoll 6) + kr.pool 3 (maxpoll 6)**. 현재 오프셋 0.2ms |
| clockfix | **v2** — 소수점 epoch(정밀도 ±1s → 수십 ms) + step 후 `chronyc online` |
| 잔존 확인 | VM 콜드 스타트 1회에서 `set-ntp 0` 부재 재확인 (§11) |

### 0-v17 추기 (2026-08-14) — Finder 복사 차단(-8062) 해소

| 항목 | 결과 |
|---|---|
| 증상 | 호스트 Finder → `/opt/stewardlabs` 로 파일/폴더 복사 시 `작업을 완료할 수 없습니다(오류 코드 -8062)` — 복사 **전량** 실패 |
| 원인 | 서버측 `veto files` 의 `.DS_Store`. **08-15 정밀화**: 치명 경로는 Finder가 **소스 폴더에 든 `.DS_Store` 를 복사 항목의 하나로 대상에 쓰다가** ACCESS_DENIED를 맞는 것이다(추기 2). 로그의 실패 경로가 소스 측인 이유가 이것이다 |
| 1차 증거 | macOS 통합 로그 — `[com.apple.DesktopServices:CopyEngine] Error -8062 at path: .../.DS_Store on write` (§7 신규 진단 도구로 채집) |
| `DSDontWriteNetworkStores` 가 막지 못한 이유 | **08-15 정밀화 — 애초에 관할 밖이다.** 이 설정은 Finder가 네트워크 볼륨에 **새 `.DS_Store` 를 생성**하는 것을 억제할 뿐, **소스에 이미 존재하는 파일을 페이로드로 복사**하는 것과 무관하다. 실제로 이 맥에서는 억제가 실효 중이었다(추기 2 케이스 1) — 그런데도 -8062가 났다. §9 원칙 27 |
| 처방 | `veto files` / `delete veto files` **폐지**. 청결은 VM `mac-cruft-cleanup.timer` 가 사후 정리로 담당 (A.16/A.17) |
| 부수 수정 | `fruit:resource = file` **명시** — `stream` 은 ext4 xattr 크기 한계를 물려받아 같은 형태의 실패를 새로 만든다 (§8 v17) |
| 부수 발견 | `.Trashes` veto는 Finder "휴지통으로 이동" 을 깨뜨리는 잠복 버그였다 (미발현 상태로 존재) |
| 호스트 autofs | **변경 없음** — `auto_master` / `auto_smb` / `autofs.conf` 3파일 모두 이 고장과 무관 (§10.6) |

**적용 상태**: **적용·확정 (08-15)** — 추기 3.

### 0-v17 추기 2 (2026-08-15) — 재현 확정 · 인과 정밀화

v17 적용 **전** 상태에서 3케이스 대조 실험을 수행했다. 진단은 확정됐고, 인과 모델이
한 단계 정밀해졌다.

| # | 소스 조건 | 터미널 `cp -r` | Finder |
|---|---|---|---|
| 1 | `.DS_Store` 없음 | 정상 | **정상** — veto가 켜져 있어도 복사 성공 |
| 2 | `touch` 로 만든 **빈(0B)** `.DS_Store` | 그 파일만 `Permission denied`, 나머지 복사 | **팝업 없이 성공** — `.DS_Store` 만 조용히 제외. 로그에 `POSIXError 13 → afpAccessDenied` 는 찍히나 -8062 없음 |
| 3 | **실제(비어 있지 않은)** `.DS_Store` 포함 (`~/Downloads` 의 진짜 폴더) | 그 파일들만 `Permission denied`, 나머지 복사 | **-8062 팝업, 작업 중단** — `Error -8062 at path: /Users/…/<소스>/.DS_Store on write` |

**확정된 사실 4건**:
- 재현·실패 경로 실명 확보 — §11 최우선 항목의 전반부 충족. 실패 경로는 **소스 측**
  (`/Users/…/Downloads/…/.DS_Store`)이다: CopyEngine은 복사 중이던 항목의 소스 URL로
  오류를 보고한다. 즉 치명 트리거는 "대상에 새 메타데이터를 쓰는 것"이 아니라
  **소스에 든 `.DS_Store` 를 페이로드로 복사하는 것**이다.
- 케이스 1이 성공했다 = 이 맥의 `DSDontWriteNetworkStores` 는 **실효 중**이다(복사
  중 새 `.DS_Store` 가 생성되지 않았다). 그런데도 케이스 3이 죽었다 — 클라이언트
  억제가 이 고장의 해법이 될 수 없음이 자체 환경에서 실증됐다. **소스 안의 파일은
  억제의 관할 밖이다.**
- 터미널 `cp` 는 파일 단위로 실패를 넘기고 계속한다(EACCES 보고 후 속행). 이때 통합
  로그가 없는 것은 정상이다 — `com.apple.DesktopServices` 채널은 Finder/CopyEngine
  전용이고 `cp` 는 그냥 syscall이다.
- 실사용 관점의 결론: **맥에서 Finder로 폴더를 다뤄본 적 있는 폴더는 거의 전부
  케이스 3이다.** veto가 있는 한 Finder 복사는 사실상 전면 불능이다.

**추정 1건 — 케이스 2와 3의 분기**: 0바이트 파일은 데이터 쓰기 단계가 없어
CopyEngine이 생성 실패를 "건너뛸 수 있는 실패"로 분류하고, 비어 있지 않은 파일의
쓰기 단계 실패(`on write`)는 데이터 유실로 분류해 치명 처리하는 것으로 보인다.
로그 서명(케이스 2는 `POSIXError 13` 만, 케이스 3은 `13` + `-8062 on write`)과
부합하나 내부 구현의 확인은 불가능하다. 운영상 중요한 것은 분기 자체가 아니라
**실전의 `.DS_Store` 는 항상 비어 있지 않다**는 사실이다(Finder가 뷰 상태를 담아
생성하므로 통상 수 KB).

**부수 관측 — 중단된 복사의 잔재**: -8062 팝업에서 확인을 누르면 대상에 폴더가
남는데, Finder에서는 **흐린 아이콘 + 재개(⟳) 표시**로 보이고 내용 접근이 안 되며,
터미널로는 접근된다. 내부는 일부 파일만 **600 권한**(`-rw-------@`)으로 존재한다.
이는 CopyEngine의 정상 동작이다 — 복사 중에는 제한 권한으로 쓰고 완료 시점에 최종
권한·메타데이터를 입히는데, 중단으로 그 단계가 오지 않았다(`create mask = 0644` 는
AND 마스크라 클라이언트가 요청한 0600을 넓히지 않는다). **잔재는 재개하지 말고
지운 뒤 v17 적용 후 재복사한다**: `rm -rf /opt/stewardlabs/<해당 폴더>` (VM 셸 또는
맥 터미널 — Finder로는 열리지 않으므로). 케이스 2 로그에 낀 `-36/Code=258` 과 취소
후의 `-128`(userCanceledErr)은 각각 직전 삭제 작업의 소음과 취소 자체의 표기로,
무해하다.

### 0-v17 추기 3 (2026-08-15) — 적용·검증 완료, v17 확정

| 검증 | 결과 |
|---|---|
| smb.conf 교체 · smbd 재시작 | 완료. `testparm -s` OK, `veto files` 0줄 |
| Finder 복사 (케이스 3 동일 폴더) | **통과** — 팝업 없음, CopyEngine 오류 0건. **`POSIXError 13 → afpAccessDenied` 자체가 소멸** — 08-14에는 조용히 건너뛴 케이스 2에도 찍혔던 줄이다. 서버가 `.DS_Store` 를 거부하지 않음의 직접 증거 |
| Finder 삭제 | 통과 — `DeleteItem` 정상, 오류 0건 |
| 타이머 등록 | 정상. `enable --now` 시점에 `OnBootSec=5min` 이 이미 경과해 즉시 1회 발화(06:51:29) |
| **정리 회수 end-to-end** | **통과 (07:22:22)** — `제거 3건 (파일 3 / 디렉터리 0 / 휴지통 0)`. 이 **3**은 08-14에 `cp -r` 이 `Permission denied` 로 거부했던 바로 그 3개(`cp_test_dir/.DS_Store`, `stewardlabs-card-pipeline/.DS_Store`, `stewardlabs-design-system-kit/.DS_Store`)와 정확히 일치한다 |

**이로써 3계층이 닫혔다**: 유입(Finder가 씀) → **수용**(서버가 거부하지 않음) →
**회수**(타이머가 치움). §11 최우선 항목 해소.

**부수 — 원칙 25의 재현**: 1차 시도(07:05:51 복사 → 07:06:09 Finder 삭제 →
07:06:29 타이머)는 **회수 대상이 20초 차이로 먼저 사라져** 아무 로그도 남지 않았다.
2차 시도에서 복사분을 남겨 둔 채 기다려 확인했다. cleanup은 0건이면 침묵하도록
설계돼 있어, "대상이 없어서 조용한 것"과 "고장나서 조용한 것"이 출력으로 구분되지
않는다 — 실증 시 대상을 남겨 둘 것.

**부수 — 순회 범위 실측 (cleanup v1.2 계기)**: `/opt/stewardlabs` 가 단일 레포가
아니라 **여러 레포가 다양한 깊이에 존재하는 워크스페이스 루트**임이 확인됐다.
`-name` 기반 prune 이라 모든 깊이의 `.git` 이 자동 제외되는 것은 설계대로였으나,
레포마다 있는 `target/` 은 제외되지 않아 순회의 대부분을 차지했다(표본 733 항목 중
714 = 97%). v1.2에서 `PRUNE_NAMES` 기본값에 `target`·`node_modules` 를 넣었다 —
A.16.

## 1. 고장 모델 (5층 → 6층) — 층 1은 v16, 층 5는 v17 신규. 나머지는 v13에서 변경 없음

v13 §1 전문이 그대로 유효하다. 요약만 남기고 상세는 v13 문서를 참조한다.

| 층 | 요지 | 처방 |
|---|---|---|
| 0 유휴 만료 창 | `AUTOMOUNT_TIMEOUT` 미설정 → 기본 3600. **마지막 사용이 아니라 마운트 시각 + 3600** 기준으로 만료. 만료 검사는 약 120초 주기 | `AUTOMOUNT_TIMEOUT=604800` + `automount -vc` |
| 1 게스트 시계 | **v16 재서술**: prltimesync는 기동 시 `timedatectl set-ntp 0` 로 게스트 NTP를 강제 해제한다 — 3계층 공존은 Parallels 설계상 애초에 불가능했고, "3계층"이라 믿던 기간의 실체는 구간별 1~2계층이었다. +76482s는 그 산물(§0-v16). 양수 스큐는 미래 mtime → cargo 침묵 무시 | **2계층 확정**: 상시 = chrony 단독(NTS+kr, `makestep 1 -1`, maxpoll 6) / resume step = clockfix v2(호스트 권위, 소수점 epoch). prltimesync = off(유휴, prlhosttime 조회만 잔존) |
| 2 스퓨리어스 웨이크 | 수면 미진입/즉시 웨이크 시 훅 오동작 | `slept < 30s` 게이트 |
| 3 TCC 프로브 블라인드 | launchd 컨텍스트 ls의 EPERM을 마운트 실패로 오판. **08-08 야생 실증**: 트리거 `ls` 가 EPERM인데도 마운트 성사 — `open()` 은 이미 일어났고 거부된 것은 `readdir` 뿐 | 판정을 mount 테이블로 단일화 → 구조적 소멸. **FDA 불필요** |
| 4-b 데몬 컨텍스트 umount 거부 | **08-08 조사 종료**: 데몬 컨텍스트에서만 `umount -f` 가 EPERM(관측 1회). 가설 5건 기각, (a) 실행 컨텍스트만 미확정 잔존 — §1 부기 | `diskutil` 을 1단계로 (DiskArbitration 위임). 원인과 무관하게 유효. **재발 시에만 조사 재개** |
| **5 Finder 부수 쓰기 차단** (v17 신규 · 08-15 정밀화) | 서버가 `.DS_Store` 쓰기를 거부하면 **Finder는 그 복사 작업 전체를 실패시킨다.** 치명 경로는 **소스 폴더에 이미 든 비어 있지 않은 `.DS_Store` 를 페이로드로 복사**하는 것 — 맥에서 Finder로 다뤄본 폴더는 거의 전부 해당한다. 빈(0B) 파일·신규 생성 실패는 조용히 건너뛴다(추기 2). 사용자에게는 "복사가 안 된다"로만 보이고 실패 대상은 로그에만 실명으로 남는다 | 서버측 차단 폐지 → **사후 정리로 이관**. `veto files` 제거 + VM `mac-cruft-cleanup.timer` + `.git/info/exclude` (§8 v17, A.13/A.16~A.18) |

### 부기 — 두 EPERM의 원인 분석 (08-08)

`ls` EPERM(층 3)과 `umount` EPERM(층 4-b)은 **원인이 다르다.** 08-08에 통합 가설
(둘 다 네트워크 볼륨 TCC)을 세웠다가 반증으로 폐기했다 — 원칙 5의 적용 사례.

**관측 5건** (FDA 부여 목록: sleepwatcher / AppCleaner / iTerm2)

| # | 실행 주체 | FDA | 명령 | 결과 |
|---|---|---|---|---|
| 1 | sleepwatcher 데몬 → asuser | **있음** | `ls` | ok |
| 2 | smb-guard 데몬 → asuser | 없음 | `ls` | **EPERM** |
| 3 | smb-guard 데몬 (root 직접) | 없음 | `umount -f` | **EPERM** |
| 4 | iTerm2 → sudo → asuser | **있음** | `ls` | ok |
| 5 | **Terminal.app → sudo** | **없음** | `umount -f` (sanha 마운트) | **ok** |
| ~~6~~ | ~~Terminal.app → sudo~~ | — | ~~`umount -f` (root 마운트)~~ | **무효 — 측정 오염** |

**`ls` (층 3) — TCC 가설 유지.**
1·2·4가 FDA 보유와 완전히 상관한다. 1과 2는 **둘 다 system 데몬**이므로 "데몬이라서"는
설명이 되지 않는다. responsible process(부모 데몬 바이너리)의 FDA가 자식에게 상속되는
것으로 본다. macOS 13+ 의 네트워크 볼륨 TCC가 SMB 마운트 readdir에 적용된다.

**`umount` (층 4-b) — TCC 기각. 나머지는 미결.**

- **(a) 실행 컨텍스트** — launchd system 도메인 vs 로그인 세션.
- **(b) 대상 마운트의 소유자** — root 소유 마운트는 직접 언마운트 불가?

> **관측 6은 무효다 (08-08).** `sudo /bin/ls` 로 만든 FOREIGN을 **watch 데몬이 2초 만에
> 교정**해 버렸고, 세 번째 `umount` 를 칠 때는 이미 sanha 마운트였다. `mount | grep` 이
> 그 2초 창 안에 찍혀 FOREIGN으로 보였을 뿐이다. **측정 대상이 측정 중에 바뀌었다** —
> 자기 치유 시스템을 대상으로 하는 실험의 고유한 함정이며, 원칙 22의 유래다.
>
> 부수 확인: 이때 `sudo umount -f` 가 비밀번호를 묻지 않은 것은 `smb-remount` 의
> NOPASSWD 규칙이 `sudo umount -f /opt/stewardlabs` 와 정확히 일치했기 때문이다.
> "sudo가 불필요하면 안 묻는다"가 아니다 — sudo는 항상 권한 확인을 한다.

**기각된 가설 3건**
- "슬립 전환 중 커널 차단" — 시나리오 A(12:19)는 슬립과 무관한 수동 재현인데도 EPERM.
- "`umount` 가 저수준 도구라 실패가 잦다" — 왜 터미널에서만 성공하는지 설명하지 못한다.
- "네트워크 볼륨 TCC" — FDA 없는 Terminal.app에서 성공(관측 5).

**08-08 판별 실험 1차 결과** (`probe-layer4b.sh`, watch 데몬 정지 상태)

| 실행 | FOREIGN 생성 | `umount -f` 결과 |
|---|---|---|
| iTerm2 (FDA 있음) | **실패 — HEALTHY가 됨** | 측정 불가 |
| Terminal.app (FDA 없음) | 성공 (`mounted by` 부재 확인) | **exit=0, 성공** |

**→ (b) 마운트 소유자 가설 기각.** root 소유 마운트여도 로그인 세션에서는 언마운트된다.

**→ 부수 발견: FOREIGN 생성은 경합이다** (아래 별도 항목).

**조사 종료 (08-08 16:37~16:49, probe v2 4회 실행).**

| 실행 | 경합 재시도 | 라운드 1 (지연 후) | 라운드 2 (즉시) |
|---|---|---|---|
| Terminal.app #1 | 1회 | exit=0 | exit=0 |
| Terminal.app #2 | 3회 | exit=0 | exit=0 |
| iTerm2 #1 | 0회 | exit=0 | exit=0 |
| iTerm2 #2 | 3회 | exit=0 | exit=0 |

라운드 1·2 전건 성공 → **(c) 타이밍 기각.** 남은 것은 (a) 실행 컨텍스트뿐이며 셸에서
재현할 수 없다. 기능 영향이 없으므로(diskutil이 1단계) **여기서 종료한다.**

**기각된 가설 최종 5건**: TCC/FDA · 마운트 소유자 · 슬립 전환 커널 차단 ·
umount 저수준 특성 · 타이밍. 남은 (a)는 미확정이나, 후임 조사자는 이 5건을
재검증할 필요가 없다 — 그것이 이 기록의 목적이다.

**경합의 추가 근거**: 워크스페이스 관련 인스턴스가 전혀 없는 환경(터미널 2개, Finder
모두 ~/Downloads)에서도 재시도가 0~3회로 실행마다 달랐다. 경쟁자는 사용자 앱만이
아니라 **Spotlight(mds)·QuickLook·Finder 백그라운드 등 시스템 프로세스를 포함**한다.
하이재킹의 비결정성이 재확인된다.

### 부기 2 — 층 4 하이재킹은 경합이다 (08-08 신규)

probe 1차 실행에서 **root의 `/bin/ls` 가 sanha 마운트를 만드는** 현상이 나왔다.
FDA 때문은 아니다 — root의 `ls` 가 FDA 유무로 sanha 자격이 될 이유가 없고, 같은
iTerm2에서 14:41에는 FOREIGN 생성에 성공한 이력이 있다.

**설명: 언마운트 직후의 빈 창에서 먼저 트리거한 쪽이 마운트 소유자가 된다.**
`/opt/stewardlabs` 는 워크스페이스이므로 에디터·LSP·파일 감시기·다른 셸의 cwd 등
sanha 프로세스가 상시 접근한다. 갓 연 Terminal.app 세션에는 그런 프로세스가 없어
root의 `ls` 가 이겼고, 작업 중이던 iTerm2 환경에서는 sanha 쪽이 먼저 이겼다.

**운영상 의미** — 층 4 하이재킹이 왜 결정론적이지 않은지를 설명한다.
만료 창이 열려도 sanha 쪽이 먼저 트리거하면 하이재킹은 일어나지 않는다.
08-07 실측의 "만료 후 28분 / 10초" 라는 큰 편차도 이 경합으로 읽힌다.
`AUTOMOUNT_TIMEOUT=604800` 이 창 자체를 없애는 처방인 이유가 한 번 더 뒷받침된다.

**부수: 시나리오 A 재현 시 주의.** FOREIGN을 인위적으로 만들려면 워크스페이스를
건드리는 프로세스를 먼저 정리해야 한다. probe v2는 최대 5회 재시도하고, 계속
지면 그 사실을 명시한다.

**중요**: 어느 가설이 맞든 **v14.3의 순서 반전 결론은 그대로 유효하다.** 근거는
"데몬 컨텍스트에서 항상 실패한다"는 사실 자체였고, 원인 규명은 진단 정확도의 문제다.

| 4 root 소유 마운트 | `backupd` 30분 주기. `tmutil disable` 무효. **디렉터리 open만 autofs 트리거.** 사용자별 마운트 공존 없음. **08-08 신규: 하이재킹은 경합이다** — 빈 창에서 먼저 트리거한 쪽이 소유자가 된다 | 창 제거(층 0) + smb-guard 즉시 교정 |

### 에러 코드 지도 (v13 유지)
| 증상 | 의미 | 조치 |
|---|---|---|
| `ls: ...: Operation not permitted` | TCC의 `readdir` 거부 (FDA 없는 데몬 컨텍스트) | **무시 — 기능 정상.** `open()` 은 이미 발생했으므로 트리거는 성립. 판정은 mount 테이블로 |
| `umount: unmount(...): Operation not permitted` | 데몬 컨텍스트의 언마운트 거부(층 4-b). **원인 미확정, TCC는 아님** | v14.3부터 `diskutil` 이 1단계이므로 훅에서는 이 메시지가 나오지 않는다. **나온다면 diskutil이 먼저 실패했다는 뜻 — 조사 대상** |
| `Permission denied` (EACCES) | root 소유 마운트 | smb-guard가 자동 교정 / 수동은 `smbfix` |
| mount 라인에 `mounted by` 없음 | root 마운트 | 상동 |
| `No locks available` (ENOLCK) | automountd 마운트 실패. 08-07 맵 비번 제거 시 관측(+21h 스큐 병존, 단일 원인 미확정). 비번 복원으로 해소 | 맵 자격증명 → 시계 → §6 로그 |
| `Too many users` (EUSERS) | 맥 커널 smbfs 세션 잔재 고착 | VM 재부팅 (`prlctl restart devm`) |
| mount 라인의 `//sanha@devm/...` | **SMB 인증 계정 표기일 뿐, 마운트 소유자가 아님** | 소유자 판정은 `mounted by` 필드로만 |
| **중단된 복사 잔재** — Finder에서 흐린 폴더 + ⟳, 내부 파일 600 권한 (v17) | -8062 중단 후 CopyEngine이 최종 권한·메타데이터를 입히지 못한 상태. 고장이 아니라 미완의 흔적 | 재개하지 말고 `rm -rf` 후 원인 해소(§10.6) 뒤 재복사. Finder로는 안 열리므로 셸에서 |
| **Finder `오류 코드 -8062`** (v17) | Finder CopyEngine이 **부수 파일** 쓰기에 실패해 복사 전체를 중단(층 5). **복사 대상 파일 자체의 문제가 아니다** — 권한·용량·이름으로 오진하기 쉽다 | `log stream --predicate 'subsystem == "com.apple.DesktopServices"' --info` 를 켜고 재현 → `Error -8062 at path: <경로> on write` 로 **실패 경로가 실명으로 찍힌다**. 그 경로가 서버측 차단 대상이면 차단을 푼다(§10.6) |

## 2. 확정 구성 (v14)

파일 전문은 부록 A. 여기서는 목록과 요지. **굵게 표시된 항목이 v14 변경분.**

**맥 (macOS)**
| 항목 | 위치 | 요지 |
|---|---|---|
| autofs 마스터 맵 | `/etc/auto_master` | `/- auto_smb -nosuid` 직접 맵 (실물 확인 완료) |
| SMB 맵 | `/etc/auto_smb` (600 root) | `/opt/stewardlabs -fstype=smbfs,soft ://sanha:<URL인코딩비번>@devm/stewardlabs`. **`soft` 실물 확인** — smb-guard `TRIGGER_TIMEOUT=15` 의 전제 |
| autofs 설정 | `/etc/autofs.conf` | `AUTOMOUNT_TIMEOUT=604800` **실물 확인**, `AUTOMOUNTD_MNTOPTS=nosuid,nodev`, `AUTOMOUNTD_NOSUID=TRUE`. 전역 설정임에 유의 |
| **공용 라이브러리** | **`/usr/local/lib/smb-guard/common.sh` (root:wheel 644)** | **신규.** 상수·로깅·상태 판정·자격 전환. source 전용(실행 비트 없음). **교정 코드는 넣지 않는다** (§3.2) |
| smb-guard | `/usr/local/sbin/smb-guard` (root:wheel 755) | 유일한 교정 주체. **`--state` 모드 추가**, **잠금 처리 수정(§3.1)** |
| StartOnMount 데몬 | `/Library/LaunchDaemons/io.stewardlabs.smb-guard.plist` | 모든 마운트 이벤트에 guard(watch) 발화. **StandardErrorPath만 `/var/log/smb/` 로 이관** |
| **sleep 훅** | **`/usr/local/sbin/smb-guard-sleep` (755)** | 구 `~/.sleep`. no-unmount 유지, 기록만 |
| **wakeup 훅** | **`/usr/local/sbin/smb-guard-wakeup` (755)** | 구 `~/.wakeup` v13 → **v14**: bash 변환, root 컨텍스트 대응 |
| **수동 복구** | **`/usr/local/sbin/smbfix` (755)** | 구 `~/bin/smbfix` v4 → **v5**: bash 변환, 자체 sudo 승격 |
| **sleepwatcher** | **`/Library/LaunchDaemons/io.stewardlabs.sleepwatcher.plist`** | **brew services → 자체 LaunchDaemon.** `-s smb-guard-sleep -w smb-guard-wakeup`. `-V` 미사용(§3.4) |
| **로그** | **`/var/log/smb/smb-guard.log`** | **4개 스크립트 통합.** 태그로 구분: `[watch] [ensure] [remount] [sleep] [wakeup +Ns] [smbfix]` |
| **로그 회전** | **`/etc/newsyslog.d/io.stewardlabs.smb.conf` (root:wheel 644)** | **신규.** 1MB × 7세대 bzip2. truncate 아닌 세대 이동 |
| **런타임 상태** | **`/var/run/smb-guard/{lock,last_sleep}`** | 구 `~/.sleepwatcher.last_sleep`. 재부팅 시 소멸 — 의도된 동작 |
| sudoers | ~~`/etc/sudoers.d/smb-guard`~~ | **v14에서 불필요·제거.** 훅이 root로 실행되므로 sanha→guard NOPASSWD가 필요 없다 |
| sudoers (기존) | `/etc/sudoers.d/smb-remount` | umount -f / automount -vc / diskutil unmount force — 응급 수동 조작용으로 존치 |
| Time Machine | `tmutil addexclusion -p ~/Parallels/devm.pvm` | 경로 기반 제외. **.pvm 이동 시 재설정 필요** |
| git | `~/.config/git/config` | `[includeIf "gitdir:/opt/stewardlabs/"]` 조건부 include (EUSERS 증폭기 제거) |
| **.DS_Store 방어** | **system 도메인 `DSDontWriteNetworkStores=true` + 전역 gitignore + repo `.git/info/exclude` + VM `mac-cruft-cleanup.timer`** | **v17 재설계.** 서버측 `veto files` 는 폐지 — 차단은 Finder를 깨뜨린다(층 5). 클라이언트 억제는 **보조**일 뿐 전제가 아니다(원칙 27). 사용자 도메인 `defaults` 는 프로필 재생성으로 소실되므로 `/Library/Preferences` 로 승격 |
| 전원 정책 | AC: 화면 잠금 후 미수면 / 배터리: claude-caffeinate(-i) | 뚜껑 닫기는 항상 수면(의도). `disablesleep` 기각(§7) |

**VM (Ubuntu 26.04, devm — 상시 기동, headless)** — v13에서 변경 없음
| 항목 | 위치 | 요지 |
|---|---|---|
| Samba | `/etc/samba/smb.conf` | SMB3+, ea support, spotlight=no, vfs fruit/catia/streams_xattr, case sensitive. **v17: `veto files` 폐지 · `fruit:resource = file` 명시** (A.13) |
| **macOS 잔재 정리** | **`/usr/local/sbin/mac-cruft-cleanup` + `mac-cruft-cleanup.{service,timer}`** | **v17 신규.** **v1.2** — 15분 주기, `.DS_Store`/`._*`/`.TemporaryItems` 등 즉시 회수, `.Trashes` 는 7일 유예. `PRUNE_NAMES` 로 순회 제외(기본 `.git .Trashes target node_modules`, 이름 기준이라 깊이 무관). 제거 건수는 journald에 남아 관찰 신호가 된다(§6) |
| clockfix | `/usr/local/sbin/clockfix` + `/etc/sudoers.d/clockfix` | epoch 인자로 `date -s`, NOPASSWD |
| chrony | `/etc/chrony/chrony.conf` | `makestep 1 -1`. prltimesync 단일 장애점의 폴백 |
| Parallels Tools | 26.1+ 드라이버리스 | prltimesync + hosts 등록 |
| avahi | disabled | 수 주 무사고 후 purge 후보 |

## 3. v14 변경 상세

### 3.1 v13 코드의 버그 2건 (배치 작업 중 발견 — 수정 완료)

**(a) 잠금 실패 시 거짓 성공.** v13 smb-guard는 잠금 획득 실패 시 모드와 무관하게
`exit 0` 한다. `watch`에서는 올바르다 — 다른 인스턴스가 이미 처리 중이다. 그러나
wakeup이 호출하는 `--ensure`에서는 **아무 일도 하지 않고 성공을 반환**한다.
wakeup은 마운트가 보장됐다고 믿고 생존성 프로브로 넘어간다.

발현 조건: wake 직후 `--ensure` 실행 시점에 마운트 이벤트로 watch 인스턴스가 떠 있으면
경합한다. wake 직후는 정확히 그런 구간이다 — 확률이 낮지 않다.

```
watch          → acquire_lock 1  || exit 0   # 즉시 물러남 (v13 동작 유지)
ensure/remount → acquire_lock 30 || exit 1   # 최대 30초 대기, 실패 시 정직하게 실패
```

**(b) 유령 잠금.** 인스턴스가 SIGKILL 등으로 죽으면 EXIT trap이 돌지 않아
`/var/run/smb-guard/lock` 이 영구히 남는다. **그 시점부터 guard 전체가 침묵한다.**
로그에도 아무것도 남지 않는 무증상 고장이므로 발견이 극도로 늦다.

120초(= `TRIGGER_TIMEOUT` 15s의 여유배수)를 넘긴 잠금은 죽은 인스턴스의 잔재로 간주하고
제거한 뒤 진행한다. 제거 사실은 로그에 남긴다.

**(c) 부수: `--state` 추가.** 부작용 없는 판정 조회. `smb-guard --state` → ABSENT /
HEALTHY / FOREIGN. 잠금도 root도 요구하지 않는다. §8-8 원칙(판정 행위가 대상을 바꾸지
않게 하라)의 도구화.

### 3.2 라이브러리 분리의 경계선

4개 스크립트가 로그 형식·마운트 경로·소유자 이름을 각자 갖고 있으면 시간이 지나며
갈라진다. 그래서 공용부를 뺐다. 단 **경계를 명확히 그었다**:

- **`common.sh` 에 두는 것 — 읽기 전용만**: 상수(`SMBG_MP`, `SMBG_OWNER`, 경로),
  `log()` / `say()`, `smbg_state()`, 자격 전환 래퍼.
- **`smb-guard` 에만 두는 것 — 상태를 바꾸는 것 전부**: `force_umount()`,
  `trigger_as_owner()`, `ensure_owner_mount()`.

v13의 "판정·교정 단일화" 계약이 지키려던 불변식은 **"교정 주체는 하나"** 이지
"코드가 한 파일에 있다"가 아니다. 판정 로직을 공유하는 것은 오히려 판정 기준의 분기를
막으므로 계약을 강화한다. 교정 원시연산을 라이브러리로 내리는 것만이 계약 위반이다.

### 3.3 root 컨텍스트 전환 — 사용자 자격이 필요한 4개 지점

sleepwatcher가 user LaunchAgent → system LaunchDaemon으로 바뀌면서 훅이 root로 돈다.
그런데 v13 wakeup/smbfix에는 사용자 자격이 필요한 호출이 있다. 각각 명시적으로 전환한다.

| 호출 | 사용자 자격이 필요한 이유 | 전환 수단 |
|---|---|---|
| `ssh devm` | `~/.ssh/config` 의 `devm` 별칭과 키가 sanha 소유 | `smbg_as_owner` = `sudo -u sanha -H` |
| `open develop_mount.app` | GUI 세션(Aqua) 필요 | `smbg_in_session` = `launchctl asuser` |
| 트리거·생존성 `ls` | 소유자 관점의 접근성이 측정 대상 | `smbg_in_session` |
| smbfix의 `mount_smbfs` 프로브 | **로그인 키체인의 SMB 자격증명** | `smbg_in_session` |

마지막 항목이 특히 중요하다. root 컨텍스트에서는 로그인 키체인이 잠겨 있어 조회되지
않으므로, **실제 원인과 무관한 인증 실패로 오진**하게 된다 — §8-2 원칙(감시 채널의
권한 경계를 의심하라)의 재발이다.

래퍼는 양쪽 도메인에서 성립하도록 작성했다. `smbg_as_owner`는 이미 소유자면 `sudo` 없이
직접 실행하고, `smbg_guard`는 root면 직접·아니면 `sudo -n`으로 호출한다. **user 도메인
LaunchAgent로 롤백해도 코드 수정 없이 동작한다.**

> **최대 위험 — 배치 전 반드시 확인할 것.**
> `sudo -u sanha -H ssh` 는 `SSH_AUTH_SOCK` 을 상속하지 않는다. 키에 패스프레이즈가
> 걸려 있고 ssh-agent에 의존한다면 `BatchMode=yes` 가 실패하고, **층 1 대응(clockfix)이
> 통째로 무력화된다.** §9.3의 첫 항목으로 검증한다.
> 실패 시 선택지: (1) 패스프레이즈 없는 전용 키를 sanha `~/.ssh/config` 의 devm 항목에
> 지정, (2) sleepwatcher를 user 도메인 LaunchAgent로 유지(§3.5 롤백).

### 3.4 로그 통합과 회전

**통합.** `[wakeup]` `[watch]` `[smbfix]` 태그로 구분되므로 파일을 나눌 실익이 없다.
오히려 v13에서 `~/.sleepwatcher.log` 와 `/var/log/smb-guard.log` 로 갈라져 있어,
wake → guard 발화 → smbfix의 인과를 추적할 때마다 타임스탬프를 손으로 대조해야 했다.
단일 시간순 스트림이 사후 추적에 결정적으로 낫다.

wakeup의 상대시간 로그는 태그 훅 재정의로 보존했다:
```
2026-08-08 14:23:01 [wakeup +12s] network up
```

**회전.** v13에는 회전 기제가 없었다(무한 증식). macOS 네이티브 `newsyslog`를 쓴다.
**truncate가 아니라 세대 이동**이다 — 오래된 것부터 밀려나고 최근 내용은 보존된다:
```
smb-guard.log → .0.bz2 → .1.bz2 → ... → .6.bz2 → 삭제
```

**주의 — 상주 프로세스와 회전의 상호작용.** `smb-guard` 는 `StartOnMount` 잡이라
이벤트마다 뜨고 죽는다. fd를 붙잡지 않으므로 회전이 안전하다. 반면 **sleepwatcher는
`KeepAlive` 상주 프로세스**라 `StandardErrorPath` 의 fd를 계속 쥔다. 회전 후에도
이동한 inode에 쓴다. 그래서 plist에서 **`-V`(verbose)를 뺐다** — 출력이 거의 없으면
실질적 영향이 없다. 디버깅 목적으로 `-V` 를 켠다면 끝난 뒤 되돌릴 것.

### 3.5 셸 통일 (zsh → bash)

`smbfix`·`_wakeup` 이 zsh, `smb-guard` 가 bash였다. 공용 라이브러리를 양쪽에서
안전하게 source하려면 문법 제약이 생기므로 코어 쪽인 bash로 통일했다.
대상은 macOS 기본 `/bin/bash`(3.2)이며, 3.2에 없는 기능은 쓰지 않는다.

실제 변환 지점 3개:

| zsh | bash |
|---|---|
| `[[ "$remote" == <-> ]]` (숫자 글로브) | `[[ "$remote" =~ ^[0-9]+$ ]]` |
| `SSH=(...)` → `$SSH` 평탄화 | `guest_ssh()` 함수 |
| `exec >> $HOME/.sleepwatcher.log 2>&1` | `exec 2>>"$SMBG_LOG"` + 구조화 `log()` |

### 3.6 sleepwatcher를 brew services에서 뗀 이유

1. **brew가 생성하는 plist는 재생성된다.** Homebrew는 formula의 `service` DSL로
   plist를 만들므로 `brew upgrade` / `brew services restart` 시 손수정이 소실된다.
   `-s` / `-w` 경로 지정이 날아가면 sleepwatcher는 기본값(`~/.sleep`, `~/.wakeup`)을
   찾고, 그 파일이 없으면 훅이 침묵 실패한다 — §8-6 원칙(설정이 실제로 적용되었는지
   먼저 검증하라)이 걸리는 전형적 지점.
2. smb-guard와 같은 system 도메인 = 같은 UID, 같은 로그 경로, sudoers 불필요.
3. 로그아웃/로그인 화면 상태의 슬립·웨이크도 커버된다.

**롤백 경로**: brew 서비스로 되돌리려면 `sudo launchctl bootout
system/io.stewardlabs.sleepwatcher` 후 `brew services start sleepwatcher`. 단
`~/.sleep`/`~/.wakeup` 을 복원해야 하므로 `cleanup.sh` 실행 전이어야 한다.
`cleanup.sh --apply` 는 삭제 전 `/var/backups/smb-guard-v13-<타임스탬프>/` 에 백업한다.

### 3.7 v14.1 수정 (08-08 설치·검증 중 발견)

**(a) `install.sh` 의 sleepwatcher 경로 탐지 버그 — 설치 차단.**
```bash
awk -F'[<>]' '/sleepwatcher</{print $3; exit}' "$PLIST"    # v14.0 — 틀림
```
`/sleepwatcher</` 는 `<string>io.stewardlabs.sleepwatcher</string>`(Label **값**)에도
매칭된다. `exit` 로 첫 매칭에서 멈추므로 `SW="io.stewardlabs.sleepwatcher"` 가 잡히고,
정상 설치인데도 `-x` 검사에 실패해 `exit 1` 한다. 재현 확인 완료.

부수 결함 2건: 매칭이 없으면 `SW=""` 가 되어 `[ ! -x "" ]` 가 참 → 빈 경로로 오류 출력.
그리고 `/Library/LaunchDaemons` 의 plist가 **바이너리 포맷이면 텍스트 파싱이 통째로
불가능**하다.

→ **PlistBuddy로 교체.** 텍스트·바이너리 양쪽에서 동작하며 키 경로를 정확히 지정한다.
```bash
SW="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$SWPLIST" 2>/dev/null || true)"
[ -n "$SW" ] || SW="$(/usr/libexec/PlistBuddy -c 'Print :Program' "$SWPLIST" 2>/dev/null || true)"
[ -z "$SW" ] && { echo "plist에서 실행 경로를 읽지 못했습니다"; exit 1; }
```
안내 문구도 `which sleepwatcher` → `"$(brew --prefix)/sbin/sleepwatcher"` 로 바꿨다.
Homebrew는 `sbin` 에 설치하는데 그 경로가 PATH에 없는 경우가 흔하다.

**(b) stdout 유실 — plist에 `StandardOutPath` 부재.**
훅 스크립트는 `exec 2>>"$SMBG_LOG"` 로 stderr만 잡았고, stdout은 sleepwatcher에서
상속받은 것을 썼다. 그런데 plist에 `StandardOutPath` 가 없으면 launchd가 `/dev/null` 로
보낸다. **일부 도구는 에러를 stdout으로 내보내므로 그 증거가 통째로 사라진다** —
§9-3 원칙(판정은 1차 증거로) 위반.

→ 두 층에서 막는다.
1. 훅 스크립트: `exec >>"$SMBG_LOG" 2>&1`. 스크립트 내부의 모든 누출이 메인 로그로 간다.
   **태그 없는 줄이 보이면 그 자체가 "누출 발생" 신호**라 진단에 유리하다.
2. 두 plist: `StandardOutPath` 를 `StandardErrorPath` 와 **같은 파일**로 지정. 스크립트가
   `exec` 에 도달하기 전의 실패(shebang 오류 등)와 sleepwatcher 자체 출력까지 잡는다.

**(c) `pmset -g log` 가 임계 경로를 11초 지연 — 성능 목표 미달의 유일한 원인.**
08-08 실측 로그:
```
11:49:04 [wakeup  +2s] slept for 707s
11:49:15 [wakeup +13s] last wake event: ...      ← 사이의 코드는 pmset -g log 하나뿐
```
`pmset -g log` 는 전원 로그 전체를 파싱한다. v13/v14.0에서 이 호출이 게이트 직후에
있어, **순수 관찰용 코드가 네트워크 대기·clockfix·마운트 보장 전부를 11초 뒤로 밀었다.**
웨이크(11:49:01) → 사용 가능(11:49:16) = 15초 중 11초가 이것이다.

→ 스크립트 **끝**으로 이관. 마운트가 이미 사용 가능해진 뒤이므로 체감 지연이 없고,
관찰 데이터의 유효성은 동일하다. 아울러 출력의 탭·연속 공백을 `tr -s ' \t' ' '` 로
압축했다(로그 줄이 과도하게 넓어지는 문제). pmset 자체 타임스탬프는 **남긴다** —
끝으로 옮기면서 `log()` 시각과 멀어졌으므로 "실제 웨이크 시각 vs 훅 발화 시각" 대조에
필요해졌다.

**(d) `clockfix: clockfix:` 접두사 중복.**
wakeup이 `log "clockfix: $l"` 로 접두사를 붙이는데 VM의 clockfix 스크립트 출력 자체가
`clockfix: ` 로 시작한다. 원격 출력이 이미 자기를 식별하므로 접두사를 제거하고 원문
그대로 기록한다. 빈 줄도 걸러낸다.

**(e) `=== wakeup 종료 ===` 추가.** 시작 줄만 있고 종료 줄이 없어, 중간 `exit 0` 경로
(네트워크 미복구, smbd 미응답)와 정상 완주를 로그만으로 구분하기 어려웠다.

### 3.9 v14.2 수정 — 로그가 인과를 보여주지 못한 문제 (08-08 시나리오 A)

시나리오 A의 원 로그:
```
12:19:18 [watch] FOREIGN 감지 — 교정 시작
umount: unmount(/opt/stewardlabs): Operation not permitted
Unmount successful for /opt/stewardlabs
ls: /opt/stewardlabs: Operation not permitted
12:19:20 [watch] 교정 완료 → HEALTHY
```
**동작은 전부 정상이었다.** 그러나 "실패 → 성공 → 실패 → 완료" 로 읽혀 모순처럼 보인다.
원인은 v14.1에서 stdout까지 잡기 시작하면서 **서브커맨드 원문이 태그 없이 태그 줄 사이에
끼어들었고, 각 줄이 예상된 것인지 진짜 실패인지 로그에 적혀 있지 않았기** 때문이다.

**(a) 원인이 된 두 줄의 정체**
- `umount ... Operation not permitted` — `force_umount` 의 1단계 실패. 곧바로 2단계
  `diskutil unmount force` 로 넘어가 성공(다음 줄). **폴백 체인이 설계대로 동작한 것.**
  autofs 트리거 지점은 직접 언마운트가 거부되므로 이 실패는 **매번 발생하는 정상 경로**다.
- `ls ... Operation not permitted` — 층 3. `ls` 의 목적은 디렉터리 `open()` 으로 autofs를
  트리거하는 것이지 내용을 읽는 것이 아니다. 순서는
  `open() → autofs 트리거 → automountd가 sanha 자격으로 mount_smbfs → 마운트 성사`
  → 그 다음 `readdir` 가 TCC에 거부되어 EPERM 출력. 마운트는 이미 성사돼 있다.

**(b) 조치 — 원문을 버리지 않고 태그 안에 담는다.**
`common.sh` 에 `smbg_oneline()` (개행·연속 공백 압축)을 추가하고, `force_umount` /
`trigger_as_owner` / `ensure_owner_mount` 가 서브커맨드 출력을 캡처해 `log()` 로 기록하되
**예상된 실패에는 "(예상됨)" 을 명시**하고 각 단계 뒤의 `state=` 를 함께 남기도록 했다.
결과:
```
[watch] FOREIGN 감지 — 교정 시작
[watch] umount -f 실패(예상됨 — autofs 트리거 지점) → diskutil 폴백: umount: unmount(...): Operation not permitted
[watch] diskutil unmount force 성공 → state=ABSENT
[watch] 트리거 ls EPERM(예상됨 — 층 3, open은 이미 발생) → state=HEALTHY
[watch] 교정 완료 → HEALTHY
```
`FOREIGN → ABSENT → HEALTHY` 의 상태 전이가 그대로 읽힌다.

**(c) 부수 발견 — 데몬별 TCC 귀속 차이.**
| 시각 | 컨텍스트 | 트리거/프로브 ls |
|---|---|---|
| 11:49:16 | sleepwatcher 데몬 → asuser → ls | `ls ok, 0s` |
| 12:19:19 | smb-guard 데몬 → asuser → ls | `EPERM` |

같은 `smbg_in_session` 경로인데 결과가 다르다. **추정**: TCC의 responsible process
귀속 차이. sleepwatcher 바이너리에는 FDA가 부여돼 있고(§2), 그 자식은 권한 맥락을
물려받는다. smb-guard(FDA 없음)의 자식은 못 받는다. macOS 13+ 는 네트워크 볼륨 접근을
TCC로 관리하므로 SMB 마운트가 여기 걸린다.
확인 방법: 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한 목록.

**조치하지 않는다.** 셸 스크립트에 대한 FDA는 인터프리터(`/bin/bash`)에 귀속되므로,
smb-guard에 FDA를 주는 것은 사실상 시스템 전역에 광범위한 권한을 여는 일이다.
현 설계는 ls 결과를 쓰지 않으므로 FDA 없이 정확히 동작한다 —
**§9-3(판정은 1차 증거로) 원칙이 실제로 값을 한 사례.**

### 3.11 v14.5 — sudoers 권한 이상과 정리 스크립트의 침묵 종료

**(a) `/etc/sudoers.d/smb-remount` 의 권한이 0640이다 (기대 0440).**
```
-r--r-----  root wheel  smb-guard      ← 0440, 정상
-rw-r-----  root wheel  smb-remount    ← 0640
$ sudo visudo -c
/private/etc/sudoers.d/smb-remount: bad permissions, should be mode 0440
```
**08-08 실측으로 확정: 이 파일은 유효했다.**
```
$ sudo -l -U sanha | grep -iE 'umount|automount|diskutil'
    (root) NOPASSWD: /sbin/umount -f /opt/stewardlabs, /usr/sbin/automount -vc,
                     /usr/sbin/diskutil unmount force /opt/stewardlabs
```
즉 **sudo 런타임은 0640을 받아들이고 visudo만 0440을 요구한다.** sudo의 실질 검사는
"group/other 쓰기 가능" 여부인데 0640은 쓰기 가능이 아니어서 통과한 것으로 보인다.
`visudo -c` 의 경고를 "규칙이 무효"로 읽으면 오판이다 — 별개의 기준이다.

**조치: 삭제 완료 (08-08, `cleanup.sh --apply --purge-sudoers`).**
유효한 규칙이었으나 v14 스크립트 중 사용처가 없다 — 쓰지 않는 NOPASSWD는 상시 권한
부여이므로 회수한다. 이후 `sudo umount -f` 는 비밀번호를 묻는다(정상).

`cleanup.sh` 가 권한을 감사하되 **자동 교정하지 않는** 설계는 유지한다. 이번에는
"유효했다"로 밝혀졌지만, 인효인 파일의 권한을 고치는 것은 부여된 적 없는 권한을
새로 여는 일이기 때문이다(원칙 21).

원칙 6("설정이 실제로 적용되었는지 먼저 검증하라")의 세 번째 사례다 —
앞선 둘은 `AUTOMOUNT_TIMEOUT` 부재와 smbfix의 clockfix 미실행이었다.
다만 이번 사례의 교훈은 방향이 반대다: **경고가 곧 무효는 아니었다.**
"검증"은 경고를 읽는 것이 아니라 실효를 직접 조회하는 것(`sudo -l`)이었다.

**(b) `set -e` 하에서 명령치환 할당이 셸을 침묵 종료시킨다.**
```bash
set -eu
m="$(stat -f %Lp "$f" 2>/dev/null)"   # stat 실패 → 할당의 종료코드 비0 → 셸 즉시 종료
```
`local m="$(...)"` 는 `local` 의 종료코드(0)가 우선하므로 발동하지 않지만, 선언과 할당을
분리하면 할당문의 종료코드가 그대로 노출된다. **정리 스크립트가 중간에 말없이 죽으면
부분 삭제 상태로 남는다** — 최악의 실패 양식이다.

조치 3건:
1. 해당 할당에 `|| true` 를 붙이고 결과 형식을 검증(`stat -f` 는 BSD/GNU 의미가 다르다).
2. `cleanup.sh` / `install.sh` 에 **EXIT trap** 추가 — 비0 종료 시 부분 실행 사실과
   확인 명령을 출력한다.
3. `[ cond ] && cmd` 패턴은 `set -e` 를 발동시키지 **않음**을 실측 확인(AND 리스트의
   좌변은 면제).

**(c) v14.6 추가 — EXIT trap의 오탐.**
`set -e` 는 발동하지 않지만 **종료 코드는 남는다.** 스크립트의 마지막 문장이
`[ cond ] && cmd` 이고 cond가 거짓이면, 그 1이 곧 스크립트의 종료 코드가 되어
EXIT trap이 정상 완료를 오류로 보고한다. 08-08 `cleanup.sh --apply --purge-sudoers`
실행에서 실제로 발생했다(정리는 정상 완료, 마지막에 "예기치 못한 오류" 오탐).

조치: 마지막의 AND 리스트를 `if` 로 바꾸고 **명시적 `exit 0`** 을 추가.
trap 본문도 `[ ] && { }` 에서 `if` 로 바꿨다 — trap 본문의 반환값이 종료 상태를
건드릴 여지를 없앤다.

**교훈**: 실패를 알리는 장치가 오탐하면, 다음번 진짜 실패도 무시된다.
경보 장치 자체를 정상 경로에서 검증해야 한다.

### 3.12 v14.8 — wake event 로그의 컬럼 경계 소실

`pmset -g log` 의 출력은 탭 구분 컬럼 구조다: `시각 도메인(Wake/DarkWake)<탭>상세...`.
v14.1의 공백 압축(`tr -s ' \t' ' '`)이 **컬럼 경계(탭)를 지워** 도메인과 상세의 첫
단어가 붙었다 — `... +0900 Wake Wake from Deep Idle ...` (08-08 관측).

검토한 3안 중 "구분자 삽입"을 채택했다. 도메인 필드 제거안은 기각 — 그 값은 고정이
아니라 `DarkWake` 일 수 있고, **DarkWake 여부가 층 2 판정의 1차 증거**다.

구현은 도메인 단어를 정규식으로 찾는 대신 **탭 자체를 ' — ' 로 치환**한다. pmset의
컬럼 배치가 바뀌어도 깨지지 않고, 탭이 없는 형식에서는 무해하게 통과한다.
```
2026-08-08 16:30:21 +0900 Wake — Wake from Deep Idle [CDNVA] : due to ...
```

### 3.10 v14.3 — `force_umount` 순서 반전

v14.2까지의 순서는 `umount -f` → `diskutil unmount force` 였다. 그런데 훅 컨텍스트에서는
**1단계가 100% 실패한다**(층 4-b — 원인은 미확정이나 사실은 확실하다). 매번 실패를
확인하는 데 시간과 로그를 쓰는 셈이다.

그렇다고 `umount` 를 **삭제**하지는 않는다. `diskutil` 은 diskarbitrationd에 의존하므로,
그 데몬이 응답하지 않으면 실패한다. 그 상황에서 커널을 직접 호출하는 `umount -f` 는
여전히 성공할 수 있고, 특히 **FDA를 가진 터미널에서 실행되는 smbfix 경로**에서는 실효가
있다. 안전망을 버리는 대신 **순서를 뒤집는다.**

| | 1단계 | 2단계 |
|---|---|---|
| ~v14.2 | `umount -f` (훅에서 항상 실패) | `diskutil` |
| v14.3~ | `diskutil` (DiskArbitration 위임 — 데몬/터미널 모두 성공) | `umount -f` (diskarbitrationd 장애 시, 터미널 경로에서 실효) |

훅에서는 1회 호출로 끝나고 로그도 한 줄이 된다. 코드 복잡도는 동일하다.

**진단상의 부수 효과**: 앞으로 로그에 `umount -f 폴백` 이 보이면 그것은
**diskutil이 실패했다는 신호**이며, 이는 지금까지 관측된 적 없는 상황이므로 조사 대상이다.
v14.2까지는 같은 메시지가 정상 잡음이었다 — 신호 대 잡음비가 개선된다.

### 3.8 정리(cleanup) 시점 판단

08-08 시점에 `cleanup.sh` 를 아직 돌리지 않는 이유는 하나다.

**08-08 wake 로그는 전부 `[ensure] healthy` 였다.** 즉 `smb-guard` 의 교정 경로
(`force_umount` → `trigger_as_owner` → `automount -vc` → 재시도)가 **한 번도 실행되지
않았다.** v14에서 실행 컨텍스트가 root로 바뀐 부분이고, 이 체계 전체의 존재 이유
(층 4 하이재킹 즉시 교정)에 해당하는 코드다.

**→ 08-08 12:19 시나리오 A 통과로 이 우려는 해소됐다.** `force_umount` 폴백,
`trigger_as_owner`, 상태 전이가 모두 실측 확인됐다(2초). 남은 것은 시나리오 B뿐이며,
B는 A의 부분집합(교정 없이 생성만)이라 위험이 거의 없다.

**→ 08-08 12:56 시나리오 B도 통과. `cleanup.sh --apply` 진행 가능하다.**
장시간 수면 테스트는 로직이 아니라 환경 조건의 검증이므로 롤백 대상이 아니다.

v14.3의 `force_umount` 순서 반전은 언마운트 **수단의 우선순위**만 바꾼 것이므로
A를 다시 돌릴 필요는 없다. 다만 재실행하면 로그가 3줄에서 1줄로 줄어드는 것을
확인할 수 있다.

## 4. 훅 체계 v14 — 역할 분담

각 구성요소는 자기만 알 수 있는 정보로 자기만 할 수 있는 일을 한다.
**마운트 교정 로직은 smb-guard 한 곳에만 존재한다.**

| 구성요소 | 트리거 | 담당 | 하지 않는 것 |
|---|---|---|---|
| smb-guard watch (StartOnMount) | 마운트 이벤트 (하이재킹 발생 순간 = 이벤트) | FOREIGN 즉시 교정 | 마운트 생성, 시계 |
| smb-guard-sleep | 수면 직전 | `last_sleep` 기록 + state 1줄 | 언마운트 (no-unmount) |
| smb-guard-wakeup | wake | 게이트 → 네트워크 대기 → clockfix → `guard --ensure` → 생존성 프로브 | 소유권 판정·교정 (→ guard) |
| chrony | 상시 (게스트) | 각성 중 시계 지속 보정 | — |
| clockfix | wakeup / smbfix | resume 직후·수동 시 즉시 step | — |
| smbfix (수동) | 사용자 판단 | 시계 교정 + `guard --remount` + 진단 | 자체 마운트 로직 (→ guard) |

전 구성요소가 이벤트 구동 또는 상시 데몬 — 주기 폴링 없음.

**smb-guard 핵심 계약** (v13에서 유지, 밑줄 친 부분이 v14 보강):
- 판정은 mount 테이블만 (`mounted by sanha` 유무). 경로 접근을 판정에 쓰지 않는다 —
  트리거 유발 방지 + TCC 오판 방지.
- 트리거는 sanha 자격의 디렉터리 open(ls) 하나뿐. ls 종료 코드는 무시하고 mount 테이블
  재조회로 성공 판정.
- watch의 교정이 낳는 새 마운트 이벤트는 재발화 인스턴스가 HEALTHY를 보고 침묵 종료.
  mkdir 잠금 + `ThrottleInterval 5s` 이중 방어.
- watch는 마운트를 만들지 않는다. 부재→생성은 의도가 명시된 `--ensure`/`--remount`의 몫.
- **`--ensure`/`--remount` 는 잠금 경합 시 대기하며, 끝내 못 얻으면 실패를 반환한다**
  (v13 버그 수정 — §3.1a). 호출자가 결과를 신뢰하는 경로이므로 침묵 성공은 금지.
- **GUI 세션 부재 시 트리거가 불가능함을 로그에 명시한다.** `launchctl asuser` 는
  로그아웃 상태에서 실패하므로, 조용히 넘기면 원인 불명의 교정 실패로 보인다.

### 롤백 경로
- **훅만**: `cleanup.sh` 실행 전이라면 `~/.wakeup`(v13)이 그대로 있다.
  sleepwatcher plist의 `-w` 를 `/Users/sanha/.wakeup` 으로 되돌리면 즉시 복귀.
- **sleepwatcher 도메인**: §3.5 참조.
- **guard 전체**: `sudo launchctl bootout system/io.stewardlabs.smb-guard`.
- v11(수면 전 강제 언마운트)로의 롤백은 **비권장** — 층 0/4 규명으로 근거가 소멸했고,
  언마운트는 backupd 창을 다시 연다.

## 5. 검증 기록 (증거 색인)

| 시각 | 조건 | 결과 |
|---|---|---|
| 08-06 15:33~16:08 | 짧은~중간 수면 (FDA 후) | `mount healthy (ls ok)` +5s |
| 08-06 18:10 | 1h, root 마운트 운반 (v9) | EACCES 재현 → 층 4 존재 규명 |
| 08-06 21:14~08-07 04:36 | 밤샘 5사이클, FOREIGN 4회 (v11) | 전건 자동 교정 → +5~8s healthy |
| 08-07 05:12~06:37 | v12: 1h25m, VM 동결 -5063s | carried HEALTHY, ls 0s — 단, **층 0 규명으로 재해석**: 수면 중 만료 검사 미동작 가능성. 재검증 대상 |
| 08-07 주간 | fs_usage 3.5h + log show | **backupd 30분 주기 확정**, 하이재킹 야생 2건(만료 후 28분/10초), 트리거 syscall 규칙, 만료 검사 120s 주기·마운트 시각 기준 |
| 08-07 | `tmutil disable` 후 | 접근 7회 지속 → 무효 확정 |
| 08-07 | 수동 재현 (`sudo ls`) | root 마운트 + sanha EACCES — 층 4 인과 직접 확인, 공존 없음 확인 |
| 08-07 | +76482s 스큐 | clockfix 계열로 해소. prltimesync 무동작 실증 |
| clockfix | -23s ~ -5063s | 항상 0±1s |
| 게이트 | slept 0s/13s | 스킵 정상 |
| **08-08** | **autofs 구성 3종 실물 대조** | `auto_master`/`auto_smb`/`autofs.conf` 모두 문서 기재와 일치. `soft` 존재 확인 → `TRIGGER_TIMEOUT=15` 전제 유효. `AUTOMOUNT_TIMEOUT=604800` 실기입 확인 |
| **08-08 11:13** | v14 설치 후 `pmset sleepnow` (10s) | `[sleep] state=HEALTHY` → `[wakeup] slept for 10s` → 게이트 스킵. **정상** |
| **08-08 11:32** | `pmset sleepnow` 후 3분 방치 시도 | `slept for 1s` 로 게이트 스킵, 이후 로그 없음. **미수면으로 판독** — 재수면했다면 `[sleep]` 이 한 번 더 찍혔어야 한다. AC 전원의 "화면 잠금 후 미수면" 정책과 일치. §7 함정 3종의 실례 |
| **08-08 11:37~11:49** | **뚜껑 닫음, 707초 실수면** | 웨이크 11:49:01 → 훅 발화 +1s → **clockfix `-700s → 0s`** → `[ensure] healthy` → `mount HEALTHY (ls ok, 0s)`. **root 컨텍스트 ssh·asuser 양쪽 실증.** 총 15초 중 11초가 `pmset -g log` (§3.7c) |
| **08-08** | `install.sh` awk 경로 탐지 | **버그 재현 확인** — Label 값이 매칭됨. PlistBuddy로 교체 후 텍스트·바이너리 plist 양쪽 정상 파싱 검증 |
| **08-08 12:19** | **시나리오 A — watch 교정** | **통과, 2초.** FOREIGN 감지 → `umount -f` EPERM(예상) → `diskutil unmount force` 성공 → 트리거 ls EPERM(층 3) → **마운트 성사, HEALTHY**. 층 4 즉시 교정의 야생 실증. 부수: autofs 트리거 지점의 umount 거부(층 4-b 신규), 데몬별 TCC 귀속 차이(§3.9c) |
| **08-08 12:56** | **시나리오 B — 부재에서 생성** | **통과, 2초.** ABSENT → 트리거 → HEALTHY. **트리거 ls에 EPERM 없음**(iTerm2 = FDA 보유) → 층 3·4-b 통합 가설의 결정적 대조군 |
| **08-08** | FDA 부여 목록 확인 | sleepwatcher / AppCleaner / iTerm2. 관측 3건과 정확히 일치 |
| **08-08** | **Terminal.app(FDA 없음) `sudo umount -f`** | **성공 → umount의 TCC 가설 기각.** `ls` 의 TCC 가설은 유지(관측 1·2·4). 두 EPERM은 원인이 다름이 확정 |
| **08-08** | **Terminal.app, root 소유 마운트에 `sudo umount -f`** | **성공 → 마운트 소유자 가설도 기각.** 층 4-b는 실행 컨텍스트 요인만 남음. 조사 중단 결정 |
| **08-08** | `sudo visudo -c` | **`smb-remount` 권한 0640 발견** — 규칙 실효 여부 불확실. 원칙 6의 세 번째 사례 |
| **08-08** | `cleanup.sh` mock 실행 | **`set -e` 침묵 종료 버그 발견·수정.** EXIT trap 추가 |
| **08-08 14:41** | **watch 데몬의 자기 치유가 실험을 오염** | `sudo /bin/ls` 로 만든 FOREIGN을 2초 만에 교정 → 관측 6 무효화. **부수적으로 watch 교정이 한 번 더 실증됨** |
| **08-08** | `sudo -l -U sanha` | **smb-remount 는 0640에서도 유효했음 확정.** sudo 런타임 ≠ visudo 기준 |
| **08-08** | `cleanup.sh --apply --purge-sudoers` | **정리 완료.** 구 훅 3종·상태 파일 3종·sudoers 2종 제거, 백업 `/var/backups/smb-guard-v13-20260808144901`. EXIT trap 오탐 발견 |
| **08-08 15:08** | probe 1차 (iTerm2) | **FOREIGN 생성 실패 → HEALTHY.** 경합 규명의 계기 |
| **08-08 15:12** | probe 1차 (Terminal.app) | FOREIGN 생성 성공 → **`umount -f` exit=0.** (b) 마운트 소유자 가설 기각 |
| **08-08 16:37~16:49** | **probe v2 × 4회 (Terminal.app 2, iTerm2 2)** | **라운드 1·2 전건 exit=0 → (c) 타이밍 기각, 층 4-b 조사 종료.** 경합 재시도 0~3회 변동 — 시스템 프로세스도 경쟁자임을 실증. probe의 remount 복구 4회 전건 정상 |
| **08-08** | `newsyslog -nv` | 3개 파일 파싱 정상, 임계 미달 skipping — **설정 유효 확정** |
| **08-08 17:06~18:49** | **장시간 수면 (1h42m, 배터리, 뚜껑)** | **전 구간 통과.** 게이트 통과(slept 6151s) → 네트워크 +2s → **clockfix -519s → -1s** → ensure healthy → **mount HEALTHY +4s** → wake event `Wake — Wake from` 포맷 정상 → 종료 줄 완주. **성능 목표(wake+6s) 달성** |
| | | 부기: 잔여 오프셋 -519s ≠ 수면 6151s — prltimesync/chrony가 웨이크 직후 일부를 선보정하고 clockfix가 잔여분을 마무리한 것으로 해석. 3계층 역할 분담의 실증. **[v16 정정: 당시 chrony는 08-05부터 disabled였고(§0-v16) 선보정 주체는 prltimesync 단독. prltimesync off 이후에는 "웨이크 오프셋 = 수면 시간"이 되는지로 재검증 — 아니면 darkwake 중간 동기(수면 구간 내 darkwake에서 0으로 리셋 후 재수면) 해석이 옳았던 것]** |
| **08-08 18:52~18:54** | 짧은 실수면 75s | 게이트 통과, clockfix -66s→0, **+3s HEALTHY** — 단거리에서도 성능 목표 내 |
| **08-08 20:38** | darkwake 2연발 (4s/7s) | 게이트 스킵 2건 정상 |
| **08-08 21:02** | **최초 야생 FOREIGN** | **watch 3초 교정 — 실전 첫 수행.** 단, 언마운트 경로 미상(§5.1 포렌식 대기). 각성 1h49m 생존은 시나리오 D의 사실상 증거 |
| **08-08 포렌식** | diskarb + VM smbd + backupd 로그 대조 | **21:02 사건 전모 규명(§5.1).** TIMEOUT=60 실험 → 만료 → backupd 하이재킹(직접 증거) → watch 4초 종결. **원 질병의 최초 end-to-end 재현이자 방어의 실전 완승.** 시나리오 D 확정 통과 |
| **08-08 최종** | TIMEOUT 되돌림 검증 | `AUTOMOUNT_TIMEOUT=604800` 확인 → `automount -vc` (updated ×2, no unmounts) → 마운트 150초 생존(:34.9 만료 검사 2회+ 통과, mounted by sanha). **복원 확정** |
| **v15** | — | **확정. 이후 §6 수 주 관찰만 잔존** |
| **08-14 13:40** | `systemctl status chrony` 우연 확인 | **disabled + inactive 발견** — v16 사건의 발단. 최소 07:43부터 6시간, 소급하면 08-05부터 구간별 수일 무감지 |
| **08-14** | 부팅 저널 ms 대조 (07:43:14) | chrony 정상 기동 0.36초 뒤 stop — disable→reload→stop 서명. su(1450)는 stop보다 1ms 늦어 무혐의 |
| **08-14** | `--list-boots` × chrony 이력 전수 대조 | 사망은 **부팅에서만** 재현(2/2), 수동 시작은 전건 장기 생존(4일 포함). 수면 4회 통과 — sleep 무관 확정 |
| **08-14** | 08-05 18:37:13 저널 (log.txt) | **결정타**: prltoolsd 기동 12ms 뒤 `comm="timedatectl set-ntp 0"` → `systemd-timedated: chrony.service: Disabling unit.` 실명 기록. 매 기동 반복 — "수동 시작은 살고 부팅은 죽는" 비대칭의 정체 |
| **08-14** | 13:29 wants-dir mtime 의혹 | **무혐의** — snapd 자가 갱신의 mount 유닛 링크 교체(log2.txt). 증거 덮어쓰기였을 뿐 |
| **08-14 17:28** | `prlctl set devm --time-sync off` | 적용 성공. 직후 chrony drift 재청정(stop → rm → start) |
| **08-14 17:33~17:37** | 재부팅 후 step -1.75s × 5회 | **주파수 에코** — shutdown이 오염 drift(-27905±1000000)를 재작성, 부팅 인스턴스가 로드(저널 확증). 5회 폴링으로 자연 수렴·종료. 맥 시계는 결백(sntp +2.4ms, timed 최대 교정 52.8ms) |
| **08-14 17:56~17:59** | **prltimesync 유휴 실험** — chrony 정지, -30s 인위 오프셋, 3분 방치 | **30.6s 차이 불변 = 유휴 확정.** time-sync off 실효. 복구 step +30.615s 정상 |
| **08-14 18:09** | 최종 상태 | 오프셋 0.17ms / RMS 5ms 하강 중 / Frequency 6.8ppm / drift 파일 3.700±9.6 / 미해명 step 0건 |
| **v16** | — | **시계 계층 재구성 확정. 콜드 스타트 1회 확인만 잔존(§11)** |

### 5.1 — 21:02 FOREIGN의 전모: 원 질병의 우연한 완전 재현 (08-08, 포렌식 완료)

**결론: "야생"이 아니었다.** 사용자가 만료 관찰을 위해 한시적으로 `AUTOMOUNT_TIMEOUT=60`
을 설정한 것이 원인의 전부이며, 그 결과 **v13 인과 모델(만료 창 + backupd = 하이재킹)이
의도치 않게 end-to-end로 재현**되고 watch가 이를 4초에 종결했다.

**통합 타임라인** (diskarb + VM smbd + watch, 시계 동기 상태라 초 단위 대조 가능)

| 시각 | diskarb | VM smbd | 해석 |
|---|---|---|---|
| ~20:40 | | | TIMEOUT=60 + automount -vc — 실험 시작 |
| 20:41:34.97 | removed 501 | closed :34 | 60s 타임아웃 첫 만료 — 3h52m 마운트 사망 |
| 20:52:27 | created 501 | opened :26 | sanha측 접근이 재트리거 (watch 침묵 — HEALTHY) |
| 20:53:34.94 | removed 501 | closed :34 | 67초 만에 재만료 |
| 20:53~21:02 | — | — | **ABSENT 9분 = 하이재킹 창** |
| 21:02:23 | | | **backupd 스냅샷 probe** (`fs_snapshot_list ... not supported`) |
| 21:02:25 | (기록 지연) | opened :25 | **root 트리거 = 하이재킹** |
| 21:02:27 | removed 0 | closed :27 | watch diskutil — 교정 개시 |
| 21:02:29 | created 501 | opened :28 | watch 트리거 — sanha 복귀. **발생→종결 4초** |
| 21:03:34.95 | removed 501 | closed :34 | **복귀 마운트도 65초 사망 — 60이 여전히 실효** |

**획득한 사실들**
1. **backupd 직접 증거 (사실상 확정)**: 스냅샷 probe(21:02:23) → root smbd 세션(21:02:25)
   의 2초 상관. v13의 정황 증거(fs_usage 패턴)가 시각 상관으로 격상됐다. 귀속은
   syscall 추적이 아니므로 "사실상"을 유지한다.
2. **만료 검사 타이머**: 세 removed가 전부 **:34.9초 정렬** — 주기 타이머다.
   timeout=60 하에서 검사 간격은 60s로 관측됐다 (v13의 ~120s 관측과 다름 — 간격이
   timeout에 비례하거나 별도 규칙일 가능성. **미확정**, 604800 복원 후엔 실익 없음).
3. **diskarb 기록 순서 이상 (추정)**: root 마운트의 created(실제 ~21:02:25)가
   removed(21:02:27) **뒤인 21:02:29에 기록**됐다. DiskArbitration의 비동기 전달 지연으로
   보인다. diskarb 로그의 순서를 액면대로 읽지 말고 owner·전후 관계로 재구성할 것.
4. **mac 마운트 수명 = VM smbd 세션 수명**: 전 이벤트가 초 단위로 일치. 이 대조 자체가
   시계 동기가 살아 있다는 방증이기도 하다.
5. **방어 성적**: 원 질병에서 무기한 지속되던 상태가 **4초**로 단축됐다.

**관찰 채널 교훈**: 사용자는 "이벤트가 안 보인다"며 실험을 접었지만 diskarb에는 5건이
있었다. watch는 설계상 FOREIGN에만 로깅한다(HEALTHY·ABSENT 침묵) — 발화 빈도상 옳은
설계지만 **만료 실험의 관찰 창으로는 부적합**하다. 만료·재활용의 이벤트 소스는
diskarb 로그다:
```bash
log stream --predicate 'process == "diskarbitrationd" AND eventMessage CONTAINS "stewardlabs"' --info
```

**잔여 조치 (즉시)**: 21:03:34 만료는 되돌림이 그 시점까지 미적용이었음을 뜻한다.
```bash
grep AUTOMOUNT_TIMEOUT /etc/autofs.conf     # 604800 확인
sudo automount -vc                           # 재적용 — 파일 복원만으로는 부족 (A.2)
ls /opt/stewardlabs > /dev/null; sleep 150; mount | grep stewardlabs   # 생존 확인
```

## 6. 운영 관찰 항목 (수 주)

- wakeup 로그: `mount HEALTHY (ls ok, Ns)` 의 N 분포(재접속 지연, v12 실적 0s),
  `UNHEALTHY` 빈도(guard --remount로 자가 종결되면 허용), `STILL DEAD` 유무
- **`/var/log/smb/smb-guard.log` 의 `[watch] FOREIGN 감지` 빈도** — 604800 적용 후
  0에 수렴해야 정상. 0이 아니면 만료 외의 언마운트 경로가 존재한다는 신호.
  "교정 실패" 발생 시 즉시 조사
- **v14 신규: `stale lock 제거` 로그** — 나타나면 guard 인스턴스가 비정상 종료하고
  있다는 뜻이다. 빈발하면 `TRIGGER_TIMEOUT` 또는 종료 경로를 재검토
- **v14 신규: `GUI 세션 없음` 로그** — 로그아웃 상태의 wake에서 예상되는 정상 출력이나,
  로그인 상태인데 나타나면 `launchctl asuser` 경로에 문제가 있다는 뜻
- **EUSERS 조기 경보**: VM `sudo smbstatus -b` 세션 수 추이 (주 1~2회) — 단조 증가 시
  서버측 세션 누수. 맥측 증상은 smbfix probe의 `Too many users`
- **chrony (v16 갱신)**: 상호 밀침 관찰은 **종결** — 밀침이 실증되어 prltimesync를
  off로 정리했다(§8 v16). 이후 관찰은 두 가지: ① 각성 중 `journalctl -u chrony |
  grep -i stepped` 가 0건 유지 (resume 직후 clockfix step은 chrony 로그에 안 찍힘 —
  찍히면 clockfix가 밀린 것) ② `chronyc tracking` Frequency가 한 자리 ppm 유지 —
  다시 수백 ppm대로 뛰면 무언가 시계를 외부에서 당기고 있다는 신호
- **v16 신규 — 맥 시계 건전성**: clockfix의 권위가 맥 시계다. 월 1회 `sntp
  time.apple.com` 오프셋 확인(수십 ms 정상). 초 단위로 틀어져 있으면 macOS timed
  점검 — 맥이 틀리면 clockfix가 게스트를 틀리게 맞추고 chrony가 되돌리는 낭비가
  구조화된다
- clockfix 오프셋 추이. **양수 스큐 재발 시** ext4 미래 mtime 점검을 반드시 동반
- **로그 용량**: `ls -la /var/log/smb/` 로 회전 세대 확인. `.0.bz2` 가 생기지 않으면
  newsyslog 설정이 무시되고 있다(권한 확인 — root:wheel 644)
- v1 계승: SMB 경유 POSIX ACL(`+`) 누적 → `nt acl support = no` 검토 / Finder 사용
  빈도 → SMB 유지·철거 판단 / avahi purge 시점
- `/Volumes/develop` 구 APFS 볼륨: duetexpertd가 주기 스캔 중 — 철거 시
  `smb-guard-wakeup` 의 `develop_mount.app` 블록 삭제와 함께 정리
- **v17 신규 — 잔재 유입량**: `journalctl -u mac-cruft-cleanup --since -7d | grep 제거`.
  건수가 0에 수렴하면 `DSDontWriteNetworkStores` 가 실효 중이라는 뜻이고, 실행마다
  `.DS_Store` 가 다량이면 클라이언트 억제가 **작동하지 않고 있다**는 신호다
  (기능 고장은 아니다 — 정리가 받아내고 있으므로. 그러나 전제가 틀렸다는 정보다)
- **v17 신규 — exclude 실효**: `git -C /opt/stewardlabs status --porcelain | grep -E
  '\.DS_Store|/\._'` 가 0줄. 잡히면 `.git/info/exclude` 가 유실됐다는 뜻이다
  (clone 을 다시 뜨면 사라지는 파일임에 유의 — A.18)
- **v17 신규 — 타이머 생존**: `systemctl list-timers mac-cruft-cleanup.timer`.
  `NEXT` 가 비어 있으면 타이머가 죽어 있다
- 뚜껑 닫아도 미수면 반복 시 외장 장치/클램셸 조건 확인

## 7. 진단 도구

**맥**
- **`smb-guard --state`** — 부작용 없는 상태 조회 (v14 신규). ABSENT/HEALTHY/FOREIGN
- `mount | grep stewardlabs` — **`mounted by` 필드로만 소유자 판정** (`//sanha@` 는 함정)
- **`log show --last 24h --predicate 'process == "diskarbitrationd" AND eventMessage
  CONTAINS "stewardlabs"' --info --style compact | grep -E 'created disk|removed disk'`**
  — 마운트 소유자가 `?owner=UID` 로 직접 기록됨. **수면 구간 포함 사후 전수 조회 가능**.
  FOREIGN 감사 추적의 1차 증거원 (owner=0 → root, owner=501 → sanha)
- backupd 접근 마커: `does not support SMB FullFSync` = backupd/TM 계열의 프로브 흔적
- **`tail -50 /var/log/smb/smb-guard.log`** (v13의 두 파일을 대체), `smbfix`,
  `smbutil statshares -a`
- `log show --last 10m --predicate 'process == "automountd" OR process == "mount_smbfs"' --info`
- `pmset -g log | grep -E "Entering Sleep|Wake from|DarkWake" | tail`
- 참고: sudo 인증 캐시는 tty별 **5분**(`timestamp_timeout` 기본값) — 연속 테스트 중
  비밀번호를 묻지 않는 것은 이 캐시다. 즉시 만료는 `sudo -k`
- **`launchctl print system/io.stewardlabs.sleepwatcher`** — 상주 여부·마지막 종료 코드
- **v17 신규 — Finder 복사 실패의 1차 증거**:
  `log stream --predicate 'subsystem == "com.apple.DesktopServices"' --info`
  를 켜 둔 채 복사를 재현한다. `Error -8062 at path: <경로> on write` 로 **실패한
  경로가 실명으로** 찍힌다. 사후 조회는
  `log show --last 30m --predicate 'subsystem == "com.apple.DesktopServices"' --info
  --style compact | grep -E '8062|on write'`.
  **Finder 대화상자는 실패 경로를 알려주지 않는다** — 이 채널 없이는 층 5를 권한·용량
  문제로 오진하게 된다(원칙 3)
- **v17 신규 — 클라이언트 억제 실효 확인**:
  `defaults read /Library/Preferences/com.apple.desktopservices DSDontWriteNetworkStores`
  (system) 와 `defaults read com.apple.desktopservices DSDontWriteNetworkStores`
  (user). 둘 중 하나라도 1이면 설정 자체는 실효. **단 이것이 1이어도 CopyEngine은
  `.DS_Store` 를 쓸 수 있다**(원칙 27) — "설정했으니 안 생긴다"의 근거로 쓰지 말 것
- 실시간 추적: `sudo fs_usage -w -f filesys | grep '/opt/stewardlabs'` —
  단, **System Settings의 Time Machine 패널을 닫을 것** (열려 있으면 64초 주기 폴링이
  로그의 90%+를 차지), grep은 반드시 `/opt/stewardlabs` 로
- **시간 동기 판정**: `systemctl status prltoolsd` + `ss --vsock` 은 **보장 지표가 아님**
  (초록불 상태로 +21h 스큐 실증). 1차 지표는 게스트 `journalctl | grep 'Clock change'`
  와 `chronyc tracking`, 직접 대조는 `prlhosttime; date`

**VM**
- `journalctl -o short-iso --since "<t1>" --until "<t2>"` (`Clock change detected` =
  step 순간, smbd pam_unix = 세션 개폐), `sudo smbstatus -b`, `chronyc tracking`
- 함정 3종: 저널 시각은 스큐 중 게스트 시계 기준 / `--since` 날짜 명시(자정 함정) /
  `pmset sleepnow` 미진입 가능(사후 pmset log로 실수면 확인)
- **v17 신규**: `journalctl -u mac-cruft-cleanup -n 20` (정리 이력) /
  `systemctl list-timers mac-cruft-cleanup.timer` (다음 실행) /
  `sudo /usr/local/sbin/mac-cruft-cleanup` 수동 1회 실행 (멱등)
- **v17 신규 — 차단 잔존 확인**: `testparm -s 2>/dev/null | grep -E '^\s*veto files'`
  → 0줄이어야 한다. 남아 있으면 -8062가 재발한다. **`grep -i veto` 로 검사하지 말 것**
  — `fruit:veto_appledouble = no` 가 이름 때문에 잡히는데, 그 줄은 차단이 아니라
  차단 해제이며 **반드시 남아 있어야 한다**(§8 v17 08-15 추기). 08-15 적용 검증에서
  실제로 이 오탐이 발생해 기준을 정정했다

## 8. 결정 기록

v13의 결정(아래 6건)은 모두 유효하며 재론하지 않는다. 상세는 v13 문서 §7 참조.

- **AUTOMOUNT_TIMEOUT=604800 확정** (08-07): backupd 주기 30분으로 1800 이상 어떤 유한
  타임아웃도 단독으로는 무의미 — 창 자체를 제거
- **backupd 차단 포기** (08-07): `tmutil disable` 무효 실측, `addexclusion` 층 불일치
- **smb-guard 단일화 + StartOnMount** (08-07): 각성 중 자가치유 부재의 실증
- **chrony 재활성화** (08-07): prltimesync 단일 장애점이 +76482s로 실증
- **키체인 자격증명 기각** (08-07): 맵 평문 비번(600 root) 유지
- **`pmset disablesleep` 기각** (08-07): 뚜껑 닫기 = 항상 수면을 의도된 동작으로 유지
- **autofs 유지 / no-unmount 유지** (08-07)

**v14 신규 결정**

**배치를 system 도메인으로 통일 (08-08)**: smb-guard가 이미 `/usr/local/sbin` +
`LaunchDaemons` + `bootstrap system` 이었고, sleepwatcher만 홈 디렉터리 + brew 서비스
+ user 도메인이었다. 두 훅이 같은 마운트를 다른 UID로 건드리는 구조는 권한·경합
문제의 온상이며, 로그 경로도 필연적으로 갈라진다. 통일의 대가는 §3.3의 자격 전환
4개 지점이고, 그것은 명시적 래퍼로 흡수 가능하다고 판단했다.

**`/usr/local/sbin/{sleep,wakeup}` 이름 기각 (08-08)**: `/usr/local/sbin` 은 기본
PATH에서 `/bin` 보다 **앞**에 온다. `/usr/local/sbin/sleep` 을 두면 root 셸이나
스크립트의 `sleep 5` 가 훅을 실행한다 — 디버깅이 극도로 어려운 종류의 사고다.
`smb-guard-` 접두사로 계열을 명시하고 `ls /usr/local/sbin/smb-guard*` 로 묶이게 했다.
`wakeup` 대신 `-wakeup` 을 유지한 것은 sleepwatcher 문서·관례와의 연속성 때문이다.

**로그 파일 통합 (08-08)**: §3.4. 인과 추적이 갈라진 파일 간 타임스탬프 대조를
요구하면 안 된다. 태그로 충분히 구분된다.

**newsyslog 채택, 자체 truncate 기각 (08-08)**: 크기 초과 시 `: > file` 로 비우는
방식은 롤링이 아니라 **전량 소실**이다. 사고 직후 로그를 잃을 수 있다. OS가 제공하는
세대 이동·압축·권한 관리를 쓴다.

**install / cleanup 분리 (08-08)**: 구 훅(`~/.sleep`, `~/.wakeup`)을 즉시 지우면
롤백 수단이 사라지고, 영영 남겨두면 brew 서비스 부활 시 이중 실행된다. "설치 → 검증 →
정리" 2단계로 나누고, `cleanup.sh` 는 dry-run 기본 + 삭제 전 백업으로 동작한다.

**v14.1 결정**

**stdout을 stderr와 같은 파일로 합류 (08-08)**: 별도 파일로 나누면 한 실행의 출력이
두 파일에 흩어져 시간 대조가 필요해진다(로그 통합 결정과 같은 논리). 두 스트림을 한
파일에 append하는 것은 안전하며, 순서도 보존된다.

**관찰 코드의 위치를 임계 경로 밖으로 (08-08)**: `pmset -g log` 11초 실측(§3.7c).
관찰을 없애지 않고 **옮긴** 이유는, 웨이크 유형이 층 2(스퓨리어스 웨이크) 판정의
1차 증거이기 때문이다. 진단 가치를 유지하면서 비용만 임계 경로에서 뺀다.

**plist 파싱을 PlistBuddy로 (08-08)**: §3.7a. grep/awk는 의도치 않은 필드에 매칭되고
바이너리 포맷에서 실패한다. 구조화 데이터는 구조화 도구로 읽는다(원칙 13).

**v16 결정 (08-14)**

**Parallels time-sync off — prltimesync를 시계 계층에서 제외 (08-14)**: 배타는
선택이 아니라 강제였다 — prltoolsd가 기동마다 `timedatectl set-ntp 0` 로 게스트
NTP를 disable+stop 한다(저널 실명 증거). 공존 불가라면 계측 가능한 쪽을 남긴다:
prltimesync는 로그 0줄·+76482s 전과·초록불 상태로 스큐 통과(§7), chrony는
tracking/journal로 전 이력이 남는다. 하이퍼바이저 동기화의 구조적 장점(호스트
권위·무네트워크·즉시성)은 clockfix가 이미 관측 가능한 형태로 동형 구현하고 있어,
잃는 것은 "게스트 sshd까지 죽은" 극단 케이스뿐이다.

**chrony 소스 재구성 (08-14)**: 영국 Canonical 단일(RTT 큼, 08-13에 1h11m offline
방치 실측) → NTS 4(인증 시각, maxpoll 6) + kr.pool 3(근거리, maxpoll 6). maxpoll
6(64s)은 clockfix 실패 시 폴백의 최악 복구 시간 상한이다(기본 1024s).

**clockfix v2 — 소수점 epoch + chronyc online (08-14)**: 정수 절삭(최대 1s)이
오차의 지배 항이었다. macOS date의 %N 부재는 perl -MTime::HiRes 로 우회, 정밀도
±1s → ssh 편도 지연 수준. RTT/2 보상은 기각 — 그 이하는 chrony 관할이며 거친 보정
단계에 정밀 로직을 넣는 것은 역할 분리(§4) 위반이다. `chronyc online` 은 수면 중
offline 처리된 소스의 즉시 복귀용(무해·비차단·chrony 부재 시 무시).

**drift 정리 절차 (08-14)**: `stop → rm → start` 로 끝나지 않는다 — chronyd는
커널 주파수 보정을 종료 시 원복하지 않고, **drift 파일을 종료 시 재작성한다**.
오염 정리는 start 후 **수렴 확인까지가 한 단위**이며, 수렴 전 재부팅은 오염을 한
세대 더 전파시킨다(08-14 에코 실증: rm 했는데 재부팅 인스턴스가 -27905를 로드).

**규명 방법론 부기**: 결정타는 전부 저널에 이미 있었다 — `timedatectl set-ntp` 는
단순 토글이 아니라 등록 NTP 유닛의 enable/disable+start/stop 이고, 실행 주체는
timedated 저널(`Disabling unit`)과 dbus 활성화 로그(`comm=`)에 실명으로 남는다.
auditd는 불필요했다. 유닛 필터(`-u`)를 벗긴 전체 저널 ±2초 창이 범인을 특정했다.

**v17 결정 (08-14)**

**`veto files` 폐지 — 차단을 사후 정리로 대체 (08-14)**: 요구사항은 "SMB 계층에서
막는다"가 아니라 "**워크스페이스와 git 이력이 오염되지 않는다**"였다. 그런데 차단은
Finder 복사를 전면 중단시킨다(층 5) — 수단이 목적을 잡아먹은 구성이었다. 같은 요구를
깨뜨리지 않고 만족시키는 계층이 세 곳 있다: git(`.git/info/exclude` — 이력 오염 차단),
파일시스템(`mac-cruft-cleanup.timer` — 실물 회수), 클라이언트(`DSDontWriteNetworkStores`
— 유입 감소). 셋 다 **실패해도 Finder가 죽지 않는다.** 부분 유지(`.DS_Store` 만 해제)를
기각한 이유는, 어떤 항목이 다음번에 Finder의 전제가 될지 예측할 수 없기 때문이다 —
실제로 `.Trashes` 가 이미 잠복 버그였다. 차단 계층 자체를 비운다.

**`fruit:veto_appledouble = no` 존치 — 이름만 같은 반대 설정 (08-15 추기)**: 이름에
"veto"가 들어 있으나 `veto files` 계열이 아니라 vfs_fruit 옵션이고, 값 `no` 는
차단이 아니라 **차단 해제**다. 기본값 `yes` 는 fruit이 만든 `._*` 를 veto 해
클라이언트가 접근하지 못하게 한다. vfs_fruit(8) 매뉴얼이 직접 경고한다: `._` 파일을
veto 하면 일부 애플리케이션이 깨지며, 드는 예가 **맥 클라이언트에서 Mac ZIP 아카이브를
푸는 작업의 실패**다(아카이브 안에 `._` 파일이 들어 있기 때문). 원인 구조가 우리
-8062와 같다 — "부수 파일 접근 거부가 주 작업을 죽인다"(층 5).

**중요 — 이 옵션은 `fruit:resource = file` 일 때만 적용된다**(매뉴얼 명시). v17에서
그것을 명시하면서 이 줄은 **비로소 실효를 갖게 됐고 더 중요해졌다**: `yes` 로
되돌리는 것은 -8062를 `._*` 버전으로 재도입하는 일이다. **반드시 `no` 로 남긴다.**

매뉴얼이 함께 붙인 반대편 경고도 기록해 둔다 — `no` 는 fruit이 내부적으로 만든
`._*` 를 노출하는 추상화 누수이며 "알려지지 않은 부작용"이 있을 수 있다. 우리는 그
누수를 **의도적으로 받아들이고** `mac-cruft-cleanup` 으로 치운다. 대가는 진짜
리소스 포크가 든 `._*` 가 오면 정리가 그것을 지운다는 것인데, 이 워크스페이스
(Rust/git)에서는 발생하지 않는다고 판단한다(§11에 위험으로 등재하지 않는 이유).

검증 grep 이 이 줄을 오탐하지 않도록 기준을 `'^\s*veto files'` 로 정정했다(§7, §10.6).

**08-15 정밀화 — 결정 불변의 근거 (원칙 19)**: 재현 실험으로 인과가 "Finder의 신규
메타데이터 쓰기 실패"에서 "**소스 페이로드 `.DS_Store` 의 대상 쓰기 실패**"로
정정됐다. 결정의 근거는 "veto가 `.DS_Store` 쓰기를 거부해 복사가 죽는다"는 관측된
사실이었고 그 사실은 그대로이므로, 설명이 정정되어도 폐지 결정은 유효하다. 오히려
강화된다 — 소스에 이미 있는 파일은 어떤 클라이언트 억제로도 막을 수 없으니, 서버가
받아주고 사후에 치우는 것 외의 선택지가 없다.

**청결이 다시 문제가 되면 정리를 손보고, veto를 되살리지 않는다 (08-14)**: 이 결정의
운영 계약이다. veto 복원은 -8062의 재도입이다.

**`fruit:resource = file` 명시 — `stream` 기각 (08-14, 08-15 근거 승격)**:
`fruit:metadata = stream` 은 유지한다(FinderInfo·DOS 속성은 수십 바이트). 그러나
**리소스 포크까지 xattr로 보내면 안 된다** — `streams_xattr` 는 ext4의 xattr 크기
한계(inode 여유공간 + 1블록, 통상 4KB)를 그대로 물려받고, 한계를 넘는 리소스 포크는
쓰기 실패가 된다. **08-15 추기: 이는 추론이 아니라 vfs_fruit(8) 매뉴얼의 명시적
경고다** — `fruit:resource = stream` 항목에 "대부분 파일시스템의 확장 속성 크기
제한 때문에 streams_xattr 모듈과 함께 쓰면 안 된다"고 적혀 있다. 우리는
`streams_xattr` 를 쓰고 있으므로 정면으로 해당한다. 그 실패는
지금 고치고 있는 -8062와 **같은 형태로** 나타난다. 기본값 `file`(AppleDouble `._*`)은
크기 제한이 없고, 생성된 `._*` 는 정리 타이머가 회수한다. 기본값이지만 **명시적으로
적는다** — 근거 없는 기본값 의존은 다음 개정에서 되돌려진다(원칙 5).

**`.Trashes` 는 즉시 삭제하지 않는다 — 7일 유예 (08-14)**: Finder의 "휴지통으로
이동"이 되돌릴 수 없으면 그것은 삭제이지 휴지통이 아니다. 정리 대상이되 유예를 둔다.
git 이력이 있으므로 유예 자체가 짧아도 되지만, 추적되지 않는 파일(빌드 산출물, 로컬
설정)이 여기로 들어올 수 있다.

**클라이언트 억제를 system 도메인으로 승격 (08-14)**: `DSDontWriteNetworkStores` 는
사용자 도메인 `defaults` 라 프로필 재생성·마이그레이션으로 조용히 사라진다.
`/Library/Preferences/com.apple.desktopservices` 로 올린다 — v14의 "배치를 system
도메인으로 통일" 결정과 같은 논리다. **단 이것은 보조 수단이며, 여기에 기대는 설계를
다시 만들지 않는다**(원칙 27).

**호스트 autofs 3파일 무변경 확정 (08-14)**: `auto_master` / `auto_smb` /
`autofs.conf` 는 이 고장과 인과가 없다 — -8062는 마운트 성립 **이후** 파일 쓰기
단계의 오류이며, 마운트는 정상이었다. `/etc/nsmb.conf` 신설도 기각한다: 공개된
Mac-Samba 튜닝 가이드가 권하는 `dir_cache_off=yes` 등은 현재 달성한 wake+4초와
브라우징 성능을 근거 없이 되돌릴 위험이 있고, 우리 증상과 무관하다(원칙 5·6).

## 9. 설계 원칙

v13의 8개 원칙을 그대로 계승한다. 요약:

1. 하이퍼바이저 우선 — 단 **"작동 중"이라는 가정도** 실측 검증할 것.
   프로세스 생존 ≠ 기능 동작
2. 감시 채널의 권한 경계를 의심하라 — launchd ≠ 사용자 터미널
3. 판정은 1차 증거로 — mount 테이블·에러 코드·저널
4. 개입 루프엔 캐시 플러시와 소유자 검사를 포함하라
5. 정책은 근거와 함께 기록하라 — 근거가 소멸하면 정책도 재검토 대상
6. **설정이 실제로 적용되었는지 먼저 검증하라**
7. **자가치유의 트리거를 다양화하라**
8. **판정 행위가 대상을 바꾸지 않게 하라**

**v14 추가**

9. **성공을 반환하기 전에 실제로 무언가 했는지 확인하라.** 침묵 성공(§3.1a)은 침묵
   실패보다 나쁘다 — 호출자가 후속 판단을 그 위에 쌓는다. "물러남"이 올바른 경로와
   "실패"가 올바른 경로를 호출 의도로 구분하라.
10. **잠금·플래그 등 배타 자원에는 만료를 함께 설계하라.** 정리 코드가 실행되지 않는
    경로(SIGKILL, 패닉, 강제 종료)가 반드시 존재하며, 만료가 없으면 그 순간부터
    시스템이 무증상으로 죽는다(§3.1b).
11. **실행 파일 이름은 PATH 전역에서 유일해야 한다.** `/usr/local/sbin` 은 `/bin` 보다
    앞선다 — 표준 명령과 겹치는 이름은 시스템 전체를 오염시킨다.

**v14.1 추가**

12. **관찰용 코드를 임계 경로에 두지 마라.** 진단 가치가 있는 호출일수록 비싸다
    (`pmset -g log` 11초 — §3.7c). 복구 경로 앞에 두면 관찰이 복구를 지연시킨다.
    관측은 대상이 사용 가능해진 뒤에 해도 유효하다. §9-8("판정 행위가 대상을 바꾸지
    않게 하라")의 시간축 버전이다.
13. **구조화된 데이터를 텍스트로 파싱하지 마라.** plist는 PlistBuddy/`plutil`,
    JSON은 `jq` 로 읽는다. grep/awk는 (i) 의도치 않은 필드에 매칭되고
    (ii) 포맷이 바뀌면(XML→바이너리) 통째로 실패한다. §3.7a에서 둘 다 발생했다.
14. **로그의 계층 접두사는 한 곳에서만 붙인다.** 하위 도구가 이미 자기를 식별하면
    상위에서 덧붙이지 않는다 (`clockfix: clockfix:` — §3.7d).

**v14.2 추가**

15. **예상된 실패에는 "예상됨"이라고 적어라.** 폴백 체인과 무시하도록 설계된 오류는
    로그에서 진짜 실패와 구분되지 않으면, 정상 동작이 고장처럼 읽힌다(§3.9).
    서브커맨드 출력을 원문 그대로 흘리지 말고 태그 안에 담고, 각 단계 뒤의 상태를
    함께 남겨 인과가 로그만으로 재구성되게 하라.
16. **한 컴포넌트에서 검증된 권한이 다른 컴포넌트에서도 성립한다고 가정하지 마라.**
    TCC는 responsible process 단위로 귀속된다. 같은 코드·같은 자격 전환이라도
    호출한 데몬이 다르면 결과가 다르다(§3.9c). §9-2의 확장이다.

**v14.3 추가**

17. **권한이 필요한 작업은 직접 하기보다 권한을 가진 시스템 데몬에 위임하라.**
    `diskutil`(→ diskarbitrationd)이 `umount`(직접 syscall)보다 안정적인 이유는
    호출자의 실행 컨텍스트에 덜 의존하기 때문이다. 위임 경로가 있으면 1단계로 둔다.
20. **파괴적 작업을 하는 스크립트는 절대 조용히 죽어서는 안 된다.** 설치·정리처럼
    부분 실행이 곧 손상인 작업에는 EXIT trap으로 중단 사실과 복구 경로를 남긴다.
    (`set -e` + 명령치환 할당의 침묵 종료 — §3.11b)
22. **자기 치유 시스템을 측정할 때는 치유를 먼저 멈춰라.** 고장을 인위적으로 만들어
    관찰하려는데 시스템이 그것을 즉시 고쳐 버리면, 측정 대상이 측정 중에 바뀐다.
    08-08 층 4-b 실험이 watch 데몬의 2초 교정에 오염됐다. 관찰자 효과의 운영판이며,
    §9-8("판정 행위가 대상을 바꾸지 않게 하라")의 역방향이다.
25. **실험 전에 관찰 채널이 그 이벤트를 기록하는지 확인하라.** watch는 FOREIGN에만
    로깅하므로 만료·재활용은 자체 로그에 나타나지 않는다 — 이벤트가 5건 발생하는 동안
    관찰자는 "아무 일도 없다"고 결론냈다(§5.1). 침묵이 "무사건"인지 "채널 밖"인지
    구분하려면 이벤트 소스(diskarb)를 봐야 한다. 원칙 6의 관찰 버전이다.

24. **재현 실패도 데이터다.** 고장을 인위적으로 만들려다 실패했을 때 "환경이 이상하다"로
    넘기지 말고 왜 실패했는지 물어라. 08-08 FOREIGN 생성 실패가 층 4 하이재킹이
    경합이라는 사실을 드러냈고, 그것이 간헐성의 설명이 되었다(부기 2).

23. **경보 장치는 정상 경로에서도 검증하라.** 실패를 알리는 장치가 오탐하면
    다음번 진짜 실패도 무시된다. EXIT trap을 넣었으면 성공 케이스에서 침묵하는지를
    반드시 확인한다 (§3.11c).

21. **정리 작업이 권한 확대가 되지 않게 하라.** 권한이 틀려 무시돼 온 설정 파일을
    "고치는" 것은 한 번도 부여된 적 없는 권한을 새로 여는 일이다. 감사는 하되
    자동 교정하지 말고, 삭제와 교정 중 무엇을 원하는지 사람이 결정하게 하라 (§3.11a).

19. **가설이 반증되어도 그 위에서 내린 결정이 반드시 무효가 되는 것은 아니다.**
    결정의 근거가 "관측된 사실"이었는지 "그 사실에 대한 설명"이었는지 구분하라.
    v14.3의 순서 반전은 "데몬에서 항상 실패한다"는 사실에 근거했으므로,
    원인 가설(TCC)이 기각되어도 결정은 유효하다. 반대로 설명에 근거한 결정이었다면
    함께 재검토해야 한다.
**v17 추가**

26. **차단(deny)과 정리(cleanup)는 같은 요구에 대한 다른 계층의 처방이며, 바꿔 쓸 수
    없다.** 클라이언트가 "실패하면 작업 전체를 중단"하도록 설계한 부수 동작을 서버에서
    막으면, 그 클라이언트의 주 기능이 죽는다. 원하는 것이 **결과 상태의 청결**이라면
    처방은 사후 정리다 — 정리는 실패해도 아무것도 깨뜨리지 않지만, 차단은 실패하는
    것이 곧 남의 기능이다. 요구를 "무엇을 막을까"가 아니라 "**무엇이 남지 않기를
    원하는가**"로 다시 쓰면 계층이 결정된다.
27. **클라이언트 측 억제 설정이 그 클라이언트의 모든 경로를 덮는다고 가정하지 마라.**
    `DSDontWriteNetworkStores` 는 **새 `.DS_Store` 의 생성**을 억제할 뿐이다 — 소스에
    이미 존재하는 파일을 페이로드로 복사하는 경로는 애초에 관할 밖이다(08-15 실증:
    억제가 실효 중인 맥에서 -8062 재현). 억제가 켜져 있다는 사실을 **서버측 방어의
    전제로 삼으면**, 전제 밖의 경로가 열리는 순간 기능이 죽는다. 억제는 유입을 줄이는
    보조이지 보장이 아니다 — §9-1("작동 중이라는 가정도 실측 검증할 것")의 설정
    버전이다.

18. **폴백은 지우지 말고 순서를 바꿔라.** "1단계가 항상 실패한다"의 올바른 처방은
    삭제가 아니라 강등이다. 삭제하면 남은 단계가 실패할 때 대안이 사라지고,
    강등하면 잡음만 사라진다. 부수 효과로 **그 메시지가 다시 나타나는 것 자체가
    이상 신호**가 되어 진단 가치가 생긴다(§3.10).

## 10. 설치·검증 절차 (v14)

### 10.1 배치

동봉 패키지에서:
```bash
unzip smb-guard-unified.zip -d smb-guard && cd smb-guard
sudo ./install.sh
```
`install.sh` 가 수행하는 것: 기존 잡 정지(system 2건 + brew 에이전트) → 디렉터리 생성
→ 라이브러리·실행 파일·plist·newsyslog 설치(권한 명시) → sleepwatcher 바이너리 경로
확인 → `bash -n` 구문 검사 → `plutil -lint` → `bootstrap system`.

**Intel Mac이면** `LaunchDaemons/io.stewardlabs.sleepwatcher.plist` 의 바이너리 경로를
`/usr/local/sbin/sleepwatcher` 로 먼저 수정할 것 (`which sleepwatcher` 로 확인).
install.sh가 검증하고 불일치 시 중단한다.

### 10.2 v14 신규 검증 (§0 체크리스트)

```bash
# 0) 최우선 — root 컨텍스트에서 게스트 ssh (§3.3 최대 위험)
sudo -u sanha -H ssh -o BatchMode=yes -o ConnectTimeout=3 devm 'date +%s'
#    기대: epoch 숫자. 실패하면 여기서 멈추고 §3.3의 선택지로 갈 것

# 1) 잡 등록 상태
sudo launchctl print system/io.stewardlabs.sleepwatcher | grep -Ei 'state|last exit'
#    기대: state = running   (KeepAlive 상주)
sudo launchctl print system/io.stewardlabs.smb-guard | grep -Ei 'state|last exit|runs|active count'
#    기대: state = not running / active count = 0 / last exit code = 0
#
#    **`not running` 이 정상이다.** launchd의 state는 "지금 프로세스가 떠 있는가"만
#    나타내며 "이벤트 대기 중"이라는 상태는 없다. `waiting for initial demand` 는 한 번도
#    발화하지 않은 on-demand job에만 붙는데, 이 잡은 RunAtLoad=true 라 적재 시점에 이미
#    1회 실행·종료했으므로 그 표현이 소진된 것이다. 마운트 훅은 평소 프로세스 0개가 정상.
#
#    주의: StartOnMount 는 launchd 내부 처리 키라 print 출력에 이벤트 채널로 노출되지
#    않는다. **"등록됐지만 훅이 안 걸린" 상태와 정상을 print로는 구분할 수 없다.**
#    실제 마운트를 일으켜 보는 것이 유일한 검증이다(아래 1-b).

# 1-b) StartOnMount 실제 발화 — 무관한 마운트로 확인 (시나리오 C를 겸함)
hdiutil create -size 10m -fs APFS -volname SMBGUARDTEST /tmp/sgtest.dmg
hdiutil attach /tmp/sgtest.dmg
sleep 3
sudo launchctl print system/io.stewardlabs.smb-guard | grep -Ei 'runs|last exit'
#    기대: runs 증가 (= 훅이 걸려 있음), last exit code = 0
tail -5 /var/log/smb/smb-guard.log
#    기대: 새 항목 없음 (watch는 무관한 마운트에 침묵 — 시나리오 C)
hdiutil detach /Volumes/SMBGUARDTEST && rm /tmp/sgtest.dmg
#    ThrottleInterval 5s 때문에 직전 실행 후 5초 내 마운트는 발화가 지연될 수 있다

# 2) 상태 조회
smb-guard --state                      # 기대: HEALTHY

# 3) 로그 회전 설정 파싱
sudo newsyslog -nv | grep /var/log/smb
#    기대: 3개 파일이 나열됨. 안 나오면 conf 권한 확인 (root:wheel 644)

# 4) 실제 sleep/wake — 훅 발화 확인
sudo pmset sleepnow
#    깨운 뒤:
tail -40 /var/log/smb/smb-guard.log
#    기대: [sleep] 1줄 → [wakeup +Ns] 다수 → mount HEALTHY (ls ok, Ns)
#
#    **함정: `slept for 1s` 로 게이트 스킵되면 미수면을 의심할 것.**
#    AC 전원에서는 "화면 잠금 후 미수면" 정책이 재수면을 막는다. sleepnow로 한 번
#    강제 수면 → 즉시 웨이크 → 그대로 깨어 있는 상태가 된다. 이후 몇 분 뒤 키를 눌러도
#    wake 이벤트가 없으므로 로그가 더 찍히지 않는다 — 훅 고장이 아니다.
#    판별: 아래에 `Entering Sleep` 이 1회뿐이면 미수면. **실수면 테스트는 뚜껑 닫기로.**
pmset -g log | grep -E "Entering Sleep|Wake from|DarkWake" | tail -20
```

### 10.3 v13 이월 검증 시나리오

```bash
# A. watch 교정 — 08-07 수동 재현의 자동화 확인 (핵심)
sudo umount -f /opt/stewardlabs
sudo /bin/ls /opt/stewardlabs > /dev/null      # root 마운트 유발
sleep 8
mount | grep stewardlabs                        # 기대: mounted by sanha
tail -5 /var/log/smb/smb-guard.log              # 기대: [watch] FOREIGN 감지 → 교정 완료

# B. ensure — 부재에서 생성
sudo umount -f /opt/stewardlabs && sudo smb-guard --ensure
smb-guard --state                               # 기대: HEALTHY

# C. 무해성 — 무관 마운트에 불개입
hdiutil attach -nobrowse <아무 dmg>
tail -3 /var/log/smb/smb-guard.log              # 기대: 새 항목 없음

# D. 604800 실효 — 마운트 후 65분 방치
log show --last 2h --predicate 'process == "diskarbitrationd" AND eventMessage CONTAINS "stewardlabs"' \
  --info --style compact | grep -E 'created|removed'   # 기대: removed 없음

# E. 밤샘 — wakeup 로그에 mount HEALTHY (ls ok, Ns)
```

### 10.4 정리 (검증 후)

```bash
sudo ./cleanup.sh                            # dry-run — 삭제 대상·현재 sudoers 규칙 확인
sudo ./cleanup.sh --apply                    # 실제 삭제 (/var/backups/smb-guard-v13-* 에 백업)
sudo ./cleanup.sh --apply --purge-sudoers    # smb-remount 규칙까지 제거
```

**기본 삭제 대상**: brew 에이전트 plist, `~/.sleep`, `~/.wakeup`, `~/bin/smbfix`,
`~/.sleepwatcher.*`, `/var/log/smb-guard*.log`, `/etc/sudoers.d/smb-guard`.

**sudoers 처리**
| 파일 | 기본 | 근거 |
|---|---|---|
| `/etc/sudoers.d/smb-guard` | **삭제** | v14에서 훅이 root 실행 → 불필요. 이를 참조하던 구 `~/.wakeup`·`~/bin/smbfix` 도 같은 실행에서 제거된다 |
| `/etc/sudoers.d/smb-remount` | **보존** | v14 스크립트 중 사용처 **없음**(smbfix는 자체 sudo 승격). 쓰지 않는 NOPASSWD는 상시 권한 부여이므로 제거가 원칙이나, 인벤토리 밖의 셸 별칭·수동 절차가 의존할 수 있어 판단을 유보한다. `--purge-sudoers` 로 제거 |

`cleanup.sh` 는 삭제 전에 **각 sudoers 파일의 현재 규칙을 출력**하고(무엇을 회수하는지
눈으로 확인), 삭제 후 `visudo -c` 로 무결성을 검사한다.

### 10.5 VM측 + 호스트 시계 설정 (v16 전면 갱신)

주의: 구판의 원라이너는 tty 없는 sudo에서 침묵 실패할 수 있었다(§9 위반). 각 단계를
대화형으로 실행하고 종료 상태를 확인한다.

```bash
# 0) 호스트 — Parallels 시간 동기화 off (1회, .pvm 구성에 영구 저장)
prlctl set devm --time-sync off
prlctl list -i devm | grep -i "Time Sync"        # (-) 여야 함

# 1) VM — chrony 설치·활성
sudo apt install -y chrony
sudo systemctl enable --now chrony
systemctl is-enabled chrony && systemctl is-active chrony

# 2) VM — makestep (chrony.conf 말미) : A.14 참조
grep -q "^makestep 1 -1" /etc/chrony/chrony.conf || \
  echo "makestep 1 -1" | sudo tee -a /etc/chrony/chrony.conf

# 3) VM — 소스: A.14의 두 파일 배치 (NTS 4 + kr 3, 전부 maxpoll 6)

# 4) VM — clockfix v2 배치 (A.12) + sudoers (기존 `clockfix *` 와일드카드가
#    소수점 인자도 커버하므로 sudoers는 변경 불필요)
sudo install -m 755 clockfix /usr/local/sbin/clockfix

# 5) 재시작·수렴 확인 — drift 오염 이력이 있으면 §8 "drift 정리 절차" 준수
sudo systemctl restart chrony && sleep 20 && chronyc tracking
# Frequency 한 자리 ppm, System time ms대가 정상

# 6) 재부팅 1회 — set-ntp 살해 부재 검증
sudo reboot
# 후: journalctl -b | grep -iE "set-ntp|Disabling unit"   → 0건
```

### 10.6 v17 적용 절차 — Finder 복사 차단 해소

**순서를 지킬 것.** 0단계 없이 1단계로 가면, 실패 경로가 `.DS_Store` 가 아닐 경우
원인을 모른 채 설정만 바뀐다(원칙 3).

```bash
# ── 0) 진단 먼저 — 실패 경로를 실명으로 확보한다 (맥, 터미널 2개)
#    터미널 A:
log stream --predicate 'subsystem == "com.apple.DesktopServices"' --info
#    터미널 B(또는 Finder): /opt/stewardlabs 로 폴더 하나 복사 → -8062 재현
#    기대: Error -8062 at path: .../.DS_Store on write
#    다른 경로가 찍히면 그 경로가 진짜 원인이다 — A.13의 처방을 그 경로에 맞춰 조정

# ── 1) VM — smb.conf 교체 (A.13 전문)
sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.v16.bak
sudo install -m 644 -o root -g root smb.conf /etc/samba/smb.conf
testparm -s >/dev/null            # 구문 검사. "Loaded services file OK" 확인
testparm -s 2>/dev/null | grep -E '^\s*veto files'   # 0줄이어야 한다
#  주의: grep -i veto 는 fruit:veto_appledouble = no 를 오탐한다. 그 줄은
#  차단 해제 설정이며 반드시 남아 있어야 한다 — §8 v17 08-15 추기
sudo systemctl restart smbd

# ── 2) VM — 정리 도구 배치 (A.16 / A.17)
sudo install -m 755 -o root -g root mac-cruft-cleanup /usr/local/sbin/mac-cruft-cleanup
sudo /usr/local/sbin/mac-cruft-cleanup          # 수동 1회 — 기존 잔재 회수
sudo install -m 644 -o root -g root mac-cruft-cleanup.service /etc/systemd/system/
sudo install -m 644 -o root -g root mac-cruft-cleanup.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mac-cruft-cleanup.timer
systemctl list-timers mac-cruft-cleanup.timer   # NEXT 가 채워져야 한다

# ── 3) VM — git 계층: 전역 ignore 심링크 체계가 이미 운용 중이면 **이 단계는
#         건너뛴다** (08-15 확인 — A.18 실물 반영). 아래는 그 체계가 없는 환경용.
cat >> /opt/stewardlabs/.git/info/exclude <<'EOF'
# macOS Finder 잔재 (핸드오프 v17 §8) — 이 파일은 커밋되지 않는다
.DS_Store
._*
.Trashes/
.TemporaryItems/
.Spotlight-V100/
.fseventsd/
.apdisk
EOF
git -C /opt/stewardlabs status --porcelain | head    # 잔재가 안 보여야 한다

# ── 4) 맥 — 클라이언트 억제를 system 도메인으로 승격 (보조 수단)
sudo defaults write /Library/Preferences/com.apple.desktopservices \
     DSDontWriteNetworkStores -bool true
defaults read /Library/Preferences/com.apple.desktopservices DSDontWriteNetworkStores
#    → 1. 반영은 로그아웃/재부팅 후. killall Finder 로는 불충분할 수 있다

# ── 5) 실증 — 이것을 하기 전까지 v17은 미검증이다
#    (a) 파일 1개 복사   (b) 하위 폴더가 있는 폴더 복사   (c) Finder 로 파일 삭제
#    (d) 0단계의 log stream 을 켠 채로 → -8062 0건
#    (e) 15분 뒤: journalctl -u mac-cruft-cleanup   → 제거 로그 확인
```

**롤백**: `sudo cp -a /etc/samba/smb.conf.v16.bak /etc/samba/smb.conf && sudo systemctl
restart smbd` + `sudo systemctl disable --now mac-cruft-cleanup.timer`.
단 롤백은 -8062의 복원이다 — 다른 원인이 밝혀진 경우에만 의미가 있다.

## 11. 미결 과제

- §0 검증 체크리스트 완료 → v14 확정 선언
- **v14 신규: sleepwatcher 바이너리의 FDA 부여가 system 도메인 실행에서도 유효한지**
  (바이너리 경로 기반 grant이므로 유지될 것으로 추정하나 미확인)
- ~~만료 외 언마운트 경로 규명~~ — **해소(08-08 포렌식).** 미상 경로는 없었다 —
  전부 사용자의 TIMEOUT=60 실험이 설명한다. darkwake 세션 단절 가설은 불필요해져 폐기
- ~~TIMEOUT=60 되돌림 실효 확인~~ — **완료(08-08).** automount -vc + 150초 생존 검증
- ~~층 4-b `umount` EPERM의 원인 특정~~ — **조사 종료(08-08).** probe v2 4회로
  가설 5건 기각 완료. (a) 실행 컨텍스트만 미확정이나 셸에서 재현 불가·기능 영향 없음.
  watch 로그에 `umount -f 폴백` 이 다시 나타나면 재개(그 자체가 diskutil 실패 신호)
- ~~`/etc/sudoers.d/smb-remount` 처리~~ — **완료(08-08).** 유효 확인 후 제거
- ~~+76482s 스큐의 발생 시점·원인 특정~~ — **배경 규명(08-14, v16).** 08-05 18:37
  Tools 설치의 `set-ntp 0` 가 chrony를 disable → 08-08 04:28까지 prltimesync 단독
  구간에서 발생. "폴백이 왜 없었나"가 답이었다. 스큐 자체의 트리거는 미상으로
  남으나 prltimesync off로 해당 구성 자체가 소멸 — 재발 경로 제거로 종결
- **v16 신규: VM 콜드 스타트 1회 확인** — 지금까지의 검증은 전부 웜(게스트 reboot)
  이었다. 다음 자연스러운 VM 재시작(`poweroff` → `prlctl start`) 때 3줄 확인:
  `journalctl -b | grep -iE "set-ntp|Disabling unit"` 0건 /
  `systemctl is-enabled chrony && systemctl is-active chrony` /
  `pgrep -af prltimesync` (안 뜨면 최선, 떠도 유휴면 무해 — 08-14 실험으로 유휴 증명됨)
- ~~**v17 신규(최우선): §10.6 5단계 실증**~~ — **해소·확정(08-15, 추기 3).**
  회수 3건이 08-14 거부 목록 3건과 정확히 일치, 유입→수용→회수 end-to-end 성립.
  아래는 그 경위 기록이다.
- **v17 신규(최우선, 종결): §10.6 5단계 실증 — 후반부(해소)도 08-15 통과.**
  적용 후 케이스 3 동일 폴더의 Finder 복사가 -8062 없이 완료(팝업 없음, 로그의
  CopyEngine 오류 0건), Finder 삭제도 정상. 잔여 확인 2건으로 확정한다:
  ① **`.DS_Store` 착지 확인** — 재복사 후 `ls -la` 로 대상에 `.DS_Store` 가 통상
  권한으로 존재하는지(서버 수용의 직접 증거). 08-15 1차 복사분은 timer 발화 전에
  삭제되어 미확인. ② **정리 회수 end-to-end** — 착지분을 남겨 두고 15분 대기 또는
  `sudo systemctl start mac-cruft-cleanup.service` 즉시 발화 후
  `journalctl -u mac-cruft-cleanup -n 5`. **주의(원칙 25)**: cleanup은 0건이면
  침묵하도록 설계됐다 — 회수 대상이 없는 상태의 "로그 없음"을 실패로 읽지 말 것.
  **08-15 1차 시도가 정확히 이 함정에 걸렸다**: 복사 07:05:51 → Finder 삭제 07:06:09
  → 타이머 발화 07:06:29. **회수 대상이 20초 차이로 먼저 사라졌다.** 그 상태로
  15분을 기다려도 로그는 영원히 나오지 않는다. 재시도 시 복사분을 **지우지 말고**
  둘 것 — 원칙 25(침묵이 "무사건"인지 "채널 밖"인지 구분하라)의 재현 사례다.
  부수: 08-15 복사 시 1회성 `Failed to deserialize resumable copy data` 는 00:12
  중단 복사의 재개 상태 잔재를 버리고 새로 복사한 흔적으로 무해(추정), 재발 시에만 조사
- **v17 신규: -8062 중단 잔재 정리** — 08-15 실험이 남긴 흐린 폴더(600 권한,
  재개 상태)를 `rm -rf` 로 제거할 것. 재개는 하지 않는다(추기 2)
- **v17 신규: `case sensitive = yes` 의 맥 클라이언트 실효성** — v16 주석의 "Phase F"
  검증이 여전히 미실시다. -8062와는 무관하나, Finder의 대소문자 무시 전제와 충돌해
  간헐적 "파일 없음"을 만들 수 있다. 실증 전까지는 잠복 위험으로 등재
- ~~**v17 신규: `mac-cruft-cleanup` 의 순회 비용**~~ — **해소(08-15, v1.2).**
  워크스페이스가 다중 레포 구조임이 확인되어 실측했고(순회의 97%가 빌드 산출물),
  `PRUNE_NAMES` 기본값에 `target`·`node_modules` 를 추가했다. `.git` 은 원래부터
  깊이 무관하게 제외되고 있었다(설계대로, 실측 확인)
- `No locks available` 의 단일 원인 분리 (비번 부재 vs 스큐 — 재발 시 시계 정상 상태에서 판별)
- `/Volumes/develop` 구 볼륨 철거 (`smb-guard-wakeup` 의 develop_mount.app 블록 동반 삭제)
- avahi purge, `nt acl support = no` 검토 (v1 계승)
- 개선 후보: `prlctl pause/resume` 훅 (v13 §7)

---

# 부록 A — 파일 전문

## A.1 /etc/auto_master (변경 없음, 08-08 실물 대조 완료)
```
#
# Automounter master map
#
+auto_master		# Use directory service
#/net			-hosts		-nobrowse,hidefromfinder,nosuid
/home			auto_home	-nobrowse,hidefromfinder
/Network/Servers	-fstab
/-			-static
/-    			auto_smb    	-nosuid
```

## A.2 /etc/autofs.conf (핵심 설정만 — 08-08 실물 대조 완료)
```
# 유휴 언마운트 만료. 기본 3600(1h) — 미설정 시 backupd(30분 주기)의 root 하이재킹
# 창이 매시간 열린다 (층 0/4). 604800(7일) = 만료 창 사실상 제거. 전역 설정임에 유의.
AUTOMOUNT_TIMEOUT=604800

AUTOMOUNTD_MNTOPTS=nosuid,nodev
AUTOMOUNTD_NOSUID=TRUE
```
변경 후 반영: `sudo automount -vc` (트리거 재생성 시점에 값이 박히므로 필수).

## A.3 /etc/auto_smb (600 root — 08-08 실물 대조 완료)
```
/opt/stewardlabs  -fstype=smbfs,soft  ://sanha:<URL인코딩비번>@devm/stewardlabs
```
- **`soft` 필수** — 서버 부재 시 hang 대신 유한 실패. smb-guard `TRIGGER_TIMEOUT=15`와
  wake 훅의 대기 상한이 성립하는 전제. 실물에 존재함을 08-08 확인.
- 비번은 URL 인코딩. 평문 보관은 §8 결정(키체인 기각)에 따름 — 파일 권한 600 root 유지.
- 호스트 devm은 Parallels가 관리하는 `/etc/hosts` 항목 (mDNS는 wake 후 지연으로 폐기).

## A.4 /usr/local/lib/smb-guard/common.sh (root:wheel 644) — v14.2
동봉 파일 전문 참조. 상수(`SMBG_MP`/`SMBG_OWNER`/경로) · `log()`/`say()` ·
`smbg_state()` · 자격 전환 래퍼(`smbg_as_owner` / `smbg_in_session` / `smbg_guard`) ·
세션 존재 확인(`smbg_session_active`). **실행 비트 없음(source 전용).**
**교정 원시연산은 이 파일에 두지 않는다** — §3.2.
v14.2: `smbg_oneline()` 추가 — 서브커맨드 출력을 로그 한 줄로 압축 (§3.9b).

## A.5 /usr/local/sbin/smb-guard (root:wheel 755) — v14.2
동봉 파일 전문 참조. watch / `--ensure` / `--remount` / **`--state`** 4모드.
mount 테이블 단독 판정, sanha 자격 디렉터리 open 트리거, `automount -vc` 재시도 1회,
mkdir 잠금 + **모드별 대기 정책** + **120초 유령 잠금 청소**.
v14.3: `force_umount` 순서 반전 — `diskutil` 1단계, `umount -f` 폴백 (§3.10).
v14.2: `force_umount` / `trigger_as_owner` / `ensure_owner_mount` 가 서브커맨드 출력을
캡처해 태그와 함께 기록하고, 예상된 실패에 "(예상됨)" 을 명시하며 각 단계 뒤 `state=` 를
남긴다 — 원문 유실 없이 인과가 로그만으로 재구성된다 (§3.9b).

## A.6 /usr/local/sbin/smb-guard-sleep (root:wheel 755) — v14.1 (구 ~/.sleep)
동봉 파일 전문 참조. no-unmount 유지. `last_sleep` 기록 + state 1줄 로깅.
슬립 훅에 주어지는 시간이 짧고 보장되지 않으므로 네트워크 I/O·언마운트를 하지 않는다.
v14.1: `exec >>"$SMBG_LOG" 2>&1` — stdout 누출도 흡수.

## A.7 /usr/local/sbin/smb-guard-wakeup (root:wheel 755) — **v16** (clockfix 소수점 epoch)
동봉 파일 전문 참조. 게이트 → develop_mount.app → 네트워크 대기 → clockfix →
smbd 포트 → `guard --ensure` → 생존성 프로브 → **웨이크 유형 관찰(끝)**.
bash 변환 + root 컨텍스트 자격 전환.
v14.1: stdout 흡수, `pmset -g log` 를 끝으로 이관, clockfix 접두사 중복 제거,
종료 줄 추가 — §3.7 b~e.

## A.8 /usr/local/sbin/smbfix (root:wheel 755) — **v6** (clockfix 소수점 epoch)
동봉 파일 전문 참조. `[1/3]` 시계 자동 교정, `[2/3]` `guard --remount`,
`[3/3]` 진단(EUSERS 감지). 자체 sudo 승격, 프로브 마운트는 소유자 세션 컨텍스트.

## A.9 /Library/LaunchDaemons/io.stewardlabs.smb-guard.plist — v14.1
동봉 파일 전문 참조. StartOnMount + RunAtLoad, `ThrottleInterval 5`.
v14.1: **StandardOutPath 추가** — StandardErrorPath와 동일하게
`/var/log/smb/smb-guard.launchd.log`.

## A.10 /Library/LaunchDaemons/io.stewardlabs.sleepwatcher.plist — v14.1 (v14 신규)
동봉 파일 전문 참조. `-s smb-guard-sleep -w smb-guard-wakeup`, KeepAlive + RunAtLoad.
**`-V` 미사용** — 상주 프로세스가 회전된 로그의 fd를 붙잡는 문제 회피(§3.4).
**바이너리 경로는 아키텍처별로 확인 필수** (Apple Silicon `/opt/homebrew/sbin/`).
v14.1: StandardOutPath 추가 — 훅이 exec 리다이렉션에 도달하기 전의 출력을 잡는다.

## A.11 /etc/newsyslog.d/io.stewardlabs.smb.conf (root:wheel 644) — v14 신규
```
# logfilename                            [owner:group]  mode  count  size  when  flags
/var/log/smb/smb-guard.log               root:wheel     644   7      1024  *     GJ
/var/log/smb/smb-guard.launchd.log       root:wheel     644   4      512   *     GJ
/var/log/smb/sleepwatcher.launchd.log    root:wheel     644   4      512   *     GJ
```
`size` 는 KB 단위, `when *` = 크기 조건만, `J` = bzip2, `G` = 글로브 허용.
**conf 파일 자체가 root:wheel 644가 아니면 newsyslog가 무시한다.**

## A.12 VM /usr/local/sbin/clockfix — **v2** (v16: 소수점 epoch + chronyc online)
```sh
#!/bin/sh
# /usr/local/sbin/clockfix   [v2 2026-08-14]
# usage: clockfix <epoch_seconds[.frac]>   (root로만 실행됨 — sudoers NOPASSWD 대상)
#
# v2 — 시계 계층 재구성(핸드오프 v16)에 따른 변경 2건:
#   · 소수점 epoch 수용 — 호스트 훅 v16이 perl로 μs 정밀도 값을 보낸다.
#     정수도 그대로 수용한다(폴백 호환). GNU date는 "@sec.frac" 를 지원한다.
#   · step 후 chronyc online — 수면 중 dispatcher가 offline 처리한 NTP 소스를
#     즉시 복귀시킨다 (08-13에 1h11m offline 방치 실측). chronyd는 step을 자체
#     감지해 이력을 리셋하므로 burst/makestep 은 불필요하다. chrony 부재/정지
#     시에도 clockfix 본연의 동작은 성립해야 하므로 실패는 무시한다.
#
# 출력 형식 "clockfix: ..." 은 로그 규약이다 — 훅이 원문 그대로 기록한다(v14.2).
case "$1" in
    ''|.|*[!0-9.]*|.*|*.|*.*.*) echo "usage: clockfix <epoch_seconds[.frac]>" >&2; exit 1 ;;
esac
before=$(date +%s.%N)
date -s "@$1" >/dev/null
echo "clockfix: ${before} -> $(date +%s.%N) ($(date '+%F %T %Z'))"
command -v chronyc >/dev/null 2>&1 && chronyc online >/dev/null 2>&1 || true
exit 0
```
+ `/etc/sudoers.d/clockfix`: `sanha ALL=(root) NOPASSWD: /usr/local/sbin/clockfix *`
  (**변경 불필요** — `*` 와일드카드가 소수점 인자를 커버한다. 08-14 실전에서
  `sudo -n clockfix <정수>` 경로로 검증된 그 규칙 그대로다)

## A.13 VM /etc/samba/smb.conf — **v17 전면 갱신** (veto 폐지 · resource=file 명시)

동봉 `smb.conf` 가 전문이다. v16 대비 변경 3건:

| 항목 | v16 | v17 | 근거 |
|---|---|---|---|
| `veto files` / `delete veto files` | `.DS_Store` 외 5종 차단 | **삭제** | 층 5 / §8 v17 / 원칙 26 |
| `fruit:resource` | 미설정(기본 `file`) | **`file` 명시** | `stream` 은 ext4 xattr 한계로 같은 실패를 재생산 — §8 v17 |
| 주석 | — | 폐지 근거를 파일 안에 기록 | 원칙 5 (근거가 소멸하면 정책도 재검토 대상) |

```ini
[stewardlabs]
   path = /opt/stewardlabs
   valid users = sanha
   read only = no
   browseable = yes

   # 대소문자 구분 강제 (맥 클라이언트 실효성 미검증 — §11)
   case sensitive = yes
   preserve case = yes
   short preserve case = yes

   create mask = 0644
   directory mask = 0755

   # no면 DOS 속성이 실행 비트로 매핑되어 오염됨
   store dos attributes = yes

   vfs objects = catia fruit streams_xattr
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

   # FinderInfo·DOS 속성 → xattr. 수십 바이트라 ext4 xattr 한계와 무관하다.
   # git 은 xattr 을 추적하지 않으므로 여기 쌓이는 것은 이력을 오염시키지 않는다.
   fruit:metadata = stream

   # 리소스 포크는 xattr 로 보내지 않는다 (v17). streams_xattr 는 ext4 의 xattr
   # 크기 한계(inode 여유 + 1블록, 통상 4KB)를 물려받고, 초과분은 쓰기 실패가 된다
   # — 지금 고치는 -8062 와 같은 형태다. file(AppleDouble ._*)은 제한이 없고,
   # 생성된 ._* 는 mac-cruft-cleanup 이 회수한다.
   fruit:resource = file

   # Finder의 chown/chmod 시도로 인한 오작동 방지
   fruit:nfs_aces = no

   # v17: veto files / delete veto files 를 두지 않는다.
   #   .DS_Store 차단 = Finder 복사 전면 중단(-8062, 층 5)
   #   .Trashes 차단 = "휴지통으로 이동" 실패 (v16까지 잠복해 있던 버그)
   #   청결은 VM 의 mac-cruft-cleanup.timer 가 담당한다 — §9 원칙 26
```

`[global]` 은 v16에서 변경 없다(동봉 파일에 전문 포함).
적용: `testparm -s` 구문 검사 → `sudo systemctl restart smbd` →
`testparm -s 2>/dev/null | grep -E '^\s*veto files'` 0줄
(`fruit:veto_appledouble = no` 는 남아 있는 것이 정상 — 아래 08-15 추기).

## A.16 VM /usr/local/sbin/mac-cruft-cleanup — **v17 신규** (root:root 755)

동봉 파일 전문 참조. `veto files` 폐지의 대체물. 15분 주기로 워크스페이스를 훑어
macOS 잔재를 회수한다. 설계 요지 4가지:

- **순회 제외는 `PRUNE_NAMES` 로 조립**(v1.2, 기본 `.git .Trashes target node_modules`).
  find 의 `-name` 은 경로가 아니라 **이름**으로 매칭하므로 **깊이와 무관**하다 —
  `/opt/stewardlabs` 가 여러 레포를 품은 워크스페이스 루트이고 `.git` 이 여러 깊이에
  흩어져 있어도 전부 자동으로 제외된다(08-15 실측: `.git` 내부 진입 0건).
  `target/`·`node_modules/` 도 기본 제외로 바꿨다 — 표본에서 순회의 97%를 차지했는데,
  그 안의 `.DS_Store` 를 남기는 대가는 사실상 없다(빌드 산출물은 전역 git ignore
  대상이고 `cargo clean` 으로 함께 사라진다). 소스 트리에 우연히 `target` 이라는
  디렉터리가 있으면 그 안의 잔재가 남으나 무해하며, 신경 쓰이면 `PRUNE_NAMES` 에서
  빼면 된다.
- **`.Trashes` 는 7일 유예** — 되돌릴 수 없는 휴지통은 휴지통이 아니다(§8 v17).
- **디렉터리류는 `-prune` 후 `rm -rf`** — 삭제한 디렉터리로 find가 하강해 오류를
  뱉는 것을 막는다.
- **제거 건수를 stdout 한 줄로 남긴다(journald 수집)** — 이것이 §6의 관찰 채널이다.
  0건이면 아무것도 출력하지 않아 로그가 조용하다. 원칙 25(관찰 채널이 그 이벤트를
  기록하는지 먼저 확인하라)의 적용.

`sudo /usr/local/sbin/mac-cruft-cleanup [경로]` 로 수동 실행 가능하며 멱등하다.
`PRUNE_NAMES=".git .Trashes" sudo -E mac-cruft-cleanup` 처럼 일회성으로 범위를
넓힐 수 있다(빌드 산출물까지 한 번 훑고 싶을 때).

## A.17 VM systemd 유닛 — **v17 신규** (root:root 644)

동봉 `mac-cruft-cleanup.service` / `mac-cruft-cleanup.timer` 전문 참조.

- `Type=oneshot` + `ConditionPathIsDirectory` — 마운트/경로 부재 시 조용히 skip.
- `Nice=10` / `IOSchedulingClass=idle` — 주기 `find` 가 빌드를 방해하지 않게.
- 타이머는 **모노토닉**(`OnBootSec` + `OnUnitActiveSec`). `Persistent=` 는
  `OnCalendar` 전용이므로 **두지 않는다** — 두면 조용히 무시되어 오해를 남긴다.

## A.18 git 계층 방어 — **v17, 08-15 실물 반영**

**실제 배치는 `.git/info/exclude` 가 아니라 전역 ignore 심링크 체계다** (기존 운용):

```
/opt/stewardlabs/config/git/ignore-global   ← 정본 (git으로 버전 관리됨)
~/.config/git/ignore  →  위 파일 심링크      ← 각 머신에서 ln -sfn 으로 연결
```

이 방식이 A.18 초안(`.git/info/exclude`)보다 낫다: (i) clone을 다시 떠도 정본이
레포 안에 있어 심링크 한 줄로 복구된다 — 초안의 "재작성 필요" 약점이 없다.
(ii) 워크스페이스의 모든 레포에 일괄 적용된다. (iii) 정본 자체가 버전 관리된다.
비용은 심링크 연결이 머신별 1회 필요하다는 것뿐이다(§6 실효 확인은 유지).

정본의 macOS 구간 (08-15 확인·보강):

```
# --- macOS ---
.DS_Store
._*
.Spotlight-V100
.Trashes
.fseventsd
.DocumentRevisions-V100
.TemporaryItems
.apdisk
```

**패턴 문법 주의 — 끝 `/` 는 불필요하다.** gitignore에서 `/` 없는 패턴은 파일과
디렉터리를 **모두** 매칭하고, 디렉터리가 매칭되면 그 내용 전체가 무시된다. 끝 `/` 는
"디렉터리만"으로 **제한**하는 문법이다. 즉 `.Trashes` 는 `.Trashes/` 를 포함하는
더 넓은 패턴이며, 현행 무슬래시 표기가 오히려 견고하다(`.apdisk` 처럼 파일인 항목과
표기도 통일된다). §10.6 3단계의 exclude 스니펫은 이 체계로 대체됐다 — 실행하지 않는다.

## A.14 VM chrony 구성 — **v16 전면 갱신** (상시 유일 권위로 승격)

`/etc/chrony/chrony.conf` 말미 (v13에서 유지):
```
# v16: 폴백이 아니라 상시 유일 권위다 (prltimesync off — §8).
# 횟수 무제한 step — resume 후 clockfix 실패 시에도 스스로 복구하기 위함.
makestep 1 -1
```

`/etc/chrony/sources.d/ubuntu-ntp-pools.sources` — NTS 4줄에 `maxpoll 6` 추가
(패키지 conffile — 업그레이드 시 병합 프롬프트에서 유지 선택):
```
pool 1.ntp.ubuntu.com iburst maxsources 1 nts prefer maxpoll 6
pool 2.ntp.ubuntu.com iburst maxsources 1 nts prefer maxpoll 6
pool 3.ntp.ubuntu.com iburst maxsources 1 nts prefer maxpoll 6
pool 4.ntp.ubuntu.com iburst maxsources 1 nts prefer maxpoll 6
pool ntp-bootstrap.ubuntu.com iburst maxsources 1 nts certset 1
```

`/etc/chrony/conf.d/vm.conf` (v16 신규):
```
# 근거리 소스 — 영국 Canonical 단일 의존의 RTT·도달성 보완 (08-13 1h11m offline 실측)
# maxpoll 6(64s) = clockfix 실패 시 폴백 최악 복구 시간 상한 (기본 1024s)
pool kr.pool.ntp.org iburst maxsources 3 maxpoll 6
```

호스트측 (1회, .pvm 구성에 영구): `prlctl set devm --time-sync off`
정상 지표: `chronyc tracking` — System time ms대 / Frequency 한 자리 ppm /
`journalctl -u chrony | grep stepped` 각성 중 0건

## A.15 claude-caffeinate (참고 — 전원 정책 보조, 변경 없음)
LaunchAgent `io.stewardlabs.claude-caffeinate` + `~/bin/claude-caffeinate.sh`:
Claude Desktop 실행 중 `caffeinate -i -w <pid>` (유휴 시스템 잠자기만 방지, 뚜껑
닫기/저전력 강제 수면은 통과 — 의도됨). 알려진 스펙-구현 불일치: 스크립트에 전원(AC/
배터리) 검사가 없어 AC에서도 어서션을 잡음 — 현재는 AC측 시스템 설정이 이미 수면을
막고 있어 무해, AC 설정 변경 시 재검토.

---

# 부록 B — v13 → v14 이관 대조표

| v13 위치 | v14 위치 | 비고 |
|---|---|---|
| `~/.sleep` | `/usr/local/sbin/smb-guard-sleep` | zsh → bash |
| `~/.wakeup` | `/usr/local/sbin/smb-guard-wakeup` | zsh → bash, root 컨텍스트 |
| `~/bin/smbfix` | `/usr/local/sbin/smbfix` | zsh → bash, 자체 승격 |
| `/usr/local/sbin/smb-guard` | 동일 | 잠금 수정 + `--state` |
| — | `/usr/local/lib/smb-guard/common.sh` | 신규 |
| brew services sleepwatcher | `/Library/LaunchDaemons/io.stewardlabs.sleepwatcher.plist` | user → system 도메인 |
| `~/.sleepwatcher.log` | `/var/log/smb/smb-guard.log` | 통합 |
| `/var/log/smb-guard.log` | `/var/log/smb/smb-guard.log` | 통합 |
| `/var/log/smb-guard.launchd.log` | `/var/log/smb/smb-guard.launchd.log` | 디렉터리 이동 |
| `~/.sleepwatcher.last_sleep` | `/var/run/smb-guard/last_sleep` | 재부팅 시 소멸(의도) |
| `~/.sleepwatcher.sleep_state` | (폐지) | 로그 1줄로 대체 |
| `/var/run/smb-guard.lock` | `/var/run/smb-guard/lock` | 만료 처리 추가 |
| `/etc/sudoers.d/smb-guard` | (폐지) | root 실행으로 불필요 |
| `/etc/sudoers.d/smb-remount` | 동일 | 응급용 존치 |
| (없음) | `/etc/newsyslog.d/io.stewardlabs.smb.conf` | 신규 |

# 부록 C — v14.0 → v14.1 변경 요약

설치 완료 상태에서 재적용하려면 `sudo ./install.sh` 를 다시 돌리면 된다
(bootout → 재배치 → bootstrap 이 멱등하게 수행된다).

| 파일 | 변경 |
|---|---|
| `install.sh` | 경로 탐지 awk → PlistBuddy (§3.7a) |
| `io.stewardlabs.smb-guard.plist` | `StandardOutPath` 추가 |
| `io.stewardlabs.sleepwatcher.plist` | `StandardOutPath` 추가 |
| `smb-guard-sleep` | `exec >>"$SMBG_LOG" 2>&1` |
| `smb-guard-wakeup` | 위 + `pmset -g log` 끝으로 이관 + 공백 압축 + clockfix 접두사 제거 + 종료 줄 |
| `smb-guard` / `common.sh` / `smbfix` | 변경 없음 |

# 부록 D — v14.1 → v14.2 변경 요약

로그 표현만 바뀌었다. **판정·교정 로직은 무변경**이므로 시나리오 A를 다시 돌릴 필요는 없다.

| 파일 | 변경 |
|---|---|
| `lib/common.sh` | `smbg_oneline()` 추가 |
| `sbin/smb-guard` | `force_umount` 2단계 폴백을 명시적 로깅으로 / `trigger_as_owner` 가 ls 출력을 캡처·분류 / `ensure_owner_mount` 의 `automount -vc` 출력 태그화 |
| 그 외 전부 | 변경 없음 |

재적용: `sudo ./install.sh`

# 부록 E — v14.2 → v14.3 변경 요약

| 파일 | 변경 |
|---|---|
| `sbin/smb-guard` | `force_umount` 순서 반전 (`diskutil` → `umount -f`) |
| 그 외 전부 | 변경 없음 |

재적용: `sudo ./install.sh`

# 부록 F — v14.3 → v14.4 변경 요약

| 파일 | 변경 |
|---|---|
| `cleanup.sh` | sudoers 처리 개편 — 삭제 전 현재 규칙 출력, `--purge-sudoers` 옵션, `visudo -c` 무결성 검사 |
| `sbin/smb-guard` | `force_umount` 2단계 주석에서 기각된 TCC 가설 제거 (동작 무변경) |
| 문서 | 층 4-b 원인 재분석, 통합 가설 폐기 기록, 원칙 19 추가 |
| 그 외 전부 | 변경 없음 |

재적용: `sudo ./install.sh`

# 부록 G — v14.4 → v14.5 변경 요약

| 파일 | 변경 |
|---|---|
| `cleanup.sh` | sudoers 권한 감사(자동 교정 없음) / `set -e` 침묵 종료 버그 수정 / EXIT trap |
| `install.sh` | EXIT trap 추가 |
| 문서 | 층 4-b 가설 4건 전부 반증·조사 중단, sudoers 권한 이상 기록, 원칙 20·21 추가 |
| `sbin/*`, `lib/*`, plist | 변경 없음 |

재적용: `sudo ./install.sh`

# 부록 H — v14.5 → v14.6 변경 요약

| 파일 | 변경 |
|---|---|
| `cleanup.sh` | EXIT trap 오탐 수정 (마지막 AND 리스트 → `if`, 명시적 `exit 0`, trap 본문 `if` 화) |
| `install.sh` | 동일 방어 + `exit 0` |
| `probe-layer4b.sh` | **신규** — 층 4-b 판별 일회용 진단. EXIT trap으로 데몬·마운트 자동 복구 |
| 문서 | 관측 6 무효화, sudoers 0640 유효 확정, 원칙 22·23 추가 |
| `sbin/*`, `lib/*`, plist | 변경 없음 |

`probe-layer4b.sh` 는 배포 대상이 아니다 — 일회용 진단이므로 설치하지 않고
패키지 디렉터리에서 직접 실행한다.

# 부록 I — v14.6 → v14.7 변경 요약

| 파일 | 변경 |
|---|---|
| `probe-layer4b.sh` | v2 — FOREIGN 생성 경합 재시도(최대 5회), 타이밍 검증 라운드 추가, 판정 분기 3종 |
| 문서 | (b) 가설 기각, 층 4 하이재킹의 경합 성질 규명(부기 2), 가설 (c) 타이밍 추가, 원칙 24 |
| `sbin/*`, `lib/*`, `install.sh`, `cleanup.sh`, plist | 변경 없음 — **재설치 불필요** |

# 부록 J — v14.7 → v14.8 변경 요약

| 파일 | 변경 |
|---|---|
| `sbin/smb-guard-wakeup` | wake event 로그의 탭(컬럼 경계)을 ' — ' 로 치환 (§3.12) |
| 문서 | 층 4-b 조사 종료(가설 5건 기각), probe 4회 결과표, 경합의 시스템 프로세스 확장, sudo 캐시 참고 |
| `probe-layer4b.sh` | 변경 없음 — 역할 종료. 보관용 |
| 그 외 전부 | 변경 없음 |

재적용: `sudo ./install.sh` (wakeup 한 파일 갱신)

# 부록 K — v14.8 → v14.9 변경 요약

**코드 변경 없음 — 재설치 불필요.** 문서만 갱신: newsyslog·장시간 수면 검증 완료 반영,
성능 목표 달성 확정(wake+4s), 시나리오 D를 유일한 잔존 항목으로 명시.

참고: wakeup 로그의 `(v14)` 는 파일 버전이 아니라 계열 표기다. 패치 버전을 박으면
갱신 누락 시 오정보가 되므로 의도적으로 계열만 남긴다 — 정확한 버전 대조는 이 문서의
검증 기록(날짜)으로 한다.

# 부록 L — v14.9 → v14.10 변경 요약

**코드 변경 없음.** 문서만: 최초 야생 FOREIGN 교정 기록(§5.1), 미상 언마운트 경로를
미결 과제로 등재, 시나리오 D를 "사실상 충족 — 포렌식 확인 대기"로 갱신.

# 부록 M — v14.10 → v14.11 변경 요약

**코드 변경 없음.** 문서만: §5.1 포렌식 완료(21:02 전모 — TIMEOUT=60 실험 → 만료 →
backupd 하이재킹 직접 증거 → watch 4초 종결), 시나리오 D 확정, 원칙 25 추가,
잔여 조치 1건(TIMEOUT 되돌림 실효 확인) 등재.

이 조치가 확인되면 **v14 확정 선언** 조건이 모두 충족된다.

# 부록 N — v14.11 → v15 (확정)

**로직 변경 없음.** 버전 표기만 갱신: 각 스크립트 헤더에 `[v15 확정 2026-08-08]`,
wakeup 로그 라인 `(v14)` → `(v15)`. 배포는 `sudo ./install.sh` 1회 — 이후 wake 로그에
`=== wakeup 시작 (v15) ===` 가 찍히면 확정본이 실효 중이라는 표지가 된다.

## 08-08 하루의 총결산 (v13 운영 개시 → v15 확정)

- **배치**: 홈 디렉터리 훅 + brew 서비스 + 이원 로그 → system 도메인 단일 체계
  (`/usr/local/sbin/smb-guard*`, `/usr/local/lib/smb-guard/common.sh`, `/var/log/smb/`,
  newsyslog 회전, install/cleanup/probe 스크립트)
- **수정된 버그 5건**: 잠금 거짓 성공 · 유령 잠금 (이상 v13 로직) · awk plist 파싱 ·
  `set -e` 침묵 종료 · EXIT trap 오탐 (이상 배포 스크립트)
- **기각된 가설 6건**: umount EPERM 관련 5건(TCC/FDA · 마운트 소유자 · 슬립 전환 ·
  저수준 특성 · 타이밍) + darkwake 세션 단절
- **신규 규명 3건**: 하이재킹의 경합 성질(시스템 프로세스 포함) · backupd 직접 증거
  (스냅샷 probe → 2초 뒤 root 트리거) · sudo 런타임과 visudo의 권한 기준 차이
- **실전 실증**: 원 질병(만료 창 + backupd)의 우연한 end-to-end 재현을 watch가
  4초에 종결 — v13 인과 모델과 v14 방어의 동시 검증
- **성능**: wake+15초 → **wake+4초** (목표 6초 달성)
- **설계 원칙**: 8개 → **25개**

---

# 부록 O — v15 → v16 변경 요약 (2026-08-14)

**발단**: `systemctl status chrony` 우연 확인 → `disabled + inactive`. "데몬이
죽었나, 맥 sleep 탓인가, 꺼버릴까"라는 질문에서 출발해 3주치 사건 사슬이 풀렸다.

**규명 사슬** (전부 기존 저널의 1차 증거로, auditd 없이):
1. `Loaded: disabled` + `Stopping` 로그 = 크래시가 아니라 명시적 disable
2. 부팅 ms 저널: 기동 0.36초 뒤 stop, disable→reload→stop 서명
3. `--list-boots` 전수 대조: 부팅에서만 사망(2/2), 수동 시작은 장기 생존, 수면 무관
4. 08-05 18:37 저널: **`comm="timedatectl set-ntp 0"` → `chrony.service: Disabling
   unit.`** — prltoolsd 기동 12ms 뒤, 실명 기록. 매 기동 반복이 비대칭의 정체
5. 부수 규명: +76482s(§11)는 이 disable이 만든 무폴백 구간의 사건 / 13:29 의혹은
   snapd 무혐의 / drift -27905 오염과 셧다운 재작성 에코 / prltimesync 유휴 실증
   (30초 오프셋 3분 방치 실험) / 맥 시계 결백(sntp +2.4ms)

**구성 변경**:
- 호스트: `prlctl set devm --time-sync off` (원인 제거 — 부팅 살해 소멸)
- VM: chrony 소스 NTS 4 + kr 3 (전부 maxpoll 6), drift 재청정 (현재 3.7ppm, 0.2ms)
- clockfix v2: 소수점 epoch(±1s → 수십 ms) + `chronyc online`
- 호스트 훅: smb-guard-wakeup v16 / smbfix v6 — perl HiRes로 소수점 epoch 전송

**아키텍처 재정의** (§1 층 1): "3계층"은 허구였다 — Parallels가 `set-ntp 0` 로
배타를 강제하므로 실체는 구간별 1~2계층이었고, 그 착시가 +76482s와 이번 사건을
낳았다. v16 확정형: **상시 = chrony 단독 / resume = clockfix / prltimesync = off.**
목표(웨이크 10초 내 1초 이내) 대비: clockfix +3~4s에 수십 ms 정밀 진입, 이후
chrony가 ms 유지 — 여유 초과 달성.

**교훈 2건** (§8 상세): drift 정리는 수렴 확인까지가 한 단위(셧다운 재작성 에코) /
`set-ntp` 는 enable·disable을 동반하며 실행 주체는 timedated·dbus 저널에 실명으로
남는다.

**배포**: 호스트 `install.sh` 경로로 wakeup v16·smbfix v6 / VM에 clockfix v2
직접 배치(§10.5-4) / sudoers·plist·기타 훅 변경 없음.

**잔존**: VM 콜드 스타트 1회 확인(§11) / §6 관찰 항목 v16 갱신분.

---

# 부록 P — v16 → v17 변경 요약 (2026-08-14)

**발단**: 호스트 Finder에서 `/opt/stewardlabs` 로 파일·폴더를 복사하면
`작업을 완료할 수 없습니다(오류 코드 -8062)` 로 전량 실패. 마운트는 정상이고
VM 셸 작업도 정상이므로 "SMB가 죽었다"가 아니라 **쓰기 단계의 특정 실패**다.

**규명**: macOS 통합 로그 `com.apple.DesktopServices:CopyEngine` 에
`Error -8062 at path: .../.DS_Store on write`. Finder CopyEngine은 `.DS_Store`
쓰기 실패를 복사 전체의 치명적 오류로 취급한다. 우리 `smb.conf` 는 `.DS_Store` 를
`veto files` 로 차단하고 있었다 — 인과가 정확히 맞물린다.

**`DSDontWriteNetworkStores` 는 왜 못 막았나**: 그 설정은 브라우징 경로를 억제할 뿐
CopyEngine은 별개 경로다. macOS 26(Tahoe)에서 억제가 켜진 상태로도 CopyEngine이
`.DS_Store` 쓰기를 시도한 사례가 보고됐다. §2의 방어가 v1부터 있었는데도 증상이
난 이유가 이것이다.

| 파일 | 변경 |
|---|---|
| `VM /etc/samba/smb.conf` | **`veto files` / `delete veto files` 삭제**, `fruit:resource = file` 명시, 근거 주석 (A.13) |
| `VM /usr/local/sbin/mac-cruft-cleanup` | **신규** — 잔재 사후 정리 (A.16) |
| `VM /etc/systemd/system/mac-cruft-cleanup.{service,timer}` | **신규** — 15분 주기 (A.17) |
| `VM /opt/stewardlabs/.git/info/exclude` | **신규** — 이력 오염 차단 (A.18) |
| 맥 `/Library/Preferences/com.apple.desktopservices` | `DSDontWriteNetworkStores` 를 system 도메인으로 승격 (보조) |
| 맥 `/etc/auto_master`·`/etc/auto_smb`·`/etc/autofs.conf` | **변경 없음** — 인과 없음(§8 v17) |
| 맥 `/etc/nsmb.conf` | **신설하지 않는다** — 증상과 무관, 성능 회귀 위험(§8 v17) |
| 훅·plist·sudoers·chrony·clockfix | **변경 없음** |

**아키텍처 변화**: 잔재 방어가 "서버측 차단" 단일 계층에서 **"git exclude(이력) +
사후 정리(파일시스템) + 클라이언트 억제(유입)" 3계층**으로 바뀌었다. 셋 다 실패해도
Finder의 주 기능은 죽지 않는다 — 이것이 차단과의 결정적 차이다.

**원칙 2건 추가**: 26(차단과 정리는 바꿔 쓸 수 없다) / 27(클라이언트 억제를 서버측
방어의 전제로 삼지 마라).

**상태**: **적용 완료 · v17 확정 (2026-08-15).**

- 재현(추기 2): 3케이스 대조로 트리거 특정 — 소스 페이로드 `.DS_Store`, 비어 있지
  않은 것만 치명. 클라이언트 억제가 원리적으로 무관함도 실증.
- 해소(추기 3): 적용 후 Finder 복사·삭제 통과, `afpAccessDenied` 소멸,
  타이머 회수 3건이 08-14 거부 목록 3건과 일치.
- 인과 설명은 "신규 메타데이터 쓰기"에서 "소스 페이로드 복사"로 정정됐으나, 폐지
  결정은 관측 사실에 근거했으므로 유효하다(원칙 19).
- 배포 버전: `smb.conf` v17 / `mac-cruft-cleanup` **v1.2** / 유닛 v1.
  `fruit:veto_appledouble = no` 는 **존치가 정답**이며, 검증 grep 은
  `'^\s*veto files'` 로 한다(`grep -i veto` 는 오탐).

**남은 관찰**: §6의 v17 신규 3항목(잔재 유입량 · exclude 실효 · 타이머 생존).
