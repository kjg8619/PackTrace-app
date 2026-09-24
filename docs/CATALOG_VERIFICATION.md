# PackTrace — 카탈로그 검증 기록

> 공개판 안내: 원 저장소의 검증 기록이다. 공개판에는 카드 카탈로그 스냅샷(`catalog-manifest.json`과 `scripts/prepare-catalogs.sh`로 설치)과 포장 그림 레지스트리 항목(출판사 그림, 재배포하지 않음)이 들어 있지 않다.

기준일: 2026-09-22 · 대상: 교환 후보 팩 상품 3종 (영문판 sv01 · sv02 · sv03)
이 문서는 **실제 확인한 값**과 **확인하지 못한 값**을 구분해서 적는다.

교환 후보 pool: `packs-v1` (가중치 1:1:1, 가격 100 P). 후보를 바꾸면 앞으로의 교환에만 적용되고,
이미 받은 팩은 각자 고정된 `catalogVersion`·`recipeVersion`으로 개봉된다.

| 상품 | 세트 | 언어 | 내부 상품 ID | 카드 정의 | 앱 지원 프린트 | catalogVersion | recipe | 상태 |
|---|---|---|---|---:|---:|---|---|---|
| Scarlet & Violet 부스터 팩 | sv01 | en | `tpcgi-en-sv01-booster` | 258 | 444 | `tcgdex-en-sv01-20260922` | `sv01-booster-sim-v1` v1 | ready-for-reward |
| Paldea Evolved 부스터 팩 | sv02 | en | `tpcgi-en-sv02-booster` | 279 | 455 | `tcgdex-en-sv02-20260922` | `sv02-booster-sim-v1` v1 | ready-for-reward |
| Obsidian Flames 부스터 팩 | sv03 | en | `tpcgi-en-sv03-booster` | 230 | 406 | `tcgdex-en-sv03-20260922` | `sv03-booster-sim-v1` v1 | ready-for-reward |

내부 상품 ID는 PackTrace 자체 식별자이며 제조사 SKU가 아니다.

## 1. 상품

| 항목 | 값 | 근거 |
|---|---|---|
| 상품명 | Pokémon TCG: Scarlet & Violet Sleeved Booster Pack (10 Cards) | Pokemon Center SKU 184-85325, 아카이브 사본 |
| 지역·언어 | US/International · English | 위 상품 페이지, TCGdex `sv01` 언어 `en` |
| 내부 packID | `tpcgi-en-sv01-booster` | `catalog-sources/sv01.json` |
| 데이터 소스 | TCGdex v2 API (`https://api.tcgdex.net/v2/en`) | API 응답 직접 확인 |
| setID | `sv01` (발매 2023-03-31) | TCGdex set 응답 |
| 검증 등급 | `ready-for-reward` | 아래 3·5절 근거 + 7절 미확인 항목 |

## 2. 카드 목록

| 항목 | 값 | 근거 |
|---|---|---|
| 전체 장수 | 258장 (localId 001–258, 누락·중복 없음) | TCGdex set 응답 + 카드별 258회 조회 |
| 공식 번호 | 198장 (001–198) | TCGdex `cardCount.official` |
| 시크릿 | 60장 (199–258) | 258 − 198, 등급 합계로 교차 확인 |
| 등급 분포 | Common 105 · Uncommon 60 · Rare 21 · Double rare 12 · Ultra Rare 20 · Illustration rare 24 · Special illustration rare 10 · Hyper rare 6 | 카드별 조회 집계 |
| 변형 분포 | normal+reverse 165 · holo+reverse 21 · holo 전용 72 · 변형 없음 0 | 카드별 `variants` 집계, set의 `normal/holo/reverse` 합계와 일치 |
| 리버스 가능 | 186장 (Common 105 + Uncommon 60 + Rare 21) | 위 두 집계의 교집합 |
| 부스터 대상 | 258장 전체 (기본 세트 + 시크릿 레어) | 실물 부스터의 시크릿 수록 관행 + 아래 3절 슬롯 구성 |
| 프로모·별도 상품 전용 | 제외 | sv01 번호 체계 밖 카드는 애초에 목록에 없음 |
| 한국어판 | **미검증 · 사용 안 함** | 앱은 영문판 데이터만 사용하고 UI만 한국어 |

## 3. 장수와 슬롯 구성

| 항목 | 값 | 근거 등급 |
|---|---|---|
| 게임 카드 수 | 10장 (Common 4 + Uncommon 3 + 포일 3, 포일 중 최소 1장은 Rare 이상) | **1차**(Pokemon Center Support) |
| 추가 카드 | Basic Energy 1장 + TCG Live 코드 카드 1장 | **1차**(Pokemon Center Support) |
| 포일 3장의 세부 | 리버스 홀로 2장 + Rare 이상 1장, 두 번째 리버스 슬롯은 Illustration/Special illustration/Hyper rare로 대체 가능 | 2차(DigitalTQ)·커뮤니티(Bulbapedia) |

출처:

- **1차**: Pokemon Center Support, “What can I expect in a Pokemon Trading Card Game Booster Pack?”
  <https://support.pokemoncenter.com/hc/en-us/articles/360028979571-What-can-I-expect-in-a-Pok%C3%A9mon-Trading-Card-Game-Booster-Pack>
  인용: “Each booster pack contains 10 game cards: 4 commons, 3 uncommons, and 3 foils (at least one of which will be rare or higher). Each booster pack also contains 1 Energy card and 1 code card…”
- **1차**: Pokemon Center 상품 페이지(아카이브 2023-05-10) “Each booster pack contains 10 cards and 1 Basic Energy.”
  <https://web.archive.org/web/20230510120947/https://www.pokemoncenter.com/product/184-85325/pokemon-tcg-scarlet-and-violet-sleeved-booster-pack-10-cards>
  (라이브 페이지는 이 환경에서 자동 접근 차단 403, 아카이브 사본으로 확인)
- **2차/커뮤니티**: DigitalTQ pull rates, Bulbapedia “Booster pack (TCG)” 국제판 표 (SV 시대 슬롯 표).

## 4. 이미지

| 항목 | 값 | 근거 |
|---|---|---|
| 카드 이미지 | 258장 전부 `low.webp` 응답 200 (245×337). `high`는 600×825 | 258개 URL 확인 |
| URL 규칙 | `https://assets.tcgdex.net/en/sv/sv01/{localId}/{quality}.{ext}`, quality ∈ {low, high}, ext ∈ {webp, png, jpg} | TCGdex Assets 문서 |
| 세트 로고 | `https://assets.tcgdex.net/en/sv/sv01/logo.webp` (200) | 직접 확인 |
| 세트 심볼 | API는 `univ` 경로를 주지만 404. `en/sv/sv01/symbol.webp`가 200 | 직접 확인, 가져오기 도구가 자동 보정 |
| 팩 포장 이미지 | 상품당 실제 은박 부스터 정면 1장을 별도 아트 레지스트리로 적용(PACK-ART-V1). 미설치·판본 불일치면 세트 로고 대체 포장 | `docs/PACK_ARTWORK.md` |
| 캐시 위치 | `<realm>/images/`, 실패 시 대체 화면(소유 정보는 유지) | 앱 구현 |

API 키·쿠키·로그인 없이 공개 자산만 사용한다. 우회 수집 없음.

## 5. 추첨

| 항목 | 값 |
|---|---|
| recipe ID / 버전 | `sv01-booster-sim-v1` v1 (`catalog-sources/sv01.json`) |
| 장수 | 10장, 중복 허용 |
| 슬롯 | ① Common 4 ② Uncommon 3 ③ 리버스 가능 186장 중 1(리버스 고정) ④ 226장 중 1(리버스 또는 IR/SIR/HR) ⑤ 53장 중 1(Rare/Double rare/Ultra Rare) |
| 풀 크기 | 105 · 60 · 186 · 226 · 53 (테스트로 고정) |
| 슬롯 내부 확률 | **균등 추첨(앱 자체 시뮬레이션)**. 슬롯별 등급 구성만 공식 안내를 따르고, 등급별 봉입 확률은 공식 자료가 없어 재현하지 않는다 |
| 변형 규칙 | 카드 데이터에 있는 변형만 사용. holo 전용 카드는 holo, normal+reverse 카드는 슬롯 규칙에 따라 normal 또는 reverse |
| 팩 상품 추첨 | ready 상태 상품에 동일 가중치 1. 현재 1종이므로 100%로 표시 |
| 고정 | 교환 시 `catalogVersion`과 `recipeVersion`을 팩에 저장하고, 개봉은 그 버전의 스냅샷으로만 수행 |

## 6. 검증 시점·버전

| 항목 | 값 |
|---|---|
| 조회 날짜 | 2026-09-22 (KST) |
| 카탈로그 버전 | `tcgdex-en-sv01-20260922` |
| 내용 해시(앱이 로드 시 검증) | `sha256:cdc1bf4c9d40e00e46710a04bf4a45db22e88560482e6e702bffebd9c0af8997` |
| 스냅샷 파일 | `Sources/PackTraceCore/Resources/catalog/tcgdex-en-sv01-20260922.json` |
| 재생성 명령 | `./scripts/fetch-catalog.sh` |

## 7. 확인하지 못한 항목

1. **슬롯별 실제 봉입 확률** — 공식 공개 자료 없음. 앱은 시뮬레이션이라고 표시하며 실제 확률 재현을 주장하지 않는다.
2. **기본 에너지·코드 카드** — 실물 팩에 들어가지만 sv01 번호 체계 밖이다. sv01의 에너지 카드(sv01-257/258)는 Hyper rare 시크릿이고, 팩에 들어가는 기본 에너지는 별도 세트(`sve`)로 API가 이미지를 제공하지 않는다. 앱은 게임 카드 10장만 모델링한다.
3. **포장 아트워크** — PACK-ART-V1에서 상품당 실제 은박 부스터 정면 1장을 등록했다(출처·권리는 `docs/PACK_ARTWORK.md`). 아트워크 사용 권리는 미확인이며, 같은 세트의 나머지 아트 변형·뒷면은 등록하지 않았다.
4. **일부 1차 페이지 접근** — `pokemon.com` 뉴스 페이지와 `pokemoncenter.com` 라이브 상품 페이지는 자동 접근 차단으로 본문 확인 실패. 상품 페이지는 아카이브 사본으로 대체 확인.
5. **한국어판 카탈로그** — 미조사. 영문판과 카드 목록·번호가 다를 수 있다.
6. **실제 팩 3종** — v0.2 범위. 현재 상품 1종만 등록되어 교환 확률은 100%다.

## 7-A. 추가 두 팩 (M4)

### 상품·근거

| 항목 | sv02 Paldea Evolved | sv03 Obsidian Flames |
|---|---|---|
| 상품명 | Pokémon TCG: Scarlet & Violet—Paldea Evolved Sleeved Booster | Pokémon TCG: Scarlet & Violet—Obsidian Flames Sleeved Booster |
| 세트 발매일 | 2023-06-09 | 2023-08-11 |
| 공식 상품 근거 | 공식 확장 페이지 featured products에 "Sleeved Booster" 등재(라이브 확인) + 같은 페이지의 Pokemon Center 링크(`…-sleeved-booster-pack-10-cards`) | 공식 확장 페이지 featured products에 "Sleeved Booster" 등재(라이브 확인) |
| 팩 구성 근거 | 시리즈 공통 1차 자료(Pokemon Center Support, 라이브 확인): 게임 카드 10장 = 커먼 4 + 언커먼 3 + 포일 3(최소 1장 레어 이상) + 에너지 1 + 코드 1 | 동일 |
| 미확인 | 세트 발매일만 확인, 슬리브드 부스터 상품 발매일은 미확인 | Pokemon Center 상품 링크·SKU 미확보(페이지에서 링크 미추출, 인터넷 아카이브 점검 중), 상품 발매일 미확인 |

공식 페이지는 라이브로 확인했고, 상품 SKU 페이지 본문은 자동 접근 차단/아카이브 점검으로 확인하지 못했다.
검색 제목·제3자 목록만으로 VERIFIED로 올리지 않았다.

### 카드 목록·이미지·recipe

| 항목 | sv02 | sv03 |
|---|---:|---:|
| 카드 정의 수(시크릿 포함) | 279 | 230 |
| 공식 번호 카드 수 | 193 | 197 |
| 등급 분포 | Common 81 · Uncommon 70 · Rare 25 · Double rare 17 · Illustration rare 36 · Ultra Rare 26 · Special illustration rare 15 · Hyper rare 9 | Common 92 · Uncommon 74 · Rare 10 · Double rare 21 · Illustration rare 12 · Ultra Rare 12 · Special illustration rare 6 · Hyper rare 3 |
| 슬롯 풀 크기 | 81 / 70 / 176 / 236 / 68 | 92 / 74 / 176 / 197 / 43 |
| 앱 지원 프린트 | 455 | 406 |
| 도달 불가 프린트 | 0 | 0 |
| 다른 세트 카드 혼입 | 0 | 0 |
| 이미지 디코딩 검증 | 279/279 성공 | 230/230 성공 |
| 내용 해시 | `sha256:01b05007…` | `sha256:210d8fb0…` |

이미지 검사는 HTTP 200만 보지 않고 `packtrace-catalog images`로 실제 디코딩까지 확인했다(오류 HTML이 200으로 오는 경우를 걸러내기 위함).
이 명령은 매 빌드·테스트가 아니라 명시적으로 실행한다.

### 인쇄 변형 처리 (M4에서 확인한 데이터 특성)

새 두 세트에는 같은 번호에 **노멀 인쇄와 홀로 인쇄가 함께 표시된 카드**가 있다(sv02 6장, sv03 21장, 그중 sv03의 Double rare 2장은 노멀+홀로).
이 앱은 등급 기준으로 기본 인쇄를 고른다: **Rare 이상은 홀로, Common·Uncommon은 노멀**.
이 규칙은 "스칼렛&바이올렛 시리즈에서 Rare 이상은 부스터에서 홀로"라는 공개 규칙과 일치하며,
덱·프로모 전용으로 보이는 비홀로 인쇄를 부스터 추첨에 섞지 않는다.
sv01의 지원 프린트(444)는 이 변경 전후로 동일하다.

## 7-B. 추가 일곱 팩 — SV04~SV10 (pool packs-v2, 2026-09-24)

스칼렛&바이올렛 시리즈의 **메인 확장 7종**을 더했다. 특수 세트(151·Paldean Fates·Shrouded Fable·Prismatic Evolutions·
White Flare/Black Bolt)와 메가진화 시리즈(me01~)는 팩 구성·희귀도 체계가 달라 이번에 넣지 않았다(별도 근거 필요).

### 상품·근거

| 세트 | 발매일(TCGdex) | 상품 근거 | 검증 상태 |
|---|---|---|---|
| sv04 Paradox Rift | 2023-11-03 | 공식 확장 페이지 featured products에 "…Paradox Rift Sleeved Booster" (2026-09-24 라이브 확인) | ready-for-reward |
| sv05 Temporal Forces | 2024-03-22 | 공식 확장 페이지 "…Temporal Forces Sleeved Booster" (라이브 확인) | ready-for-reward |
| sv06 Twilight Masquerade | 2024-05-24 | 공식 확장 페이지 "…Twilight Masquerade Sleeved Booster" (라이브 확인) | ready-for-reward |
| sv07 Stellar Crown | 2024-09-13 | 공식 확장 페이지는 봇 차단으로 본문 확인 실패. Pokémon Center 상품 페이지 "…Stellar Crown Sleeved Booster Pack (10 Cards)" SKU 190-85900이 **웹 검색 결과**에 있음(본문은 HTTP 403) | **metadata-verified** |
| sv08 Surging Sparks | 2024-11-08 | 공식 확장 페이지 "…Surging Sparks Sleeved Booster" (라이브 확인) | ready-for-reward |
| sv09 Journey Together | 2025-03-28 | sv07과 같음. Pokémon Center 상품 페이지 SKU 100-10326이 검색 결과에만 있음 | **metadata-verified** |
| sv10 Destined Rivals | 2025-05-30 | 공식 확장 페이지 "…Destined Rivals Sleeved Booster Pack" (라이브 확인) | ready-for-reward |

M4와 같은 원칙: 검색 결과만으로는 ready-for-reward로 올리지 않았다. 두 상태 모두 교환 후보가 될 수 있고
(`PackProduct.isRewardEligible`), 설정 > 카탈로그에 상태가 그대로 표시된다.
팩 구성(게임 카드 10장 = 커먼 4 + 언커먼 3 + 포일 3)은 SV 시리즈 공통 1차 자료(Pokemon Center Support)를 따른다.

### ACE SPEC 레어 (sv05~sv08)

sv05~sv08에는 기존 세트에 없던 **ACE SPEC Rare**가 있다(7 · 6 · 3 · 8장, 리버스 인쇄 없음).
2차 자료(tcgrocks.com, Temporal Forces 풀 레이트 기사)는 "약 20팩에 1장, 첫 번째 리버스 홀로 칸"이라고 한다. 1차 자료는 없다.
그래서 이 네 세트의 recipe만 첫 번째 리버스 칸(slot 2)을 `Common/Uncommon/Rare/ACE SPEC Rare`,
`reverseIfAvailableElsePrimary`로 두었다. 이 세트들의 C·U·R은 모두 리버스 인쇄가 있어 나머지 카드의 결과는 기존 규칙(리버스 필수)과 같다.
확률은 다른 슬롯과 마찬가지로 슬롯 안 균등 추첨이다(sv05에서 ACE SPEC 7/147 ≈ 4.8%로, 2차 자료의 1/20과 우연히 비슷하다).
화면 표시: 등급 이름 "에이스 스펙 레어", 개봉 연출 단계는 더블 레어와 같은 3.

### 카드 목록·recipe

| 세트 | 카드 정의 | 공식 번호 | 등급 분포 | 슬롯 풀 | 지원 프린트 | 도달 불가 |
|---|---:|---:|---|---|---:|---:|
| sv04 | 266 | 182 | C 81 · U 54 · R 27 · DR 20 · IR 34 · UR 28 · SIR 15 · HR 7 | 81 / 54 / 162 / 218 / 75 | 428 | 0 |
| sv05 | 218 | 162 | C 71 · U 55 · R 14 · DR 15 · IR 22 · UR 18 · SIR 10 · HR 6 · ACE 7 | 71 / 55 / 147 / 178 / 47 | 358 | 0 |
| sv06 | 226 | 167 | C 76 · U 55 · R 16 · DR 14 · IR 21 · UR 21 · SIR 11 · HR 6 · ACE 6 | 76 / 55 / 153 / 185 / 51 | 373 | 0 |
| sv07 | 175 | 142 | C 71 · U 39 · R 15 · DR 14 · IR 13 · UR 11 · SIR 6 · HR 3 · ACE 3 | 71 / 39 / 128 / 147 / 40 | 300 | 0 |
| sv08 | 252 | 191 | C 88 · U 61 · R 16 · DR 18 · IR 23 · UR 21 · SIR 11 · HR 6 · ACE 8 | 88 / 61 / 173 / 205 / 55 | 417 | 0 |
| sv09 | 190 | 159 | C 85 · U 42 · R 16 · DR 16 · IR 11 · UR 11 · SIR 6 · HR 3 | 85 / 42 / 143 / 163 / 43 | 333 | 0 |
| sv10 | 244 | 182 | C 85 · U 62 · R 18 · DR 17 · IR 23 · UR 22 · SIR 11 · HR 6 | 85 / 62 / 165 / 205 / 57 | 409 | 0 |

모든 세트: 다른 세트 카드 혼입 0, `packtrace-catalog verify` exit 0.

| 세트 | 스냅샷 | 내용 해시 |
|---|---|---|
| sv04 | `tcgdex-en-sv04-20260923` | `sha256:4f6b0566…` |
| sv05 | `tcgdex-en-sv05-20260923` | `sha256:b0ac18c5…` |
| sv06 | `tcgdex-en-sv06-20260923` | `sha256:1667eee1…` |
| sv07 | `tcgdex-en-sv07-20260923` | `sha256:0f072aa1…` |
| sv08 | `tcgdex-en-sv08-20260923` | `sha256:56dd721d…` |
| sv09 | `tcgdex-en-sv09-20260923` | `sha256:a4063973…` |
| sv10 | `tcgdex-en-sv10-20260923` | `sha256:8b6041c1…` |

스냅샷 날짜는 가져온 시각의 UTC 날짜다(한국 시각 2026-09-24 오전). sv01~sv03 스냅샷·해시는 바꾸지 않았다.

### 카드 이미지

`packtrace-catalog images --quality low`로 7세트 1,571장을 실제로 내려받아 디코딩했다(2026-09-24).
sv04~sv09는 전부 성공. **sv10 #028 Arcanine 한 장만 low.webp가 원본에서 404**이고 high.webp는 200이다(TCGdex 쪽 누락).
앱은 썸네일을 받지 못하면 같은 카드의 큰 이미지를 썸네일 크기로 디코딩해 보여 준다(`RemoteImageModel`, 테스트로 고정).
둘 다 실패하면 이전처럼 카드 이름·번호·등급이 있는 "이미지 없음" 자리 표시가 남고, 소유 기록에는 영향이 없다.

### 교환 pool과 포장 그림

- pool `packs-v2`: sv01~sv10 10종, 가중치 모두 1(각 10%), 가격 100 P 그대로. `packs-v1` 파일은 이미 받은 팩의 기록으로 남겨 둔다.

## 7-C. 영문판 전 시대 부스터 — pool packs-v3 (2026-09-24)

요청: "카드 팩을 추가할 수 있는 모든 팩과 카드". 결정(사용자): **영문판 전 시대**, 추첨은 **시리즈별 같은 확률**.

### 범위

- TCGdex 영문 세트 중 **무작위 봉인 팩으로 나온 세트 128종**을 더해 SV01~SV10과 합쳐 **138종**(1999 Base Set ~ 2026-09 30th Celebration).
  낱팩으로 팔지 않고 ETB·컬렉션 안에만 든 특수 세트 팩(151, Hidden Fates, Celebrations, Crown Zenith, 30th Celebration 등),
  오거나이즈드 플레이 배포 팩(POP 1~9), 블리스터 전용 팩(Dragon Vault, Double Crisis, Detective Pikachu)도 무작위로 뽑히는 봉인 팩이라 포함했고,
  상품마다 판매 형태를 미확인 항목에 적었다.
- **넣지 않은 세트**(무작위 부스터가 아님): Southern Islands(si1, 고정 18장 묶음), Sample(sp, 카드 0장), Best of Game(bog, 대회 상품),
  Poké Card Creator Pack(ex5.5, 고정 5장), Pokémon Rumble(ru1, 고정 16장), Kalos Starter Set(xy0, 테마덱), Yellow A Alternate(xya, 다른 상품의 대체 인쇄),
  Radiant Collection(rc, 원본에 카드 0장 — 실제 카드는 bw11 안의 RC 번호), My First Battle(mfb, 덱 키트), 맥도날드 컬렉션·트레이너 키트·프로모.
- **서브세트 10종**은 자기 팩이 없고 본 세트 팩 안에서 나온다: 30th-c, cel25cc, exu(안농), sma(샤이니 볼트), swsh4.5sv(샤이니 볼트),
  swsh9tg·swsh10tg·swsh11tg·swsh12tg(트레이너 갤러리), swsh12.5gg(갈라르 갤러리). 카드는 원본 세트 ID를 지키고(바인더에서 본 세트 바로 뒤),
  레시피가 그 세트를 명시한 칸에서만 나온다.

### 추첨 (pool packs-v3)

- `selection: series-uniform`: 시리즈 16개(Base·Gym·Neo·Legendary Collection·e-Card·EX·POP·Diamond & Pearl·Platinum·HeartGold & SoulSilver·
  Black & White·XY·Sun & Moon·Sword & Shield·Scarlet & Violet·Mega Evolution) 중 하나를 **같은 확률(각 1/16)** 로 고른 뒤 그 시리즈 안의 팩을 가중치(모두 1)대로 고른다.
  시리즈는 TCGdex 구분을 따르되 Call of Legends는 Bulbapedia 분류대로 HeartGold & SoulSilver에 넣었다.
- 세트가 1개뿐인 시리즈(Legendary Collection)는 그 세트가 1/16, 세트가 많은 시리즈는 세트당 확률이 작다. 사용자 결정의 결과이며 오늘 화면에 시리즈별 확률이 그대로 보인다.
- 가격은 100 P 그대로. 이전 pool(packs-v1·v2)로 받은 팩은 기록된 상품·판본 그대로 열린다(재추첨 없음).

### 시대별 봉입 구성(요약)

| 시대 | 게임 카드 | 슬롯 | 주된 근거(2차) |
|---|---:|---|---|
| Base~Neo(WotC) | 11 | 커먼 7(세트 번호의 기본 에너지 포함) + 언커먼 3 + 레어 1(홀로·논홀로) | Wizards 공식 상품 페이지(보관본, 1차), Elite Fourum 인쇄 시트 분석 |
| Legendary Collection | 11 | 커먼 6 + 언커먼 3 + 레어 1 + 리버스 1 | Elite Fourum |
| e-Card | 9 | 커먼 4 + (커먼·홀로 1) + 언커먼 2 + 레어 1 + 리버스 1 | Elite Fourum |
| EX | 9 | 커먼 5 + 언커먼 2 + 레어 1 + 리버스 1 | 소매 상품 설명, Loose Packs, PokeBeach |
| POP | 2 | 커먼 1 + (커먼·언커먼·레어 1); POP 6은 레어 1 + 커먼·언커먼 1 | Bulbapedia, CardGuide (신뢰도 낮음) |
| DP·Pt·HGSS·CoL | 10 | 커먼 5 + 언커먼 3 + 레어 1 + 리버스 1 (HGSS 프라임은 리버스 칸) | Bulbapedia, PokeBeach, SixPrizes |
| BW·XY | 10 | 커먼 5 + 언커먼 3 + 리버스 1 + 레어 1; Legendary Treasures·Generations는 본 세트 8 + 레이디언트 컬렉션 2 | Bulbapedia, PokeBeach 개봉 기록, 공식 체크리스트 |
| SM | 10 | 커먼 5 + 언커먼 3 + 리버스 1 + 레어 1 | Bulbapedia, BleedingCool |
| SWSH | 10 | 커먼 5 + 언커먼 3 + 리버스 1(어메이징·레디언트·갤러리 포함) + 레어 1 | TCGplayer 대량 개봉 통계 |
| SV 특수·ME | 10 | SV01~SV10과 같은 4 + 3 + 리버스 2 + 레어 1 | TCGplayer, PokeBeach, 공식 페이지 |
| 특수 팩 | 4~7 | Celebrations 4, Detective Pikachu 4, 30th Celebration 5, Dragon Vault 5, Double Crisis 7 | 상품별 공식·2차 자료 |

모든 슬롯은 **슬롯 안 카드별 균등 추첨**이며 레시피 안내문에 "PackTrace 자체 시뮬레이션"이라고 적었다. 원본 분류로 표현할 수 없는 부분
(WotC 레어 칸의 홀로 약 1/3, SM 프리즘 스타·XY BREAK·BW ACE SPEC이 실물에서는 리버스 칸 등)은 세트별 안내문에 차이를 적었다.

### 원본 데이터 처리

- **인쇄 변형**: BW·XY·대부분의 SM 카드는 TCGdex 변형 값이 자동 생성값(`variantId: generated`, 전부 normal)이다. 이런 카드만 카드 응답의
  **TCGplayer 가격 키**(`normal`·`holofoil`·`reverse-holofoil`)로 인쇄를 정했다(가격은 인쇄가 있을 때만 붙는다). 가격 키도 없으면 조사 결과로 정했다
  (울트라·시크릿 레어와 BW EX는 포일, 샤이니 볼트·30주년·명탐정 피카츄·드래곤 볼트는 전부 포일). 카드마다 `printEvidence`에 근거가 남고 `verify`가 개수를 보여 준다.
- **EX Delta Species~Power Keepers**: 원본의 리버스 플래그가 비어 있고 리버스 홀로가 세트 로고 도장 인쇄로만 기록돼 있어 그 인쇄를 리버스로 읽었다(`reverseFromStamp`).
- **부스터 밖 카드·인쇄 제외**: 박스 토퍼(EX 10장), 테마덱 전용 인쇄(EX 홀로 15건, LC 논홀로 3건), 점보 전용 리버스(ecard2 H21), 다른 상품의 a/b 인쇄(XY 17장),
  테마덱 기본 에너지(ecard1 160~165, sm1 164~172), 점보 카드(sm4 63a), 2인 스타터 전용(base1 #8 Machamp), POP 팩에 없던 홀로·리버스, 트레이너 갤러리의 잘못된 리버스 표시.
  제외 목록은 원본에 실제로 있는 ID여야 하며 틀리면 카탈로그를 만들지 않는다.
- **카드 그림**: 원본이 그림 링크를 주지 않으면 같은 시리즈의 세트 폴더(점 없는 ID 포함, Shining Legends는 `sm35`)와, 번호가 겹치지 않을 때만 본 세트 폴더에서
  200 응답을 확인한 주소만 썼다. 그래도 없는 카드와 링크가 404인 카드는 이름·번호·등급이 적힌 자리 표시로 보이고 요청하지 않는다.

### 세트별 결과

`packtrace-catalog verify`: 138개 모두 해시 확인, **도달 불가 프린트 0 · 다른 세트 카드 0**. `packtrace-catalog pool`: packs-v3 후보 138종 해석 성공.
스냅샷은 모두 `tcgdex-en-<set>-20260924`. 인쇄 근거는 원본(TCGdex 변형 값) · 가격 키(TCGplayer) · 조사 · 도장(세트 로고 리버스).

| 시리즈 | 세트 | 이름 | 팩 장수 | 카드 | 모으는 프린트 | 같이 든 서브세트 | 인쇄 근거 | 그림 없음 | 해시 |
|---|---|---|---:|---:|---:|---|---|---:|---|
| base | base1 | Base Set | 11 | 101 | 101 | — | 원본 101 | 0 | `sha256:e4370b57…` |
| base | base2 | Jungle | 11 | 64 | 64 | — | 원본 64 | 0 | `sha256:e96f370a…` |
| base | base3 | Fossil | 11 | 62 | 62 | — | 원본 62 | 0 | `sha256:20a42582…` |
| base | base4 | Base Set 2 | 11 | 130 | 130 | — | 원본 130 | 0 | `sha256:f8248729…` |
| base | base5 | Team Rocket | 11 | 83 | 83 | — | 원본 83 | 0 | `sha256:cf7a2290…` |
| gym | gym1 | Gym Heroes | 11 | 132 | 132 | — | 원본 132 | 0 | `sha256:0205ac0f…` |
| gym | gym2 | Gym Challenge | 11 | 132 | 132 | — | 원본 132 | 0 | `sha256:1935eae8…` |
| neo | neo1 | Neo Genesis | 11 | 111 | 111 | — | 원본 111 | 0 | `sha256:8c03c857…` |
| neo | neo2 | Neo Discovery | 11 | 75 | 75 | — | 원본 75 | 0 | `sha256:d7654697…` |
| neo | neo3 | Neo Revelation | 11 | 66 | 66 | — | 원본 66 | 0 | `sha256:589f6e21…` |
| neo | neo4 | Neo Destiny | 11 | 113 | 113 | — | 원본 113 | 0 | `sha256:e1a7047e…` |
| lc | lc | Legendary Collection | 11 | 110 | 220 | — | 원본 110 | 0 | `sha256:25170564…` |
| ecard | ecard1 | Expedition Base Set | 9 | 159 | 318 | — | 원본 159 | 0 | `sha256:b3a52c1f…` |
| ecard | ecard2 | Aquapolis | 9 | 186 | 337 | — | 원본 186 | 40 | `sha256:a9ce0cb8…` |
| ecard | ecard3 | Skyridge | 9 | 182 | 332 | — | 원본 182 | 32 | `sha256:542901d9…` |
| ex | ex1 | Ruby & Sapphire | 9 | 109 | 210 | — | 원본 109 | 0 | `sha256:f03aaa96…` |
| ex | ex2 | Sandstorm | 9 | 100 | 193 | — | 원본 100 | 0 | `sha256:bef2cdc5…` |
| ex | ex3 | Dragon | 9 | 100 | 188 | — | 원본 100 | 0 | `sha256:ba366f73…` |
| ex | ex4 | Team Magma vs Team Aqua | 9 | 96 | 184 | — | 원본 96 | 0 | `sha256:2ca27470…` |
| ex | ex5 | Hidden Legends | 9 | 101 | 193 | — | 원본 101 | 0 | `sha256:f79ea2f2…` |
| ex | ex6 | FireRed & LeafGreen | 9 | 115 | 216 | — | 원본 115 | 0 | `sha256:a35b2a93…` |
| ex | ex7 | Team Rocket Returns | 9 | 110 | 205 | — | 원본 110 | 0 | `sha256:5543c769…` |
| ex | ex8 | Deoxys | 9 | 107 | 202 | — | 원본 107 | 0 | `sha256:c7ec5e22…` |
| ex | ex9 | Emerald | 9 | 106 | 195 | — | 원본 106 | 0 | `sha256:6b4682d5…` |
| ex | ex10 | Unseen Forces | 9 | 144 | 244 | exu | 원본 144 | 28 | `sha256:6d34fdf1…` |
| ex | ex11 | Delta Species | 9 | 113 | 220 | — | 도장 107 · 원본 6 | 0 | `sha256:b264a4da…` |
| ex | ex12 | Legend Maker | 9 | 92 | 174 | — | 도장 82 · 원본 10 | 0 | `sha256:cc5148ec…` |
| ex | ex13 | Holon Phantoms | 9 | 110 | 208 | — | 도장 98 · 원본 12 | 0 | `sha256:92bdf847…` |
| ex | ex14 | Crystal Guardians | 9 | 100 | 188 | — | 도장 88 · 원본 12 | 0 | `sha256:8f3e3c47…` |
| ex | ex15 | Dragon Frontiers | 9 | 101 | 190 | — | 도장 89 · 원본 12 | 0 | `sha256:f94ab99e…` |
| ex | ex16 | Power Keepers | 9 | 108 | 199 | — | 도장 91 · 원본 17 | 0 | `sha256:98011ace…` |
| pop | pop1 | POP Series 1 | 2 | 17 | 17 | — | 원본 17 | 0 | `sha256:0ca4eeba…` |
| pop | pop2 | POP Series 2 | 2 | 17 | 17 | — | 원본 17 | 0 | `sha256:b3f8d5ed…` |
| pop | pop3 | POP Series 3 | 2 | 17 | 17 | — | 원본 17 | 0 | `sha256:19aee41c…` |
| pop | pop4 | POP Series 4 | 2 | 17 | 17 | — | 원본 17 | 0 | `sha256:ff12ba8f…` |
| pop | pop5 | POP Series 5 | 2 | 17 | 17 | — | 원본 17 | 0 | `sha256:7baf1750…` |
| pop | pop6 | POP Series 6 | 2 | 17 | 17 | — | 원본 17 | 2 | `sha256:c6c98b91…` |
| pop | pop7 | POP Series 7 | 2 | 17 | 17 | — | 원본 17 | 0 | `sha256:d3c24c4b…` |
| pop | pop8 | POP Series 8 | 2 | 17 | 17 | — | 원본 17 | 0 | `sha256:b9185eae…` |
| pop | pop9 | POP Series 9 | 2 | 17 | 17 | — | 원본 17 | 0 | `sha256:371b227b…` |
| dp | dp1 | Diamond & Pearl | 10 | 130 | 249 | — | 원본 130 | 0 | `sha256:3e8bf235…` |
| dp | dp2 | Mysterious Treasures | 10 | 124 | 244 | — | 원본 124 | 0 | `sha256:302bede8…` |
| dp | dp3 | Secret Wonders | 10 | 132 | 262 | — | 원본 132 | 0 | `sha256:627fe9ba…` |
| dp | dp4 | Great Encounters | 10 | 106 | 208 | — | 원본 106 | 0 | `sha256:1c5669ff…` |
| dp | dp5 | Majestic Dawn | 10 | 100 | 196 | — | 원본 100 | 0 | `sha256:ee921fbc…` |
| dp | dp6 | Legends Awakened | 10 | 146 | 285 | — | 원본 146 | 0 | `sha256:e2f875eb…` |
| dp | dp7 | Stormfront | 10 | 106 | 201 | — | 원본 106 | 0 | `sha256:26a517af…` |
| pl | pl1 | Platinum | 10 | 133 | 254 | — | 원본 133 | 0 | `sha256:0beae8e8…` |
| pl | pl2 | Rising Rivals | 10 | 120 | 222 | — | 원본 120 | 1 | `sha256:29afa7e5…` |
| pl | pl3 | Supreme Victors | 10 | 153 | 293 | — | 원본 153 | 0 | `sha256:b5d66bd7…` |
| pl | pl4 | Arceus | 10 | 111 | 204 | — | 원본 111 | 0 | `sha256:b0266459…` |
| hgss | hgss1 | HeartGold SoulSilver | 10 | 124 | 229 | — | 원본 124 | 0 | `sha256:97989eb3…` |
| hgss | hgss2 | Unleashed | 10 | 96 | 178 | — | 원본 96 | 0 | `sha256:8d38256e…` |
| hgss | hgss3 | Undaunted | 10 | 91 | 170 | — | 원본 91 | 0 | `sha256:87a61269…` |
| hgss | hgss4 | Triumphant | 10 | 103 | 193 | — | 원본 103 | 0 | `sha256:174be066…` |
| hgss | col1 | Call of Legends | 10 | 106 | 193 | — | 원본 106 | 0 | `sha256:bf88568b…` |
| bw | bw1 | Black & White | 10 | 115 | 216 | — | 가격 키 112 · 원본 3 | 0 | `sha256:072a7356…` |
| bw | bw2 | Emerging Powers | 10 | 98 | 193 | — | 가격 키 97 · 원본 1 | 0 | `sha256:07151c75…` |
| bw | bw3 | Noble Victories | 10 | 102 | 198 | — | 가격 키 100 · 원본 2 | 0 | `sha256:30d32c6c…` |
| bw | bw4 | Next Destinies | 10 | 103 | 189 | — | 가격 키 90 · 원본 1 · 조사 12 | 0 | `sha256:238bc075…` |
| bw | bw5 | Dark Explorers | 10 | 111 | 207 | — | 가격 키 96 · 원본 15 | 0 | `sha256:61dfa4fd…` |
| bw | bw6 | Dragons Exalted | 10 | 128 | 238 | — | 가격 키 114 · 원본 2 · 조사 12 | 0 | `sha256:a4b9df6a…` |
| bw | dv1 | Dragon Vault | 5 | 21 | 21 | — | 가격 키 21 | 0 | `sha256:81521e12…` |
| bw | bw7 | Boundaries Crossed | 10 | 153 | 281 | — | 가격 키 139 · 원본 2 · 조사 12 | 0 | `sha256:989fd1d0…` |
| bw | bw8 | Plasma Storm | 10 | 138 | 257 | — | 가격 키 126 · 조사 12 | 0 | `sha256:f1553bf7…` |
| bw | bw9 | Plasma Freeze | 10 | 122 | 220 | — | 가격 키 108 · 원본 2 · 조사 12 | 0 | `sha256:e298a326…` |
| bw | bw10 | Plasma Blast | 10 | 105 | 189 | — | 가격 키 90 · 원본 4 · 조사 11 | 0 | `sha256:a6d43670…` |
| bw | bw11 | Legendary Treasures | 10 | 140 | 241 | — | 가격 키 103 · 원본 10 · 조사 27 | 0 | `sha256:a99ab1ad…` |
| xy | xy1 | XY | 10 | 146 | 269 | — | 가격 키 146 | 0 | `sha256:559bb2e7…` |
| xy | xy2 | Flashfire | 10 | 109 | 196 | — | 가격 키 103 · 원본 4 · 조사 2 | 0 | `sha256:ed766d38…` |
| xy | xy3 | Furious Fists | 10 | 113 | 210 | — | 가격 키 113 | 0 | `sha256:b0d1a967…` |
| xy | xy4 | Phantom Forces | 10 | 122 | 221 | — | 가격 키 117 · 원본 5 | 0 | `sha256:9eb0b174…` |
| xy | xy5 | Primal Clash | 10 | 164 | 295 | — | 가격 키 163 · 원본 1 | 0 | `sha256:df6564d6…` |
| xy | dc1 | Double Crisis | 7 | 34 | 66 | — | 가격 키 34 | 1 | `sha256:cf1d04c2…` |
| xy | xy6 | Roaring Skies | 10 | 110 | 196 | — | 가격 키 110 | 0 | `sha256:3a13d02e…` |
| xy | xy7 | Ancient Origins | 10 | 100 | 172 | — | 가격 키 100 | 0 | `sha256:a74bac0b…` |
| xy | xy8 | BREAKthrough | 10 | 164 | 301 | — | 가격 키 163 · 원본 1 | 0 | `sha256:209f4cc1…` |
| xy | xy9 | BREAKpoint | 10 | 123 | 219 | — | 가격 키 122 · 원본 1 | 0 | `sha256:f681f433…` |
| xy | g1 | Generations | 10 | 115 | 181 | — | 가격 키 80 · 원본 13 · 조사 22 | 0 | `sha256:6122e9e1…` |
| xy | xy10 | Fates Collide | 10 | 125 | 221 | — | 가격 키 124 · 원본 1 | 0 | `sha256:319e1647…` |
| xy | xy11 | Steam Siege | 10 | 116 | 206 | — | 가격 키 112 · 원본 3 · 조사 1 | 0 | `sha256:5ea11385…` |
| xy | xy12 | Evolutions | 10 | 113 | 194 | — | 가격 키 110 · 원본 2 · 조사 1 | 0 | `sha256:907347bb…` |
| sm | sm1 | Sun & Moon | 10 | 163 | 287 | — | 가격 키 161 · 원본 2 | 0 | `sha256:cdc47d4f…` |
| sm | sm2 | Guardians Rising | 10 | 169 | 287 | — | 가격 키 169 | 1 | `sha256:d7fd8335…` |
| sm | sm3 | Burning Shadows | 10 | 169 | 285 | — | 원본 169 | 0 | `sha256:29615839…` |
| sm | sm3.5 | Shining Legends | 10 | 78 | 136 | — | 가격 키 75 · 원본 2 · 조사 1 | 2 | `sha256:051de5a2…` |
| sm | sm4 | Crimson Invasion | 10 | 124 | 216 | — | 가격 키 124 | 0 | `sha256:2ee7322b…` |
| sm | sm5 | Ultra Prism | 10 | 173 | 295 | — | 가격 키 161 · 원본 9 · 조사 3 | 0 | `sha256:8d6e8252…` |
| sm | sm6 | Forbidden Light | 10 | 146 | 248 | — | 가격 키 136 · 원본 9 · 조사 1 | 6 | `sha256:8a656995…` |
| sm | sm7 | Celestial Storm | 10 | 183 | 317 | — | 가격 키 174 · 원본 6 · 조사 3 | 0 | `sha256:34cba261…` |
| sm | sm7.5 | Dragon Majesty | 10 | 78 | 133 | — | 가격 키 74 · 원본 3 · 조사 1 | 0 | `sha256:d1ee5e4e…` |
| sm | sm8 | Lost Thunder | 10 | 236 | 405 | — | 가격 키 223 · 원본 12 · 조사 1 | 0 | `sha256:c343e4cd…` |
| sm | sm9 | Team Up | 10 | 196 | 331 | — | 가격 키 179 · 원본 13 · 조사 4 | 0 | `sha256:20f4a1f6…` |
| sm | det1 | Detective Pikachu | 4 | 18 | 18 | — | 가격 키 18 | 0 | `sha256:e029d79e…` |
| sm | sm10 | Unbroken Bonds | 10 | 234 | 403 | — | 가격 키 222 · 원본 8 · 조사 4 | 0 | `sha256:b2b8c2b3…` |
| sm | sm11 | Unified Minds | 10 | 258 | 450 | — | 가격 키 249 · 원본 6 · 조사 3 | 0 | `sha256:badc38ba…` |
| sm | sm115 | Hidden Fates | 10 | 163 | 204 | sma | 가격 키 53 · 원본 15 · 조사 95 | 0 | `sha256:d4ffedb7…` |
| sm | sm12 | Cosmic Eclipse | 10 | 271 | 457 | — | 가격 키 259 · 원본 7 · 조사 5 | 0 | `sha256:099b6c7e…` |
| swsh | swsh1 | Sword & Shield | 10 | 216 | 381 | — | 가격 키 209 · 원본 7 | 0 | `sha256:619fe8b4…` |
| swsh | swsh2 | Rebel Clash | 10 | 209 | 360 | — | 원본 209 | 0 | `sha256:b3fe25fb…` |
| swsh | swsh3 | Darkness Ablaze | 10 | 201 | 356 | — | 원본 201 | 0 | `sha256:7f3f2aac…` |
| swsh | swsh3.5 | Champion's Path | 10 | 80 | 134 | — | 가격 키 77 · 원본 3 | 0 | `sha256:1dae16c5…` |
| swsh | swsh4 | Vivid Voltage | 10 | 203 | 345 | — | 원본 203 | 0 | `sha256:417f26db…` |
| swsh | swsh4.5 | Shining Fates | 10 | 195 | 241 | swsh4.5sv | 원본 195 | 0 | `sha256:642b39da…` |
| swsh | swsh5 | Battle Styles | 10 | 183 | 306 | — | 원본 183 | 0 | `sha256:36cec334…` |
| swsh | swsh6 | Chilling Reign | 10 | 233 | 369 | — | 원본 233 | 0 | `sha256:274abdba…` |
| swsh | swsh7 | Evolving Skies | 10 | 237 | 369 | — | 원본 237 | 0 | `sha256:90f936e2…` |
| swsh | cel25 | Celebrations | 4 | 50 | 50 | cel25cc | 원본 50 | 26 | `sha256:3edb1df0…` |
| swsh | swsh8 | Fusion Strike | 10 | 284 | 501 | — | 원본 284 | 0 | `sha256:13560c59…` |
| swsh | swsh9 | Brilliant Stars | 10 | 216 | 340 | swsh9tg | 원본 216 | 0 | `sha256:d234a34e…` |
| swsh | swsh10 | Astral Radiance | 10 | 246 | 374 | swsh10tg | 원본 246 | 0 | `sha256:8188bcba…` |
| swsh | swsh10.5 | Pokémon GO | 10 | 88 | 145 | — | 원본 88 | 0 | `sha256:beb2d2de…` |
| swsh | swsh11 | Lost Origin | 10 | 247 | 396 | swsh11tg | 원본 247 | 0 | `sha256:20cd3153…` |
| swsh | swsh12 | Silver Tempest | 10 | 245 | 387 | swsh12tg | 원본 245 | 0 | `sha256:e069a3ed…` |
| swsh | swsh12.5 | Crown Zenith | 10 | 230 | 342 | swsh12.5gg | 원본 230 | 0 | `sha256:ff3d5266…` |
| sv | sv03.5 | 151 | 10 | 207 | 360 | — | 원본 207 | 0 | `sha256:a07c6199…` |
| sv | sv04.5 | Paldean Fates | 10 | 245 | 326 | — | 원본 245 | 0 | `sha256:e69d91e3…` |
| sv | sv06.5 | Shrouded Fable | 10 | 99 | 154 | — | 원본 99 | 0 | `sha256:6537dea7…` |
| sv | sv08.5 | Prismatic Evolutions | 10 | 180 | 280 | — | 원본 180 | 0 | `sha256:0577c61e…` |
| sv | sv10.5b | Black Bolt | 10 | 172 | 252 | — | 원본 172 | 0 | `sha256:627d1c96…` |
| sv | sv10.5w | White Flare | 10 | 173 | 253 | — | 원본 173 | 0 | `sha256:83ff563d…` |
| me | me01 | Mega Evolution | 10 | 188 | 310 | — | 원본 188 | 0 | `sha256:7297bb0f…` |
| me | me02 | Phantasmal Flames | 10 | 130 | 214 | — | 원본 130 | 0 | `sha256:519e0d1a…` |
| me | me02.5 | Ascended Heroes | 10 | 295 | 473 | — | 원본 295 | 0 | `sha256:60cdad29…` |
| me | me03 | Perfect Order | 10 | 124 | 203 | — | 원본 124 | 0 | `sha256:ac2a6bf8…` |
| me | me04 | Chaos Rising | 10 | 122 | 198 | — | 원본 122 | 0 | `sha256:568cf9d1…` |
| me | me05 | Pitch Black | 10 | 120 | 194 | — | 원본 120 | 0 | `sha256:1c0c0b61…` |
| me | 30th | 30th Celebration | 5 | 188 | 188 | 30th-c | 조사 188 | 30 | `sha256:909f3612…` |

합계: 세트 128 · 카드 16,707 · 모으는 프린트 27,889 · 그림 없는 카드 169


### 확인하지 못한 항목

- 대부분 1차 자료가 없고 2차·커뮤니티 자료다. 새 상품 128종은 모두 `metadata-verified`다.
- 슬롯 위치가 자료마다 다르거나 추정인 것: LV.X·LEGEND(레어 칸 vs 리버스 칸), 초기 EX의 "홀로가 다섯 번째 커먼 자리를 대신함", 안농(UF), 메가 하이퍼 레어·블랙 화이트 레어,
  명탐정 피카츄·셀러브레이션·30주년의 칸 나눔, Legendary Treasures·Generations의 커먼/언커먼 3+3, Double Crisis의 커먼/언커먼.
- 원본 등급 오류는 고치지 않고 그대로 두었다(dp4 58·59 커먼 표기, SM·SWSH 일부 등급 오표기).
- 1판(1st Edition)·그림자 없는 판·특수 무늬 리버스(볼·에너지 무늬)는 구분하지 않는다.
- 포장 그림: 공개판에는 등록된 그림이 없어 모든 팩이 세트 로고로 만든 대체 포장이다.

## 8. 독립 확인

구현과 별개로 두 개의 읽기 전용 검증 작업을 돌려 같은 값을 두 방법으로 확인했다(2026-09-22).

- 실시간 API 258장 개별 조회 집계와 API 필터·페이지 경계 조회가 **동일한 등급/변형 표**를 냈다.
- 카드 이미지 258개 URL 전부 200, 999번 같은 없는 번호는 404(대조군).
- 팩 구성은 1차 자료(Pokemon Center Support)와 2차·커뮤니티 자료를 구분해 기록했다.
