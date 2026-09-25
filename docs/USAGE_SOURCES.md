# PackTrace — 사용량 소스 계약 (다중 도구)

기준일: 2026-09-23 · 설치본 확인: `omp/18.2.9`, `codex-cli 0.155.1`, `claude 2.1.280 (Claude Code)`, `opencode 1.18.31`
이 문서는 **확인한 사실(OBSERVED)** 과 **추론(INFERRED)**·**미확인(UNKNOWN)** 을 구분한다. 상류 최신 버전이 설치본과 같다고 가정하지 않는다.

> 이번 구현 상태는 §9에 있다. 어댑터 코드가 없다는 사실을 "지원"이라고 쓰지 않는다.

## 1. 보상 정책 (도구와 무관하게 동일)

| 항목 | 값 |
|---|---|
| 인정 토큰 | 검증된 **비캐시 입력 + 검증된 출력** |
| 환산 | 10,000 인정 토큰 = 1 P (정수 몫), 나머지는 공통 계정에 이월 |
| 제외 | cache read / cache write, `total`, reasoning(출력의 부분집합), cost, rate limit, 컨텍스트 크기 |
| 화폐 | 도구별 화폐를 만들지 않는다. 모든 도구의 인정량이 **하나의 공통 계정**에 모인다 |
| 계정 ID | `omp-noncache-v1` — 최초 OMP 전용으로 만들어진 rule id를 그대로 쓴다. 장부·award 이력의 연속성을 위해 이름을 바꾸지 않는다 |
| 지갑 | 인정 적립은 `production` 지갑에만 기록한다 |

OMP 규칙의 근거와 필드 의미는 `docs/OMP_USAGE_SCHEMA.md`에 그대로 보존한다.

## 2. 도구·소스·호출의 분리

| 개념 | 뜻 | 저장 위치 |
|---|---|---|
| `toolKind` | 사용자가 실행한 도구 (OMP/Codex/Claude Code/OpenCode) | `usage_source.tool_kind` |
| `sourceID` | 연결한 저장소의 안정 식별자 (`<tool>:<FNV1a(정규 경로)>`) | `usage_source.source_id` |
| provider/model | 그 사용량에 기록된 모델 경로 | `usage_event.provider` / `model` |
| observation | 한 소스에서 읽은 기록 1건 | `usage_event.event_id` = `<tool>:<session>:<record>` |
| call identity | 실제 호출의 정체성 (증명 가능할 때만) | `usage_event.call_key` |
| credited usage | 중복 제거 후 보상에 반영된 사용량 | `usage_event.accepted_tokens` |

- 같은 모델 이름이라도 도구가 다르면 다른 호출이다.
- 다른 도구 이름이라도 같은 호출이면 두 번 지급하지 않는다(`call_key` → `usage_event_alias`).
- provider + response id는 **provider 네임스페이스 안에서만** 유일하다고 취급한다.

## 3. 소스별 파일·커서 분리

| 저장 방식 | 위치 기록 | 이유 |
|---|---|---|
| JSONL (OMP·Codex·Claude Code) | `usage_file_checkpoint.byte_offset` (바이트) | 레코드 경계까지 소비한 위치 |
| DB (OpenCode) | `usage_cursor` (`kind = row-position`, payload는 어댑터 소유 JSON) | 행 정렬 위치는 바이트 오프셋이 아니다. 숫자를 서로 바꿔 쓰지 않는다 |

`usage_cursor`는 (source_id, cursor_key) 단위로 저장하며 파일 checkpoint와 절대 섞지 않는다.

## 4. Codex — 확인한 저장 계약

| 항목 | 값 | 근거 |
|---|---|---|
| 설치·버전 | `codex-cli 0.155.1` | `codex --version` |
| 세션 파일 | `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<uuid>.jsonl` | 실제 코퍼스 3,226개 파일 |
| 인코딩 | UTF-8 JSON Lines, 1줄 1레코드 | OBSERVED |
| 레코드 종류 | `session_meta`, `event_msg`, `response_item`, `turn_context` | OBSERVED |
| 세션 식별 | `session_meta.payload.id` (= 파일명 uuid), `payload.cli_version`, `payload.model_provider` | OBSERVED |
| usage 위치 | `event_msg` + `payload.type == "token_count"` → `payload.info` | OBSERVED |
| usage 필드 | `info.total_token_usage`(누적), `info.last_token_usage`(요청별), `info.model_context_window`(컨텍스트 크기) | OBSERVED |
| usage 구성 | `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`, `total_tokens` | OBSERVED |
| 포함 관계 | `total_tokens == input_tokens + output_tokens` **3,089/3,089 일치** → `cached_input_tokens`는 `input_tokens`에 **포함**, `reasoning_output_tokens`는 `output_tokens`에 포함 | OBSERVED(항등식) |
| 비캐시 입력 | `input_tokens − cached_input_tokens` (clamp하지 않고 음수면 거절) | OBSERVED(포함 관계에서 유도) |
| 누적성 | `total_token_usage`는 세션 안에서 단조 증가(770 표본) | OBSERVED |
| 누적 감소 | 같은 파일에서 **1회 감소**가 관찰됨 → 리셋/분기 가능 | OBSERVED |
| 레코드 식별 | 레코드의 `ordinal`이 파일 안에서 **고유**(0..21,927) | OBSERVED |
| 사용 금지 | `payload.rate_limits`(한도), `model_context_window`(컨텍스트 크기), `last_token_usage`와 `total_token_usage` 동시 가산 | 정책 |

**앱의 Codex 정책(설계 확정)**

1. `token_count` 레코드만 사용한다. `last_token_usage`와 누적 차분을 **동시에 더하지 않는다**.
2. 연결 기준선: 연결 시점의 마지막 `total_token_usage`를 기준값으로 저장하고, 그 이후 증가분만 적립한다.
3. `total_token_usage`가 이전 관찰값보다 **작아지면** 리셋/분기로 보고 `cumulative_boundary_unclear`로 기록하고 **지급하지 않는다**(기준을 그 값으로 재설정만 한다).
4. 관찰 identity는 `codex:<session_id>:<ordinal>` — 스캔마다 새로 만들어지는 값이 아니다. 저장되는 response id는
   `<session_id>:<ordinal>`이다: `ordinal`은 **파일 안에서만** 고유하므로, 순번만 저장하면 저장소의 provider+response 중복 검사가
   두 번째 이후 세션의 호출을 첫 세션의 "중복"으로 지웠다(2026-09-24 수정, 실제 DB에서 Codex 적립 0건으로 확인).
5. 연결 시점의 기준선(§7-A 파일 발견 규칙): 연결할 때 있던 파일은 현재 끝을 기준선으로 삼고(내용을 읽지 않음), 연결 뒤 처음 본
   파일은 연결 뒤 수정되지 않았으면 역시 기준선, 연결 뒤 수정됐으면 처음부터 읽어 **연결 시각 이전 레코드는 기준선·이후는 적립**한다.
   이전 정책("처음 본 파일은 무조건 기준선")은 발견이 늦은 파일의 연결 뒤 사용량을 영구히 버렸다.

## 5. Claude Code — 확인한 저장 계약

| 항목 | 값 | 근거 |
|---|---|---|
| 설치·버전 | `2.1.280 (Claude Code)` | `claude --version` |
| transcript | `~/.claude/projects/<project-slug>/<session-uuid>.jsonl` (단일 파일이 300 MB 규모) | 실제 코퍼스 190개 파일 |
| 레코드 종류 | `assistant`, `user`, `system`, `attachment`, `file-history-*`, `mode`, `permission-mode`, `bridge-session`, `last-prompt`, `frame-link`, `artifact-*` 등 | OBSERVED |
| 확정 usage 위치 | `assistant` 레코드의 `message.usage` | OBSERVED |
| usage 필드 | `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `output_tokens_details.thinking_tokens` | OBSERVED |
| 식별자 | `sessionId`, `uuid`, `parentUuid`, `isSidechain`, `requestId`, `message.id`, `message.model` | OBSERVED |
| 중복 관계 | `requestId`와 `message.id`가 assistant 레코드마다 존재(414/414) | OBSERVED |
| 비캐시 입력 | `input_tokens` (cache_creation/cache_read와 별도 필드) | INFERRED — Anthropic API 의미 기준, 이 앱의 교차 검증은 아직 없음 |
| reasoning | `output_tokens_details.thinking_tokens`는 `output_tokens`의 부분집합(1,763 < 1,869) → **재가산 금지** | OBSERVED(표본) |
| 서브에이전트 | `<session>/subagents/agent-*.jsonl`, `isSidechain: true`, 세션 ID는 부모와 같음. 2026-09-23~24 실제 transcript: 서브에이전트 호출 1,460건 중 부모와 `requestId`가 겹친 것은 3건뿐이고, 셋 다 포크된 서브에이전트에 **복사된 부모 호출**(세션·요청 ID·usage 동일). 나머지는 부모 transcript에 없는 **별도 API 호출** | OBSERVED(2026-09-24) |

**앱의 Claude Code 정책(설계 확정)**

1. `assistant` 레코드의 확정 usage만 본다. statusline·비용 합계·컨텍스트 비율은 보상 근거가 아니다.
2. `input_tokens + output_tokens`만 인정한다(캐시 읽기/쓰기 제외, thinking 재가산 없음).
3. identity는 `claude-code:<sessionId>:<requestId>`(없으면 `message.id`). 스트리밍 중간값·요약·user 레코드는 대상이 아니다.
4. 서브에이전트(`isSidechain == true`) 호출도 인정한다(2026-09-24 변경, 이전에는 중복 관계 미검증으로 제외). 복사된 부모 호출은 identity가 같아 한 번만 인정된다. 변경 전에 읽고 제외한 서브에이전트 기록은 소급하지 않는다(파일 위치가 이미 지나감).
5. 파일 발견·기준선은 §7-A. 한 요청이 content block마다 여러 줄로 기록되는 것을 실제 transcript 5개에서 확인했다(요청 748건 중
   573건이 여러 줄). 줄 사이 usage·stop_reason이 다른 경우는 0건이라, 같은 requestId의 두 번째 줄부터는 중복으로만 처리된다
   (숫자 필드만 집계, 본문은 읽지 않음).

## 6. OpenCode — 확인한 저장 계약

| 항목 | 값 | 근거 |
|---|---|---|
| 설치·버전 | `1.18.31` | `opencode --version` |
| 데이터 루트 | `~/.local/share/opencode/` | OBSERVED |
| 저장 방식 | `opencode.db` (SQLite) + `opencode.db-wal` + `opencode.db-shm`, 그리고 `storage/` 트리 | OBSERVED(파일 존재) |
| WAL | **사용 중**(wal/shm 존재) → 본체 파일만 복사하면 일관되지 않다 | OBSERVED |
| 스키마(확인) | `message`(`id`, `session_id`, `time_created`, `time_updated`, `data` JSON) + 인덱스 `(session_id, time_created, id)`, `session` 3,207 · `message` 30,927 · `part` 154,024 행 | OBSERVED |
| usage 필드 | `data.tokens` = `{input, output, reasoning, cache:{read, write}, total}`, `role == "assistant"` | OBSERVED |
| 캐시 포함 관계(Claude) | 실제 transcript 1,107개 assistant 레코드 중 **1,098건에서 `cache_read_input_tokens > input_tokens`** → `input_tokens`가 캐시를 포함한다면 불가능한 관계다. 공식 API 계약(비캐시 입력은 `input_tokens`, 캐시는 별도 필드)과 일치 | OBSERVED(코퍼스) |
| 포함 관계 | `total == input + output + reasoning + cache.write + cache.read` **3,492행 전부 일치**(그중 2,794행은 reasoning > 0) → reasoning은 output에 포함되지 않는 별도 구성 요소이므로 **한 번만** 더한다 | OBSERVED(항등식) |
| CLI 경로 조회 | `opencode`의 데이터 경로 조회 명령은 초기화·마이그레이션 부작용 위험이 있어 실행하지 않았다 | 정책 |

**OpenCode `finish` 실제 분포(이 설치본, 20,000행 표본): `tool-calls` 15,161 · `stop` 1,893 · 값 없음 299 · `length` 1 — `error`/`aborted`는 **없음**. 네 경우 모두 usage가 함께 기록되어 있고, usage는 호출이 끝날 때 쓰인다.**

**앱의 OpenCode 정책(설계 확정)**

1. 읽기 전용 연결(`SQLITE_OPEN_READONLY`)만 사용한다. 스키마 변경·VACUUM·journal mode 변경·immutable 설정을 하지 않는다.
2. 원본 DB 파일을 복사해 "일관된 원본"으로 취급하지 않는다.
3. 커서는 `usage_cursor`(행 정렬 위치)에 저장한다. 바이트 오프셋과 혼용하지 않는다.
4. 완료 판정: 확인한 완료 집합(`tool-calls`, `stop`, `length`) 또는 값 없음 + usage 존재 → 확정 호출로 적립. **그 밖의 `finish` 값은 정상 완료로 기본 처리하지 않고 제외**하며, 원본 값을 사유와 함께 기록한다.
5. 스키마가 확인되기 전에는 **지원 완료로 표시하지 않는다.**
6. 알려진 결함(수정 완료): 기준선이 열려 있는 동안 추가·갱신 두 경로 중 하나만 끝나도 기준선이 완료로 표시되어 **남은 과거 행이 신규로 적립**되었다. 두 경로가 모두 소진될 때만 기준선을 닫도록 수정했고, 회귀 테스트를 추가했다. 이미 적립된 과거분은 재계산·회수하지 않았다(§11 참조).

## 7-A. 파일 발견 규칙 (Codex·Claude Code, 2026-09-24)

- **발견은 자르지 않는다.** 슬라이스는 루트 아래 일치하는 파일을 모두 본다(최근 수정 순). 예산(`maxFiles`·`maxBytes`·`maxRecords`)은
  **내용을 읽는 파일**에만 적용된다. 이전에는 발견 자체를 8개에서 멈춰, 디렉터리 순회가 매번 같은 8개를 돌려주는 탓에 나머지 파일이
  영구히 보이지 않았다(실제 기록: Codex 3,230개 중 8개만 추적, Claude Code 99개 중 10개).
- 파일별 처리(`UsageFilePlan`): 기준선 중 → 끝에 기준선(읽지 않음) · 처음 봤고 연결 뒤 미수정 → 기준선(읽지 않음) · 처음 봤고 연결 뒤
  수정 → 처음부터 읽되 발견 당시 있던 구간은 레코드 시각으로 연결 전/후 판정 · 아는 파일 → 늘어난 만큼 읽음 · 짧아짐(교체) → 연결 뒤
  수정이면 처음부터 다시(이미 기록된 호출은 identity로 중복 처리).
- 읽지 않고 잡은 Codex 기준선은 누적값·세션 id를 "미확인"으로 두고, 파일이 실제로 늘어날 때 경계 앞 512 KB와 헤더에서 찾는다.
- 한 슬라이스에서 새로 기준선을 표시하는 파일 수는 `maxNewFiles`(기본 1,000)로 제한한다(트랜잭션 크기 제한일 뿐, 보이는 범위 제한이 아님).
- 실측: 실제 Codex 루트 3,230개 파일 메타데이터 열거 23–36 ms.

## 7. 기준선·중복·순서 (도구 공통)

- 소스마다 독립된 기준선을 가진다. 새 소스를 연결해도 기존 OMP의 연결·checkpoint·pause는 변하지 않는다.
- 소스별 **관찰 여부**와 **실제 호출의 지급 여부**를 분리한다: 새 소스의 baseline이 다른 소스의 정당한 신규 보상을 막지 않는다.
- 관찰 순서가 달라도 총 적립·나머지가 같도록 소스는 `(tool, connected_at)` 순으로 결정적으로 스캔하고, 나머지는 순차 가산으로만 계산한다(합은 교환법칙이 성립하므로 총액·나머지가 순서에 무관하다).
- 부모 합계와 자식 상세를 동시에 보상하지 않는다(도구별로 §4~§6의 정책을 따른다).
- 임의 복사·미래 포맷까지 완벽한 교차 중복 제거를 보장하지 않는다. 검증한 경우(호출 키·provider+response)와 식별 불가능한 경우를 구분해 기록한다.

## 8. 이번 구현이 추가한 것 (U1)

| 영역 | 내용 |
|---|---|
| 스키마 v5 | `usage_source.tool_kind`(기존 행 = `omp`), `tool_version`, `format_version`; `usage_event.reasoning_tokens`, `normalization_version`, `call_key`; 신규 `usage_cursor`; `usage_event_by_call_key` 인덱스 |
| 소스 식별 | `UsageSourceIdentity` — `tool` + 정규화(심볼릭 링크 해제) 경로에서 유도. 재시작마다 새 ID를 만들지 않는다 |
| 다중 소스 API | `usageSources()`, `usageSource(id:)`, `usageSource(tool:)`, `connectUsageSource(tool:rootPath:)`(같은 저장소 재선택 시 기존 행 재사용), 소스별 상태·pause·baseline, `usageCursors`, `usageToolTotals` |
| 트랜잭션 | `applyUsageBatch`가 커서·세션 관찰을 **같은 트랜잭션**에서 저장. checkpoint만 먼저 전진하지 않는다 |
| 중복 | `call_key` 조회를 provider+response 조회보다 **먼저** 수행하고, 별칭(alias)으로만 기록한다 |
| 어댑터 경계 | `UsageSourceAdapter`(candidates/inspect/scanSlice), `UsageSliceRequest/Output`, `UsageScanBudget`, `UsageAdapterRegistry`, `UsageJSONLReader`(레코드 경계·부분 줄·심볼릭 링크 공용) |
| coordinator | `UsageCoordinator`: 소스별 1슬라이스/패스 + 회전 시작점, 소스별 오류 격리, pause/resume/disconnect, `applyUsageBatch` 한 트랜잭션 커밋. OMP는 아직 기존 `OMPUsageCollector`가 담당 |
| 연결 정책 | 같은 도구·같은 경로 재선택 → 기존 행 재사용(기준선 유지). 같은 도구·다른 경로 → **별도 소스 추가**(기존 소스를 끊지 않음). 끊기는 사용자 명시 동작으로만 |
| Codex 어댑터 | `CodexUsageAdapter` + fixture 7개(기준선·반복 알림·리셋·다중 호출 점프·캐시 관계·부분 줄·재스캔·형식 인식) |
| Claude Code 어댑터 | `ClaudeCodeUsageAdapter` + fixture(확정 usage·캐시/thinking 제외·서브에이전트 포함과 부모 복사본 1회·식별자 없음·부분 줄/재스캔·형식 인식) |
| OpenCode 어댑터 | `OpenCodeUsageAdapter` + 읽기 전용 SQLite open + fixture 5개(복합 커서·같은 시각 다중 행·늦게 채워진 행·역할 필터·스키마 불일치) |

## 9. 직접 확인하는 방법

```bash
./scripts/usage-connect.sh --status       # 실사용(production) 프로필의 연결·도구별 인정량
./scripts/usage-connect.sh codex          # 도구 연결 (연결 시점이 기준선, 과거 기록 소급 없음)
./scripts/usage-connect.sh --disconnect codex   # 연결 해제 (다른 도구는 그대로)
./scripts/test.sh            # 전체 회귀 (280+ 선언)
./scripts/verify.sh          # 게이트: 테스트 · release 빌드 · 카탈로그 3종 · pool · 앱 번들
```

앱에서 직접 확인하는 순서:

1. `./scripts/run.sh` 로 실행 → 설정 탭 → **"AI 사용량 도구"** 패널
2. "감지된 후보"에 Codex·Claude Code·OpenCode 경로가 마스킹되어 표시됨(자동으로 연결되지는 않음)
3. **연결**을 누르면 그 시점이 **기준선**이 되고, 그 뒤 발생한 사용량부터 공통 지갑에 적립됨
4. Today 탭에서 **도구별 인정 토큰**과 공통 합계를, 메뉴바에서 오류 도구 수를 확인
5. 연결 해제·일시정지/재개는 도구별로 독립적으로 동작

## 10. 추가 도구 조사 (설치본 확인, 어댑터 미구현)

이 머신에 실제로 설치되어 있는 후속 후보와 그 저장소를 읽기 전용으로 확인한 결과입니다. **어댑터는 아직 구현하지 않았습니다.**

| 도구 | 설치 버전 | 저장소(관찰) | 비고 |
|---|---|---|---|
| pi | 0.87.0 | `~/.pi/agent/sessions/` (세션 디렉터리 구조), `~/.pi/agent/run-history.jsonl` | OMP와 같은 pi 계열 |
| senpi | 2026.8.24 | `~/.senpi/agent/` (`.omo`, `.senpi`, `omo-senpi` 하위 포함) | omo의 엔진 |
| omo | 5.0.0-0.beta.82 (**engine: senpi 2026.9.22**) | `~/.omo/sessions/<project>/<timestamp>_<id>.jsonl` | **pi/OMP와 동일한 세션 레이아웃** |
| hermes | v0.21.3 | `~/.hermes/state.db` (SQLite), `.icarus-telemetry.jsonl` | 다른 계열 |
| grok | 1.0.40 | `~/.grok/worktrees.db` (SQLite), `sandbox-events.jsonl` | 다른 계열 |
| gajae | 미설치 | — | 설치 전에는 계약 확인 불가 |

**결론(다음 작업의 근거)**
1. pi·senpi·omo는 **한 계열**로 보이며 세션 JSONL 레이아웃이 OMP와 같습니다 → 어댑터 1종(+루트별 등록)으로 3종을 덮을 가능성이 큽니다. 다만 **각 설치본에서 실제 필드·`version`을 확인한 뒤**에만 지원으로 올립니다.
2. **omo와 senpi는 저장소가 겹칩니다**(omo 엔진 = senpi, `~/.senpi/agent/.omo`·`~/.omo/.senpi` 공존) → 두 제품을 별도 소스로 등록하면 **같은 호출을 두 번 읽게 됩니다.** 등록 시 동일 물리 저장소 판별(정규 경로 + 세션 ID)로 중복을 차단해야 합니다.
3. hermes·grok은 SQLite 계열이라 OpenCode와 같은 **읽기 전용 DB 어댑터** 패턴을 재사용해야 하며, 스키마 확인 전에는 지원으로 올리지 않습니다.
4. gajae는 설치되어 있지 않아 계약을 확인할 수 없습니다.

## 11. 구현·검증 상태 (정직한 현재 값)

| 도구 | 공통 구조 연결 | 어댑터 코드 | fixture 테스트 | 실제 과거 로그 파싱 | 실제 신규 적립 | 실제 P 지급 |
|---|---|---|---|---|---|---|
| OMP | 됨(기존 경로 유지) | 있음(기존) | 있음(기존 81개) | 확인(기존 M3) | 확인(기존) | 확인(기존) |
| Codex | 연결·수집 경로 연결됨 | **있음** (`CodexUsageAdapter`) | **7 + 2개**(coordinator e2e) | **확인**: 실제 저장소 6개 파일 667레코드에서 **59개 호출 파싱**(예산 한도 내, 제외 5건) | **합성 fixture로 확인**(baseline·증분·재스캔 무적립) | 합성 fixture에서 1 P 확인 |
| Claude Code | 연결·수집 경로 연결됨 | **있음** (`ClaudeCodeUsageAdapter`) | **5개** | **확인**: 실제 transcript 6개 파일 2,111레코드에서 **504개 호출 파싱**(예산으로 중단) | 없음(어댑터 단위까지) | 없음 |
| OpenCode | 연결·수집 경로 연결됨 | **있음** (`OpenCodeUsageAdapter`) | **5개** | **확인**: 실제 DB 21,854행에서 **8,732개 호출 파싱** | 없음(어댑터 단위까지) | 없음 |

- 세 신규 도구는 **지원 완료로 표시하지 않는다.** 설정 화면의 연결 항목도 만들지 않았다(coordinator·UI 미구현이므로).
- 세 어댑터의 실제 코퍼스 파싱을 개발자 머신의 읽기 전용 프로브(예산 한도, 공개판에는 없음)로 확인했다: Codex 59건, Claude Code 504건, OpenCode 8,732건 파싱.
- **실제 신규 적립·P 지급은 아직 미검증**이다: 연결 이후 자연 발생한 새 기록이 생기면 그때 확인한다(과거 기록은 소급 지급하지 않는다).
- 설정 화면에는 도구별 연결 항목(감지 후보·형식 검사·기준선 진행·인정 토큰·연결/일시정지/연결 해제)이 있으며, 도구를 연결하면 그 시점이 기준선이 된다. 실제 적립이 확인되기 전까지는 검사 상태를 "지원"으로 올리지 않고 **형식 검사 결과**만 표시한다.
- OpenCode는 확인된 스키마에 맞춰 읽기 전용으로만 접근한다. `finish` 값의 어휘는 미확인이라 보상 판단에 쓰지 않고 원문 그대로 기록만 한다.
- 이번 세션은 U1(공통 구조)까지 완료했고, U2(어댑터)·U3(화면·백업)·U4(통합 검증)는 남아 있다.
- 다음 세션은 §4~§6의 계약에 따라 어댑터를 순수 파서로 구현하고, 실제 코퍼스 읽기 전용 파싱(임시 PackTrace DB)까지 확인해야 "실제 과거 로그 파싱" 칸을 채울 수 있다.

## 12. 추가 도구 어댑터 (2026-09-24, `feat/more-ai-tools`)

§10에서 조사만 했던 도구를 실제 저장소 형식을 **읽기 전용으로 확인한 뒤** 구현했다(구조·키·숫자만 확인, 본문 미출력).

| 도구 | 저장소 | 인정 토큰 | 식별 | 제외 | 근거(이 Mac 실측) |
|---|---|---|---|---|---|
| pi · omo · senpi | `~/.pi/agent/sessions` · `~/.omo/sessions` · `~/.senpi/agent/sessions` (OMP와 같은 세션 JSONL v3) | `input` + `output` (`input`은 비캐시: 캐시 읽기가 더 큰 기록 84~85%) | 응답 ID, 없으면 항목 ID. 도구를 넘는 `call_key = pi-entry:<항목>@<시각>` | 로컬·테스트 모델(lm-studio·ollama·omlx·faux 등), `error`·`aborted` | omo·senpi 공유 세션 50개(omo가 senpi 세션을 복사, `.migrated-from-senpi`) → `call_key`로 한 번만. 서브에이전트 실행(`run-N/session.jsonl`)은 별도 호출이라 읽음. `claude-sdk-oauth` 호출은 Claude Code transcript와 겹침 0건(시각·토큰 대조) |
| Hermes | `~/.hermes/state.db` `session_model_usage` (SQLite, 읽기 전용) | 행 누적값의 **증가분** 입력 + 출력 (`input_tokens`는 비캐시: 137/203) | 세션·모델·작업·제공자 + 누적 상태 | 로컬 주소(localhost) 모델(`custom` 93행), 줄어든 누적값(재기준) | 호출별 기록이 없어 누적값 증가분만. 연결 시점 값은 기준선 |
| Grok | `~/.grok/sessions/**/updates.jsonl` `turn_completed.usage` | (`inputTokens` − `cachedReadTokens`) + `outputTokens` | 세션 ID + `prompt_id` | `error` 턴 | 캐시 읽기가 입력보다 큰 기록 0건 → 입력에 캐시 포함. `totalTokens` = 입력 + 출력 → 추론은 출력 안 |
| Kimi | `~/.kimi-code/sessions/**/session_<id>/agents/*/wire.jsonl` `event.usage` | `inputOther` + `output` | `messageId` | 오류·취소 | 세션 3개(소량) |
| Zed | `threads.db`(zstd 압축) | — | — | 미구현 | macOS 기본 압축 해제가 zstd를 지원하지 않음 |

실제 저장소 파싱(개발자 머신의 읽기 전용 프로브, 예산 한도 1회, 공개판에는 없음): omo 525건 · senpi 643건 · grok 턴 인식 · kimi 1건 · hermes 328행 인식(기준선 모드라 적립 0). 모두 연결 뒤 사용량만 적립한다.

