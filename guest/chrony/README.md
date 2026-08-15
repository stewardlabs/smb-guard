# 게스트 시계 — chrony 참조 설정

이 디렉터리의 파일은 **install.sh 가 자동 배치하지 않는다.** 시스템 시계 정책은 배포판마다
다르고, 잘못 건드리면 손해가 크기 때문이다. 내용을 읽고 직접 반영한다.

## 역할 분담

| 계층 | 담당 | 언제 |
|---|---|---|
| 상시 권위 | chrony (NTP) | 각성 중 계속 |
| resume step | `clockfix` (호스트 훅이 ssh 로 호출) | 웨이크 직후 1회 |
| 하이퍼바이저 시간 동기화 | **끈다** | — |

하이퍼바이저의 게스트 시간 동기화와 게스트 NTP 는 **공존하지 못하는 경우가 있다.**
Parallels 의 `prltimesync` 는 기동할 때마다 `timedatectl set-ntp 0` 을 실행해 게스트
NTP 유닛을 disable + stop 시킨다(저널에 `Disabling unit` 으로 실명이 남는다). 이 상태를
"3계층 방어"로 오인하면 실제로는 단일 계층으로 돌고 있다가 그 하나가 조용히 죽는다 —
실제로 +76482초(21시간) 스큐가 그렇게 발생했다.

계측 가능한 쪽을 남긴다. chrony 는 `chronyc tracking` 과 저널로 전 이력이 남지만,
하이퍼바이저 동기화는 로그가 없고 초록불 상태로 스큐를 통과시킨다.

```bash
# Parallels 의 경우 — 호스트에서 1회, .pvm 구성에 영구 저장된다
prlctl set <VM이름> --time-sync off
prlctl list -i <VM이름> | grep -i "Time Sync"     # (-) 여야 한다
```

다른 하이퍼바이저도 동등한 설정이 있다 (VMware `tools.syncTime`,
VirtualBox `--timesync-set-start` 계열, UTM/QEMU `qemu-guest-agent` 의 시간 동기).

## 파일

### `makestep.conf`

`/etc/chrony/chrony.conf` 말미 또는 `/etc/chrony/conf.d/` 에 넣는다.

횟수 제한 없는 step 을 허용한다. resume 후 `clockfix` 가 실패하더라도 chrony 가 스스로
큰 오차를 복구해야 하기 때문이다 — 기본 정책은 기동 직후 몇 회만 step 을 허용하고
이후에는 slew 로만 좁히므로, 수천 초 오차를 사실상 복구하지 못한다.

### `local-pool.conf.example`

근거리 NTP 소스. 배포판 기본 pool 이 지리적으로 멀면 RTT 와 도달성이 나빠진다
(영국 단일 소스에 의존하던 구성에서 1시간 11분 offline 방치를 실측했다).

`maxpoll 6`(64초)은 **clockfix 가 실패했을 때 폴백의 최악 복구 시간 상한**이다.
기본값 1024초로는 웨이크 후 17분간 시계가 틀린 채로 남을 수 있다.

## 오염된 drift 정리

`chronyd` 는 종료할 때 drift 파일을 **재작성한다.** 그래서 `stop → rm → start` 로 끝내면
오염된 값이 되살아난다 — 실제로 `rm` 한 뒤 재부팅했더니 부팅 인스턴스가 이전 값
(-27905 ppm)을 그대로 로드한 사례가 있다.

**정리는 수렴 확인까지가 한 단위다.** 수렴 전에 재부팅하면 오염이 한 세대 더 전파된다.

```bash
sudo systemctl stop chrony
sudo rm -f /var/lib/chrony/chrony.drift
sudo systemctl start chrony
sleep 20 && chronyc tracking      # Frequency 가 한 자리 ppm 으로 수렴할 때까지 관찰
```

## 정상 지표

```bash
chronyc tracking
#   System time : ms 대
#   Frequency   : 한 자리 ppm
journalctl -u chrony | grep -i stepped    # 각성 중 0건이어야 한다
```

각성 중에 `stepped` 가 찍히면 `clockfix` 가 밀린 것이다 — resume step 은 chrony 로그에
남지 않는다(chronyd 는 외부 step 을 감지해 이력만 리셋한다).
