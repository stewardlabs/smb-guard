# 층 8 실측 원장 — 클라이언트 권한 쓰기와 부재하는 서버측 하한

2026-08-18, macOS 26.6 클라이언트(아카이브 유틸리티 10.15/176.6.1) + Samba
4.23.6 (Ubuntu 26.04 ARM64 게스트). 결론과 처방은
[failure-model.md 층 8](../failure-model.md), 결정 근거는
[decisions.md](../decisions.md), 미결 지점은
[open-questions.md](../open-questions.md). 이 문서는 측정 자체의 원장이다 —
프로토콜, 수치, 그리고 **기각된 가설**.

## 발단

Finder에서 zip을 풀자 "오류 1 - 작업이 허용되지 않음" 대화상자와 함께 실패하고,
희미한(진입 불가) 폴더만 남았다. 같은 zip을 CLI `unzip`으로 풀면 정상.

## 측정 규율

- 재현은 사용자의 원 증상과 동일 조건(같은 zip, 같은 디렉토리)에서 수행했다.
  아카이브 유틸리티는 launch constraint 때문에 셸에서 직접 실행할 수 없다 —
  `open -g -a "Archive Utility" <zip>` (LaunchServices 경유)로 실행한다.
  직접 실행 시도는 SIGKILL(Code Signature Invalid)로 죽고 크래시 리포트만 남긴다.
- 서버 실제 모드 판정은 전부 게스트 로컬 `stat`으로 했다. 맥 `ls`는 smbfs의
  변환을 거친 값이라 판정 근거로 쓰지 않았다.
- 와이어 캡처는 `smbcontrol all debug 10`. 로그 회전 유실을 막기 위해
  `max log size`를 일시 상향(204800)했고, 디버그 창은 트리거 파일로 개폐했다 —
  게스트의 sudo 스크립트가 워크스페이스 안의 `.debug-go`/`.debug-stop` 생성을
  폴링하고, 맥 세션이 SMB 경유로 그 파일을 만들어 창을 여닫는다. sudo 1회로
  원격 조율이 되는 구조다.
- 신규 세션 검증은 운영 마운트를 건드리지 않고 `mount_smbfs -N`으로 임시
  마운트를 따로 만들어 했다 (층 7 원장과 같은 규율).

## 재현과 와이어 시퀀스

재현 결과(2회 일관): 최종 폴더가 서버 실측 `644`(`drw-r--r--`)로 남고 내용물
없음, 아카이브 유틸리티는 오류 1로 중단.

debug 10 로그의 시퀀스 (경로는 공유 루트 기준):

```
open_directory: opening directory stewardlabs/tas/docs/.AU.4osXy, ... file_attributes = 0x12
mkdir_internal: Created directory 'stewardlabs/tas/docs/.AU.4osXy'
MS NFS chmod request stewardlabs/tas/docs/.AU.4osXy, 0700
MS NFS chmod request stewardlabs/tas/(AUHelperService이(가) 문서 저장 중), 0700
MS NFS chmod request stewardlabs/tas/docs/.ArchiveServiceTemp.sb-…, 0700
open_directory: opening directory stewardlabs/tas/docs/2026-05-16-b, ... create_disposition = 0x2
unix_mode: unix_mode(stewardlabs/tas/docs/2026-05-16-b) returning 0755
MS NFS chmod request stewardlabs/tas/docs/2026-05-16-b, 0644        ← 문제 지점
MS NFS chmod request stewardlabs/tas/docs/.ArchiveServiceTemp.sb-…/ALGORITHM.md, 0600
smbd_check_access_rights_sd: File [....../METRICS.md] requesting [0x10000] returning [0x10000] (NT_STATUS_ACCESS_DENIED)
smbd_check_access_rights_sd: File [....../METRICS.md] requesting [0x110080] returning [0x10000] (NT_STATUS_ACCESS_DENIED)
  (5개 파일 × 2회씩 반복)
```

판독:

1. 임시 폴더들에는 0700을 요청한다 — 정상.
2. 최종 폴더는 서버가 0755로 정상 생성한다 (`unix_mode` 계산 = directory mask).
3. **클라이언트가 최종 폴더에 0644 — 디렉토리에 파일 모드 — 를 요청**하고,
   서버는 그대로 적용한다. x비트가 전멸한 디렉토리가 된다.
4. 이후 임시 폴더의 파일들을 최종 폴더로 rename하는 단계에서 소스 열기
   (DELETE=0x10000, DELETE|READ_ATTR|SYNC=0x110080)가 거부되고 중단된다.
5. 분리 재현: 맥에서 `chmod 644 dst && mv file dst/` → `Permission denied`.
   0644 목적지 자체가 이동을 죽인다.

같은 zip의 APFS 대조군: 정상 해제, 최종 폴더 700. 즉 0644 요청은 아카이브
유틸리티의 네트워크 볼륨 경로에서만 나온다. 0644가 어디서 오는지(zip 파일
자신의 모드 복사? smbfs 변환?)는 클라이언트 블랙박스라 미규명 — 서버측
사실만 확정한다.

## 기각된 가설들

| 가설 | 판정 | 근거 |
|---|---|---|
| AU가 000 폴더를 남긴다 | **기각** | 실제 재현 산출물은 644. 000은 합성 케이스로만 성립 |
| `uchg`(BSD immutable) 매핑이 모드를 훼손한다 | **기각** | `chflags uchg` → DOSATTRIB xattr에 ReadOnly(0x11/0x21)만 기록, 모드 무손상, 내부 파일 생성도 정상 (`store dos attributes = yes` 정상 동작) |
| `force create mode`/`force directory mode`로 하한 강제 | **기각** | 0600/0700 설정 후에도 chmod 000·mkdir -m 000 전부 서버 실측 0. 기존 세션(reload 후)과 **신규 세션(별도 mount_smbfs)** 양쪽에서 동일 |
| `create mask`/`directory mask`가 막아준다 | **기각** | 마스크는 생성 시점 전용. 이 경로(생성 후 SD/NFS ACE 모드 쓰기)에 미적용 |
| `security mask` 계열로 chmod 경로 마스킹 | **불가** | Samba 4.11에서 제거. 4.23에서 `Unknown parameter` |
| `fruit:nfs_aces = no`가 이 채널을 끈다 | **기각** | 설정된 상태에서 `MS NFS chmod request`가 수용·적용됨. modify 경로에 가드가 걸리지 않는다 → open-questions 등재 |

## 복구 가능성의 경계

SMB는 핸들 기반이라 모든 조작(모드 변경·rename·삭제 포함)이 대상 열기를
선행하고, 열기가 현재 모드로 검사된다. 경계는 정확히 0에 있다:

| 남은 모드 | 맥에서 |
|---|---|
| 소유자 비트 1개 이상 (100/200/400/500/600/700/644…) | `chmod` 복구 가능 — 전 조합 실측 |
| 정확히 000 | chmod·rename·삭제 전부 EACCES. **게스트 chmod만이 유일한 복구 경로** |

644 폴더의 복구·사용·삭제를 맥에서 실증했다 (`chmod u+x` → 진입·기록·삭제
정상). 일상 트래픽 검증: 게스트가 umask 077로 만든 600 파일·700 디렉토리는
맥에서 rename·폴더 간 이동·삭제 전부 정상. 워크스페이스 전수 스캔(게스트
로컬 ext4)에서 000·소유자 비트 결손 객체 0건.

의도적 권한 축소의 보존도 확인했다 — 맥에서 400/500/640/750 설정 시 서버에
정확히 그 값이 남는다. force 파라미터가 있었어도 이 값들을 오염시키지 않았을
것이라는 뜻이 아니라(무효이므로 애초에 관여하지 않음), 클라이언트 chmod
채널의 충실성 자체가 확인됐다는 뜻이다.

## 측정 중 함정 기록

- **APFS→SMB 경계의 `mv`는 파일을 잠글 수 있다.** 임시 파일을 APFS에 만들고
  `mv`로 마운트 안의 대상을 교체하자, 데이터 복사 후 메타데이터(xattr·모드)
  이전 단계에서 실패하며 **대상이 모드 0으로 남았다** — 층 8의 함정을 측정
  도중 자체 재현한 셈이다. 마운트 안에서 파일을 교체할 때는 같은 볼륨의
  임시 파일 + `cat tmp > target`(내용 덮어쓰기)을 쓴다.
- **게스트가 방금 쓴 파일이 맥에서 ENOENT** — 층 7(무기한 stale) 그대로.
  맥 쪽에서 해당 디렉토리를 한 번 수정(touch)하면 보인다. 층 8 측정 결과를
  오독하게 만들 수 있으므로(권한 문제로 보임), 판정 전에 캐시를 깨야 한다.
- ssh 원격 명령의 상대경로는 게스트 홈 기준이다. 두 차례 측정이 이걸로
  오염됐다 — 원격 생성·검증은 절대경로로만 한다.

## 잔재 처리

아카이브 유틸리티는 실패 시 `(AUHelperService이(가) 문서 저장 중)` 폴더
(자동저장 헬퍼)와 644 최종 폴더를 남기고, 상위 디렉토리 모드도 건드릴 수
있다(측정 중 tas/가 755→700으로 바뀐 것을 확인, 원복함). 재현 후에는 상위
디렉토리 모드까지 대조하라.

## 소스 판독 — 가드는 있었고, 우리 배치가 무효였다 (2026-08-19)

미결로 남겼던 "`fruit:nfs_aces = no`가 modify 경로를 막지 못한다"의 진상을
Samba 4.23.6 소스(`source3/modules/vfs_fruit.c`, GitLab `samba-4.23.6` 태그)
판독으로 규명했다. 게스트 실행 버전은 4.23.6-Ubuntu-4.23.6+dfsg-1ubuntu2.2.

- **가드는 존재한다.** `check_ms_nfs()`는 `config->unix_info_enabled`가 꺼져
  있으면 조기 반환하고(1300행), 그 경우 `fruit_fset_nt_acl()`의 `do_chmod`가
  false로 남아 `SMB_VFS_FCHMOD` 자체가 실행되지 않는다.
- **문제는 옵션 파싱의 스코프다.** `config->unix_info_enabled =
  lp_parm_bool(-1, "fruit", "nfs_aces", true)` (338행) — snum이 `-1`이라
  **[global] 섹션만 조회**한다. share 섹션의 `fruit:nfs_aces = no`는 조회
  대상이 아니고, 기본값 true가 남는다. 같은 `-1` 패턴이 `fruit:aapl`,
  `fruit:copyfile`에도 쓰이고, `veto_appledouble`·`time machine` 등은
  `SNUM(handle->conn)`로 per-share 조회다 — 옵션마다 스코프가 갈린다.
- **매뉴얼도 같은 말을 하고 있었다.** vfs_fruit(8) GLOBAL OPTIONS 절: "The
  following options must be set in the global smb.conf section and won't take
  effect when set per share" — `fruit:nfs_aces`가 그 목록에 있다. 층 8 등재
  당시 옵션 설명("querying and modifying")만 읽고 절 머리의 배치 제약을
  놓쳤다.
- **실측 환경 대조:** 게스트 배포본 `/etc/samba/smb.conf` 136행의
  `fruit:nfs_aces = no`는 `[ws]` 섹션(89행) 안 — 템플릿과 동일한 무효 배치.
  즉 측정 당시 이 옵션은 사실상 기본값(켜짐)이었다.

판정: 상류 결함이 아니라 **설정 배치 오류**. 리포트할 것 없음. 기각 가설 표의
"`fruit:nfs_aces = no`가 이 채널을 끈다 — 기각"은 "share 섹션 배치가 무효"로
정정된다 — 채널을 끄는 능력 자체는 기각된 적이 없다.

부수 확인 — [global] 배치로 껐을 때 같은 플래그에 함께 걸리는 것들:

- AAPL 협상 응답의 `SMB2_CRTCTX_AAPL_SUPPORTS_NFS_ACE` 서버 캐퍼빌리티 광고
  (884행) — 클라이언트가 채널 미지원을 학습하므로 chmod 요청 자체가 사라질
  가능성이 높다.
- readdir 강화 응답의 `unix_mode` (4532행) — 맥의 모드 표시가 합성값이 된다.
  맥 쪽 git이 실행 비트 차이를 유령 변경으로 볼 수 있는지가 측정 대상.
- `fruit_fget_nt_acl()`의 가상 NFS ACE 3종(mode/uid/gid, 4589행) — 조회측도
  함께 꺼진다. 구 주석의 "query side는 유지"도 오류였다 — per-share 배치는
  양쪽 모두에 무효였다.

차단 실험(옵션을 [global]로 이동 + smbd 재시작, sudo 필요)은
open-questions.md의 재개 조건으로 넘긴다. 게스트측 스위치는
`tools/experiment-layer8-nfs-aces.sh`. 주의: AAPL 캐퍼빌리티는 세션당 1회
협상이므로, 측정 전에 맥의 SMB 세션을 완전히 끊고(전 마운트 해제) 새로
붙어야 한다.

## 차단 실험 — 채널 차단 성공, 서버측 처방으로 승격 (2026-08-19)

`--apply`(산하님 sudo 실행) + `smb-guard --remount`로 세션 재수립 후 측정.
사전 확인: testparm 정규화 출력의 [global]에 `fruit:nfs_aces = no` 등재.
측정은 층 7 원장과 같은 규율 — 별도 프로브 마운트(`mount_smbfs -N`), 판정은
게스트 로컬 stat, 운영 마운트는 프로브에 쓰지 않음.

### 부작용 실측

- **chmod 전면 침묵 no-op.** 맥에서 파일 `chmod +x`/`600`/`000`, 디렉토리
  `chmod 644`(AU 킬러 패턴) 전부 exit 0인데 게스트 실측 모드 불변(644/755).
  000 후 읽기, 644 후 디렉토리 내 쓰기 모두 정상 — 복구 불가 000 클래스가
  클라이언트에서 생성 불가능해졌다. 의도적 모드 변경도 같은 채널이므로 함께
  죽는다(오류조차 없다는 것이 가장 나쁜 형태). 모드 변경은 게스트에서 한다.
- **모드 표시 합성화.** 맥 stat/ls가 전 객체를 `rwx------`(700)로 표시.
  게스트 실측(파일 644, 디렉토리 755)과 무관한 값. 집행은 서버측이므로
  기능 영향 없음 — "판정은 게스트 stat" 규율이 표시 계층까지 확장된 셈.
- **git 유령 모드 변경 (최대 부작용).** 합성 700의 x비트 때문에
  `core.filemode=true`인 전 레포에서 전 추적 파일이 `100644 => 100755`로
  보였다(워크스페이스 4개 레포 표본 → 17개 레포 전수 동일).
  `-c core.filemode=false`로 전 레포 청정 확인 — 전부 유령, 실변경 0건.

### git 완화책 — 실증 후 17개 레포 전수 적용

레포 로컬 `core.filemode` unset + 맥 머신 로컬 config.local에 워크스페이스
스코프 `includeIf` 오버레이(`core.filemode = false`). 레포 로컬 값이 모든
include를 덮으므로 unset이 필수다. 게스트는 unset 후 내장 기본값 true로
실모드 판정 유지 — 맥·게스트 양쪽 status 청정 실증 후 서브모듈 포함 17개
레포에 전수 적용, 유령 0건.

**clone 함정은 양방향(실측).** 맥에서 `git init` → 레포 로컬 **false** 기록
(프로브가 새 파일에 x비트가 이미 서 있는 것을 보고 모드 신뢰 불가 판정 —
사전 추정 "true를 기록할 것"과 반대). 이 false는 게스트의 실모드 판정을
죽인다(신규 스크립트가 100644로 커밋됨). 게스트 clone은 true를 기록해 맥에
유령을 되살린다. 어느 쪽이든 처방 동일: clone 후 `git config --unset
core.filemode`. 상세는 operations.md.

### 아카이브 유틸리티 end-to-end

원본 zip은 잔존하지 않아(증상 후 삭제) 와이어 캡처와 동일 형태의 합성 zip
으로 재현 — 디렉토리 엔트리 0644, 파일 0600 저장. zip 제작 함정: 디렉토리를
먼저 644로 바꾸면 zip이 진입을 못해 빈 아카이브가 된다 — 내용을 먼저 담고
디렉토리 엔트리만 2차 갱신으로 644를 입혔다.

결과: `open -g -a "Archive Utility"` 해제 **완전 성공**. 파일 3개 전부 존재,
최종 디렉토리 게스트 실측 755(마스크 산출값), 희미한 폴더·오류 대화상자
없음. chmod가 무시되니 해제는 그냥 성공한다 — 가설 그대로.

한계: ① 합성 zip 재현(원본 부재), ② debug 10 미가동이라 클라이언트가 chmod
요청을 보냈는지(서버가 무시) 아예 안 보냈는지(캐퍼빌리티 미광고 학습)는
행동 결과로만 판정 — 서버측 사실(모드 불변·해제 성공)은 어느 쪽이든 동일.

### 처방 승격과 잔재

층 8 처방을 운영 우회에서 서버측 수정으로 승격(failure-model.md).
doctor.sh에 [global] 스코프 불변식 추가 — 전 출력 grep이면 per-share
오배치(바로 이번에 진단한 함정)가 false-pass하므로 섹션 스코프가 필수다.
게스트에 실험 스크립트의 백업(`/etc/samba/smb.conf.layer8-nfs-aces.bak`)이
남아 있다 — 채택했으므로 이 백업은 이제 구본이며, `--revert`는 채택 상태를
되돌리는 명시적 행위가 된다. 프로브 잔재는 전량 회수(게스트 대조 확인),
프로브 마운트 해제.

## 채택 후속 실측 — 실행 판정과 x비트 소실 (2026-08-19, 같은 날)

트레이드오프 재검토("맥 실행 스크립트 정본이 워크스페이스에 있는데 괜찮은가")
과정에서 세 가지를 추가 실측했다.

- **실행은 서버 실모드를 따른다 — 표시는 양방향으로 거짓말한다.** 서버 644
  파일은 맥 표시가 `rwx------`여도 실행 거부(126), 서버 755 파일은 정상 실행.
  합성 모드는 표시 외 아무것도 지배하지 않는다.
- **맥 경유 checkout/pull이 실행 파일을 다시 쓰면 서버 x비트가 죽는다 —
  실사례 발생.** 채택 직후 맥에서 실행한 PR #15 머지 pull이
  `tools/doctor.sh`를 서버 실측 644로 만들었고, 맥에서 실행 거부로 발견됐다.
  게스트는 이를 index-vs-worktree 모드 diff(` M`)로 본다. 복구는 게스트
  `git checkout -- tools/doctor.sh` 한 줄(755 복원 실증). 전 레포 스윕
  (`git diff --summary | grep 'mode change'`)에서 추가 피해 0건.
- **게스트 chmod +x 직후에는 맥 속성 캐시가 실행 판정을 붙든다.** 맥이 만든
  644 파일에 게스트가 +x를 줘도 즉시는 거부가 유지됐고(1회 실측), 게스트가
  처음부터 755로 만든 파일 + 디렉토리 touch(층 7 규율)에서는 정상 실행 —
  생성 시점 접근권 캐시로 해석(추정). 판정 전 캐시를 깰 것.

측정 중 zip 함정 하나 추가: 빈 아카이브 사건(위 절)과 별개로, 실행 테스트용
스크립트를 맥에서 만들면 어차피 644라 "테스트 파일 자체를 게스트에서 만들고
+x까지 게스트에서" 해야 깨끗한 측정이 된다.

처방 반영: 배포된 doctor(`/usr/local/sbin/smb-guard-doctor`, host/install.sh)
— 마운트의 의사가 마운트 위에 살면 안 된다는 부트스트랩 논거 + x비트 노출
회피. doctor에 층 8 운영 계약 스윕 2종 추가(repo-local core.filemode,
게스트 모드 드리프트 — 감사 전용, 원칙 21). 상세는 operations.md
'git on the Mac — filemode'.
