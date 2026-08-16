# smb-guard — Claude Code Context

This repository is **public** (github.com/stewardlabs/smb-guard). That single fact
drives the rules below and overrides the workspace-level defaults where they
conflict.

## Language policy

**Everything in this repository is written in English** — code comments,
user-facing messages (log lines, errors, help text), documentation, commit messages
and pull requests.

This is a deliberate exception to the workspace policy, which is Korean. It is
registered in the canonical language section of the workspace `CLAUDE.md`; the
reasoning is that this is the only externally published repository, its inbound
traffic is essentially all search, and a Korean surface never reaches the readers it
was published for. If it is not found, it never gets translated either.

**The one exception is `docs/history/`, which stays in Korean.** It is the
development ledger — session handoffs carrying raw measurement logs and reasoning
as it happened. Its external value is lowest, its volume is roughly half of all the
documentation, and it is where translation risks losing precision most. Its findings
are already distilled into `docs/failure-model.md` and `docs/decisions.md`.
Do not translate it, and do not add English files to that directory.

Git history before the switch is Korean and is **not** retroactively rewritten —
the repository is already public and the PR numbers in those commit subjects would
stop matching the GitHub PR pages. `CHANGELOG.md` is the English-language record.

## Terminology

Use these renderings consistently. The 8-layer failure model is cross-referenced
across every document and several code comments, so a drifting term silently breaks
those references. This table is also the bridge between the Korean `docs/history/`
and the English documents.

| Korean | English | Note |
|---|---|---|
| 층 N / 층 4-b | `Layer N` / `Layer 4b` | the axis of every cross-reference |
| 판정 | `determination` (verb: determine) | mostly "is the mount healthy or root-owned" |
| 교정 | `remediation` / `remediate` | "the sole remediation agent" |
| 처방 | `remedy` | pairs with "failure model" as a medical metaphor |
| 실측 | `measured` / `measurement` | |
| 설계 원칙 N | `Principle N` | also referenced from code comments |
| 잔재 | `cruft` | fixed by the name `mac-cruft-cleanup` |
| 침묵 실패 / 침묵 무시 | `silent failure` / `silently ignore` | |
| 회수 | `reclaim` / `reclamation` | |
| (만료) 창 / 빈 창 | `(expiry) window` / `empty window` | |
| 순회 | `sweep` | the `find` traversal |
| 기각 / 반증 | `rejected` / `refuted by` | column headings of the hypothesis tables |
| 하이재킹 | `hijacking` | |
| 쌍안정 | `bistability` / `bistable` | Layer 7 |
| 회귀 | `regression` | the Samba regression |
| 상류 | `upstream` | |
| 설계 계약 / 운영 계약 | `design contract` / `operational contract` | |
| 봉쇄 | `containment` (verb: block) | |
| 불변식 | `invariant` | |
| 고장 모델 | `failure model` | |
| 1차 증거 | `primary evidence` | |
| 스퓨리어스 웨이크 | `spurious wake` | |
| 부수 파일 | `incidental files` | `.DS_Store` and friends |
| 공유 루트 / 충돌 집합 | `share root` / `collision set` | Layer 6 |
| 자격 전환 | `credential switch` | the `sudo -u` wrappers |
| 임계 경로 | `critical path` | |
| 단발 / 부분 읽기 | `one-shot` / `partial read` | Layer 7 measurement table |
| 무기한 stale | `indefinite staleness` | |
| 능동 관찰자 | `active observer` | |
| 유예 | `grace period` | the `.Trashes` policy |
| 강등 | `demotion` | Principle 18, the fallback chain |
| 오탐 | `false positive` | |
| 잠복 위험 / 미결 과제 | `latent risk` / `open questions` | |
| 점검 | `inspection` | what `doctor.sh` does |
| 수동 배치 | `manual placement` | |

## Comment policy

Comment density here is deliberately high, and higher than the Claude Code default.
The comments carry design rationale, invariants and rejected hypotheses — they are
the material a future session uses to reconstruct why the code looks like this.
Keep them when editing; do not strip them for brevity. What is still forbidden is
the "what" comment that the identifier already says, and time-bound references
("added for X", "was Y").

The header of every script states its deployment path and role. Keep that intact.

## Things that bite

- **`bash 3.2` is the target on the host.** `/bin/bash` on macOS is 3.2; no zsh-only
  syntax, no bash 4+ features (no associative arrays, no `${var^^}`).
- **Principle 29 still applies even though the trigger is gone.** Braces around a
  variable expansion followed by a non-ASCII byte are kept on purpose. English
  output removes the failure mode here, but the regression check stays:
  ```bash
  perl -ne 'while (/\$([A-Za-z_]\w*)(?=[\x80-\xFF])/g){print "$ARGV:$.\n"}' $(git ls-files)
  ```
- **`host/` is macOS-only and cannot be executed on Linux.** In a Linux session,
  `bash -n` is the available check. Do not claim runtime verification you did not do.
- **Log strings are an observation channel.** `mac-cruft-cleanup`'s summary line and
  `smb-guard`'s tagged lines are cited by the documentation. Changing their wording
  is a documentation change too.
- **`tools/probe-layer4b.sh` and `tools/cleanup.sh` still have paths and accounts
  hardcoded.** They predate configuration externalisation; both READMEs say so.

## Verification

There is no CI. Before opening a PR, run at minimum:

```bash
for f in install.sh host/install.sh guest/install.sh host/lib/common.sh host/sbin/* guest/sbin/* tools/*.sh; do bash -n "$f" || echo "SYNTAX FAIL $f"; done
```

```bash
grep -rlP '[가-힣]' --exclude-dir=.git --exclude-dir=history --exclude=CLAUDE.md .
```

The second must return nothing — Korean outside `docs/history/` means the language
policy has been broken. This file is excluded because the terminology table above
is Korean-to-English by construction.
