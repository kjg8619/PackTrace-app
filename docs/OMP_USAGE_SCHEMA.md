# PackTrace — OMP 사용량 로그 계약

기준일: 2026-09-22 · 확인한 설치본: `omp/18.2.8` (`~/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js`, 25,957,469 bytes)
확인 방법: 설치본 소스에서 경로·usage 계산 코드를 읽고, 실제 로그 50개(메인 세션) + 171개(서브에이전트) 파일의 **구조만** allowlist로 집계했다. 본문·프롬프트·도구 인자는 읽지 않았고, 숫자·식별자 메타데이터만 셌다.

> 이 문서는 관찰한 사실과 아직 검증하지 못한 것을 구분해 적는다. upstream 최신 구현이 이 설치본과 같다고 가정하지 않는다.

## 0. 읽는 범위와 저장 범위 (용어)

| 표현 | 뜻 |
|---|---|
| 원본 레코드 | 로그 파일의 한 줄(JSON Lines). 본문·thinking·도구 인자·결과를 포함한다 |
| usage 메타데이터 | 그 줄 안의 `message.usage` 객체와 `provider`/`model`/`responseId`/`stopReason`/`timestamp` 등 앱이 쓰는 필드 |
| 본문을 **읽는다** | 파서가 그 줄을 JSON으로 해석하기 위해 줄 바이트를 메모리에 올린다. 줄 단위 상한(8 MiB)까지만 |
| 본문을 **저장·출력한다** | 금지. 앱 DB·fixture·문서·보고서 어디에도 본문을 남기지 않는다 |

정상 무사용량(예: `toolResult`, `custom`, `compaction`, `title` 레코드)과 제외/오류로 인한 무적립은 다르다. 전자는 "적립 대상 아님", 후자는 "사유가 기록된 제외"이며 앱은 둘을 구분해 표시한다.

## 1. 로그 루트 결정 방식

소스에서 확인한 순서(추측 아님):

| 우선순위 | 결정 방식 | 근거(소스 심볼) |
|---|---|---|
| 1 | `--session-dir <path>` CLI 옵션 | `"--session-dir": (e,t)=>{e.sessionDir=t}` |
| 2 | `PI_CODING_AGENT_SESSION_DIR` 환경변수 | `sessionDir: Re.PI_CODING_AGENT_SESSION_DIR || void 0` |
| 3 | `<agentHome>/sessions` | `Xs.agentSubdir(e,"sessions","data")` |
| 4 | agentHome = `PI_CODING_AGENT_DIR` 또는 profile 디렉터리, 기본 `~/.omp/agent` | `agentDirOverride`, `PI_CODING_AGENT_DIR`, 프로필은 `OMP_PROFILE`/`PI_PROFILE` |

앱은 이 순서로 후보를 제안하고, 사용자가 폴더를 직접 고를 수 있게 한다. 경로는 로컬 설정에만 저장하며 문서·진단에는 마스킹해서 남긴다.

실제 배치(확인):

```
<sessions root>/<프로젝트 슬러그>/<YYYY-MM-DDTHH-MM-SS-mmmZ>_<sessionId>.jsonl   ← 메인 세션 (depth 2)
<sessions root>/<프로젝트 슬러그>/<sessionId>/<n>-<Name>.jsonl                  ← 서브에이전트 (depth 3)
<sessions root>/<프로젝트 슬러그>/<sessionId>/*.log                             ← 도구 실행 로그(사용량 없음)
```

파일 stem은 항상 `..._<sessionId>`이고, 헤더의 `id`와 일치한다(50/50 확인).

## 2. 인코딩·레코드 경계·헤더

| 항목 | 확인 값 |
|---|---|
| 인코딩 | UTF-8 JSON Lines, 레코드 1개 = 1줄, `\n` 종료 |
| 레코드 종류 | `title`, `session`, `message`, `custom`, `custom_message`, `model_change`, `thinking_level_change`, `title`, `title_change` |
| 헤더 위치 | 0번 줄 `title`(제목 캐시), 1번 줄 `session` — 세션 3개 표본 모두 동일. 파서는 위치를 가정하지 않고 `session` 레코드를 찾는다 |
| `session` 헤더 키 | `cwd`, `id`, `timestamp`, `title`, `titleSource`, `type`, `version` |
| 헤더 `version` | 50개 파일 모두 `3` |
| 라이브 파일 | 현재 진행 중인 세션 파일도 마지막 줄이 `\n`으로 끝났다(완성 레코드만 append). 그래도 파서는 마지막 개행 이후 부분 레코드를 소비하지 않는다 |
| 본문 없는 필드 | 레코드 공통: `id`, `parentId`, `timestamp`, `type` |

`custom` 레코드 종류(전체 집계): `tool_execution_start` 11,943 · `user_todo_edit` 668 · `session_exit` 26 · `todo_hud_state` 15 — **사용량을 담은 custom 레코드는 없음**(또는 발견되지 않음).

## 3. assistant 메시지와 usage

`message` 레코드의 role 분포: `assistant`, `toolResult`, `user`. 보상 대상은 **assistant만**이다.

assistant 메시지 키:

```
api, completedAt, content, contextSnapshot, duration, model, provider,
responseId, role, stopReason, timestamp, ttft, usage
```

usage 키(필수/선택):

| 필드 | 의미 | 보상 |
|---|---|---|
| `input` | **비캐시 입력** (소스 확인) | 포함 |
| `output` | 출력 토큰 | 포함 |
| `cacheRead` | 캐시에서 읽은 입력 | 제외 |
| `cacheWrite` | 캐시 쓰기 | 제외 (이 코퍼스에서는 항상 0) |
| `totalTokens` | `input + output + cacheRead + cacheWrite` | 합산에 쓰지 않음 |
| `reasoningTokens` | 추론 토큰, **output에 포함**되어 있음 | 다시 더하지 않음 |
| `cost` | 금액 추정치 | 사용하지 않음 |

`input`이 비캐시 입력이라는 근거(소스):

```js
function y6e(e){
  let t = e.cacheWriteOpenRouter ?? e.cacheWriteDeepSeek ?? 0,
      s = e.hasDeepSeekCacheHitAndMiss && e.cacheWriteOpenRouter === undefined && (e.cacheWriteDeepSeek ?? 0) > 0,
      n = s ? Math.max(0, e.promptTokens - e.cachedTokens)
            : Math.max(0, e.promptTokens - e.cachedTokens - t),
      o = s ? 0 : t;
  return { input: n, output: e.outputTokens, cacheRead: e.cachedTokens, cacheWrite: o,
           totalTokens: n + e.outputTokens + e.cachedTokens + o, ... }
}
```

즉 OMP가 `promptTokens − cachedTokens`를 이미 계산해 `input`에 넣는다. 따라서 **cacheRead를 다시 빼지 않는다**. `reasoningTokens`는 `output`에서 파생된 세부값이므로 다시 더하지 않는다(소스: `...(e.reasoningTokens>0?{reasoningTokens:e.reasoningTokens}:{})`).

실제 로그 교차 검증(메인 세션 10,146개 assistant 레코드):

- `input + output + cacheRead + cacheWrite == totalTokens` : **10,146/10,146 일치**
- 음수·소수 필드: **0건**
- 필드 범위: input 0–769,428 · output 0–46,324 · cacheRead 0–849,664 · cacheWrite 항상 0

## 4. 시각과 식별자

| 항목 | 확인 값 |
|---|---|
| 레코드 `timestamp` | ISO-8601 문자열(레코드 생성 시각) |
| `message.timestamp` | **epoch 밀리초 (number)** — 요청 시작 시각. 확인 범위 2026-05-11 ~ 2026-09-22 |
| `message.completedAt` | epoch 밀리초 (number) — 응답 종료 시각 |
| `message.duration`, `ttft` | 밀리초 (보상에 사용하지 않음) |
| `sessionId` | `session.id`(UUID v7 계열) == 파일명 접미사. 유일성 범위: 로컬 전체 |
| `responseId` | provider가 준 응답 식별자, 형식 `gen_<26자 ULID>`. assistant 레코드마다 존재 |
| 레코드 `id`/`parentId` | 로그 트리 식별자. 보상 키로 쓰지 않음 |

`responseId` 유일성 실측:

- 메인 세션 50개 파일 · assistant 10,146건 → **고유 ID 10,079개, 중복 0건**
  (응답 ID가 없는 레코드는 37건 있었고, 이들은 보상 대상에서 제외한다.)
- 서브에이전트 171개 파일 · assistant 1,913건 → 고유 ID 1,913개, **메인과 교집합 0건**

따라서 앱의 이벤트 키는 `omp:<sessionId>:<responseId>`로 두고, `UNIQUE` 제약으로 중복 지급을 막는다.

## 5. usage의 확정성

| 질문 | 관찰 결과 |
|---|---|
| 요청별 확정값인가? | 그렇다. assistant 레코드 1개 = API 호출 1회, `completedAt`이 있는 완결 레코드 |
| 누적값인가? | 아니다. `cacheRead`가 수십만까지 가는 것은 컨텍스트 캐시 크기이며 누적 카운터가 아니다 |
| 중간 스트리밍 값인가? | 아니다. 스트리밍 델타는 별도 레코드로 저장되지 않고, `type` 분포에 부분 usage 레코드가 없다 |
| usage 수정 레코드가 있는가? | 없다. 같은 `responseId`가 두 번 나오지 않고(중복 0), 사용량을 담은 `custom` 레코드도 없다 |
| 파일 재작성(rewrite)이 있는가? | 관찰되지 않았다(append-only). 그래도 파서는 같은 ID의 값이 다르면 **충돌로 격리**하고 자동 지급·덮어쓰기를 하지 않는다 |

## 6. stopReason별 처리

| stopReason | 건수 | input 합계 | output 합계 | 0토큰 행 | responseId 있음 | 앱 정책 |
|---|---:|---:|---:|---:|---:|---|
| `toolUse` | 9,697 | 72,107,312 | 7,381,418 | 0 | 9,697 | **보상** |
| `stop` | 353 | 3,586,493 | 294,668 | 37 | 316 | **보상** (응답이 정상 종료됨) |
| `error` | 69 | 79,802 | 3,194 | 68 | 58 | 제외 (`stop_reason_error`) |
| `aborted` | 29 | 0 | 0 | 29 | 10 | 제외 (`stop_reason_aborted`, 전부 0토큰) |
| 그 외/누락 | 0 | - | - | - | - | 제외 (`unknown_stop_reason`) |

정상 종료(`stop`, `toolUse`)만 보상한다. `error`는 provider 오류로 끝난 호출이고, 68/69가 0토큰이지만 1건은 값이 있어 **일관성이 확인되지 않으므로** 제외한다. `aborted`는 29건 모두 0토큰이며, 중단 호출의 청구 의미가 확인되지 않아 제외한다. 제외 건은 사유와 함께 로컬에 기록만 한다.

## 7. 보상 범위 (지원/제외)

**지원**: 검증된 OMP 메인 세션(`<root>/<project>/<session>.jsonl`)의 확정 assistant usage.
첫 검증 경로는 provider `commandcode` + model `deepseek/deepseek-v4.1-flash`(현재 개발 경로)이며, 로그에서 이 조합은 4,062건으로 확인됐다.

| 항목 | 처리 | 이유 |
|---|---|---|
| provider `commandcode` | 지원 | 실제 로그로 필드 의미·확정성 확인 |
| 그 외 모델 서비스(openai-codex, openrouter, codex-lb 등) | **지원(2026-09-24부터)** | pi 계열이 usage를 공통 정규화한다: 캐시가 있는 호출에서 `cacheRead > input`이 openai-codex 98% · openrouter 97% · codex-lb 95%(commandcode 99%)로 같은 의미(비캐시 input). 이전에는 `provider_not_verified`로 제외했고, 그때 기록된 이벤트는 소급 적립하지 않는다 |
| 로컬·테스트 모델(lm-studio, ollama, omlx, mlx, faux 등) | 제외(`local_model_excluded`) | 이 Mac에서 도는 모델·가짜 provider: 비용이 없고 포인트를 무한히 만들 수 있다 |
| provider 없음 | 제외(`provider_not_verified`) | 출처를 알 수 없음 |
| `model_usage` 성격의 기록 | 해당 레코드 없음 | 이 버전에서는 관찰되지 않음 |
| compaction | assistant 메시지로 기록되지만 모델·provider가 다름 | 2026-09-24부터: 모델 서비스 호출이면 실제 사용량이라 인정, 로컬 모델이면 제외(위 provider 정책) |
| subagent(depth 3 jsonl) | 제외(`subagent_excluded`) | 부모 세션과의 중복 관계를 검증하지 못함. ID 교집합이 0인 것은 확인했으나 포함 근거로는 불충분 |
| advisor | 별도 파일로 관찰되지 않음 | 위와 동일 |
| `custom` 레코드 전부 | 제외 | 사용량 필드 없음 |

일부만 지원하므로 앱은 “OMP 전체 사용량”이나 “공식 청구 사용량”이라고 표시하지 않고 **“OMP 메인 세션 중 검증된 경로의 확정 사용량”**이라고 쓴다.

## 8. 앱이 저장하는 것 / 저장하지 않는 것

저장: `sessionId`, `responseId`, `model`, `provider`, `stopReason`, `occurred_at`(UTC epoch ms), `completed_at`, `input`, `output`, `cacheRead`, `cacheWrite`, 인정 토큰, 처리 상태·사유, 파일 checkpoint(상대 경로·inode·offset·baseline 경계).

저장하지 않음: 프롬프트·응답 본문, thinking, 도구 인자/결과, `cwd`(세션 헤더에서 읽지 않음), 인증정보, 이미지·첨부, `cost` 값.

## 9. 재현 방법

이 문서의 수치는 다음 방법으로 재측정한다(본문은 읽지 않는다):

```bash
# 구조만 집계: 레코드 종류·usage 필드·정수 범위·totalTokens 항등식·responseId 중복
python3 /tmp/scan_omp.py     # §3·§4 표
python3 /tmp/scan2.py        # §6 stopReason 표
python3 /tmp/scan3.py        # provider/model/헤더 버전
```


## 10. fork·가져오기(상속) 이벤트 identity

설치본 소스에서 확인한 사실:

| 항목 | 확인 내용 |
|---|---|
| fork 경로 | `SessionManager.forkFrom(source, cwd, dir, …, opts)` — 원본 세션 엔트리를 `structuredClone`해 **새 세션 파일**(새 `id`)에 쓴다. 옵션에 `sessionFile`, `copyArtifacts`, `suppressBreadcrumb`, `resetInheritedCost`, `repairInterruptedTail`이 있다 |
| 복제되는 필드 | 엔트리를 구조 복제하므로 `message.responseId`와 엔트리 `id`가 그대로 보존된다. `vre()`는 `session` 레코드만 걸러내고 나머지를 새 파일에 쓴다 |
| 원본 관계 필드 | 세션 헤더에 선택적 `parentSession`이 있다(`mdi`/`gdi`가 파싱). 실제 코퍼스 50개 헤더에서는 **0건**(이 환경에서 fork/가져오기가 아직 없었음) |
| 기타 세션 플래그 | `--fork <session>`, `--from-claude`, `--from-codex`, `--continue`, `-r/--resume` |

앱의 처리:

- 이벤트 키는 `omp:<sessionId>:<responseId>` 그대로 두고, **원본 호출 키(provider + responseId)** 로 한 번 더 중복을 막는다. 세션이 바뀌어 같은 호출이 다시 나타나면 `usage_event_alias`에 매핑만 남기고 지급하지 않는다(진단: `duplicate_original_call`).
- 같은 원본 호출인데 토큰 수가 다르면 충돌로 격리한다(`identity_conflict`). 자동 덮어쓰기·추가 지급은 없다.
- 연결 **이후 처음 보는 파일**은 그 안의 기록이 모두 신규라고 가정하지 않는다. 호출 발생 시각이 연결 시각보다 이르면 `baseline`(`inherited_pre_connection`)로 기록해 지급하지 않고, 연결 이후 시각의 호출만 적립한다.
- 관찰한 세션과 `parentSession`은 `usage_session`에 진단용으로만 기록한다. 보상 결정에 쓰지 않는다.

**검증 근거 구분**

| 근거 | 상태 |
|---|---|
| 설치 소스에서 fork 동작·복제 필드 확인 | 확인 |
| 합성 fixture로 "세션만 바뀐 동일 호출" 재현(5개 시나리오) | 확인(테스트) |
| 같은 파일을 복사한 경우 | 확인(테스트, 세션 ID 동일) |
| 실제 `--fork`/`--from-claude` 실행 | **미검증** — 에이전트 세션을 시작해야 하고 모델 호출·사용자 상태 변경이 따르므로 이 환경에서 실행하지 않았다 |
| 실제 로그에 `parentSession`이 있는 사례 | **0건**(50개 헤더) |

## 11. 레코드 크기 한계 (M3.1)

"4 KiB"는 **테스트 전용 제한**이었다(합성 테스트에서 `Limits(maxLineBytes: 4 * 1024)`). 실제 앱의 기본 상한은 다르다.

| 항목 | 값 |
|---|---|
| 한 레코드(한 줄) 상한 | **8 MiB** (`maxLineBytes`. 초과 시 원문 없이 사유만 기록하고 다음 레코드로 진행) |
| 한 슬라이스 바이트 예산 | 32 MiB (`maxBytesPerSlice`. **레코드 사이에서만** 적용 — 예산을 넘겨도 진행 중인 레코드는 끝까지 읽는다) |
| 한 슬라이스 레코드 수 | 2,000 |
| 읽기 청크 | 1 MiB, 단 `min(chunkBytes, maxLineBytes)`로 제한 |
| 마지막 개행 이후 부분 레코드 | 소비하지 않고 checkpoint를 전진시키지 않는다 |
| 상한 초과 레코드 | 그 레코드 전체(버린 앞부분 포함)를 지나 checkpoint를 전진시킨 뒤 1건으로 집계 |

실제 코퍼스 측정(2026-09-22, 50개 세션 226.9 MB, 37,935줄):

| 항목 | 값 |
|---|---|
| 가장 큰 줄 | 3,473,317 B (3.3 MiB, `message/toolResult`, usage 없음) |
| 가장 큰 `message/assistant` 줄 | **133,164 B (130 KiB)** |
| usage를 가진 줄 중 64 KiB 초과 | 36건 (전부 130 KiB 이하) |
| usage를 가진 줄 중 256 KiB 초과 | **0건** |
| 4 KiB 초과 줄 | 11,219건(대부분 정상 usage 레코드) |

즉 현재 코퍼스에서는 8 MiB 상한이 한 번도 발동하지 않으며, 크기 때문에 누락되는 정상 usage는 없다. 상한을 넘는 입력이 생기면 그 레코드만 제외되고 뒤 레코드는 정상 처리된다. OMP 설치본 자체는 8 MiB를 파일 단위 빠른 로드 임계값(`qci`)으로 쓰며, 줄 단위 상한은 없다.

## 12. 미검증 항목

1. 실제 `--fork`/`--from-claude`/`--from-codex` 실행 검증 — 소스상 복제 엔트리는 `responseId`를 보존하지만 실행으로 확인하지는 않았다(모델 호출·사용자 상태 변경을 일으키므로 제외). 보존되면 원본 호출 중복으로 차단되고, 보존되지 않으면 신규 호출로 적립된다.
2. compaction 호출이 남기는 assistant 레코드의 정확한 provider/model 조합(정책상 제외되지만, 어떤 이름으로 나타나는지는 미확인).
3. OMP가 향후 버전에서 `version` 값을 올리거나 usage 필드 의미를 바꿀 가능성 — 앱은 `version != 3`이면 해당 파일을 `unsupported`로 표시하고 지급하지 않는다.
4. 로그 회전·삭제 정책(OMP가 오래된 세션을 지우는지) — 삭제되어도 이미 적립된 포인트는 유지된다.
5. provider별 `cacheWrite` 의미(이 코퍼스에서는 항상 0이라 검증 불가).
