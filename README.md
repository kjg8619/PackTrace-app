# PackTrace

A small macOS menu bar app that turns the AI coding work you already do into
free points, and the points into booster packs you open by hand and file in a
binder.

> **Unofficial fan project.** Not affiliated with Nintendo, Creatures,
> GAME FREAK or The Pokémon Company. No publisher images are included; pack
> contents are PackTrace's own simulation, not official pull rates. See
> [NOTICE.md](NOTICE.md).

한국어 요약은 [아래](#한국어)에 있습니다.

## What it does

- **Points from AI usage.** Reads the usage records your AI tools already keep
  on this Mac (OMP, Codex, Claude Code, OpenCode, pi, omo, senpi, Hermes, Grok,
  Kimi) and credits confirmed, uncached input + output tokens
  (10,000 tokens = 1 point). Cache reads and writes are shown but not credited.
  Only usage after you connect a tool counts.
- **Random packs, opened by hand.** 100 points buys a random pack: a series is
  picked first (all equally likely), then a set inside it. 138 English booster
  products from 1999 Base Set to 2026, each with its own pack size and slot
  layout. The result is saved before the opening animation, so quitting or
  double-clicking never re-draws a pack.
- **Binder and records.** Every print you own, per set and across sets (search
  by name, set or number), with duplicates counted as stars, achievements and
  a history of every opening.

Everything stays on your Mac: a local SQLite database, read-only access to the
AI tools' records, no account, no telemetry.

## Requirements

- macOS 14 or later
- A Swift 6 toolchain. Tested with Swift 6.4 (Command Line Tools) on macOS 27;
  Xcode is not required. Older Swift 6 toolchains are untested. Why the code
  avoids `@State`/`@Observable`: [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md).

## Getting started

```sh
git clone https://github.com/kjg8619/PackTrace-app.git PackTrace && cd PackTrace
./scripts/prepare-catalogs.sh https://github.com/kjg8619/PackTrace-app/releases/download/v0.1.0/packtrace-catalogs-pool-v3.tar.gz
./scripts/test.sh                                   # the whole test suite
./scripts/run.sh                                    # build dist/PackTrace.app and open it
```

The app starts with a development wallet holding 500 demo points, so you can
open packs before connecting any AI tool. Real usage goes to a separate
production wallet (Settings > 지갑·백업).

### Card catalogues

The card lists the app is built with are generated from
[TCGdex](https://tcgdex.dev) data and are **not tracked in Git**.
`catalog-manifest.json` names every snapshot with its hash. Install them one of
two ways:

- **From a bundle** (fast): the bundle attached to the
  [release](https://github.com/kjg8619/PackTrace-app/releases) whose name
  matches `pool` in `catalog-manifest.json` (now
  `packtrace-catalogs-pool-v3.tar.gz`). Pass its https URL or a downloaded file
  to `./scripts/prepare-catalogs.sh`. Every file is checked against the
  manifest; nothing is installed if one differs.
- **From TCGdex** (slow, network): `./scripts/prepare-catalogs.sh --rebuild`
  fetches every set again with the pinned versions. TCGdex data may have moved
  on since the manifest; the app works either way, some tests pinned to the
  published snapshots may not.

A build without catalogues opens with instructions instead of a collection.

### Pack artwork (optional)

Packs are drawn with a stand-in wrapper made from the set logo. The registry in
`Sources/PackTraceCore/Resources/pack-artwork/` is empty here: publisher
artwork is not redistributed. You can register pictures you are entitled to use
yourself; the format and the install/verify tool are described in
[docs/PACK_ARTWORK.md](docs/PACK_ARTWORK.md). Installed images stay in
`~/Library/Application Support/PackTrace/pack-artwork` and are git-ignored.

### Connecting AI tools

Settings > AI 사용량 lists every supported tool with the folder it reads.
Connecting marks everything already there as a baseline; only usage after that
moment earns points. What each tool's records contain and how they are read is
documented in [docs/USAGE_SOURCES.md](docs/USAGE_SOURCES.md).

PackTrace stores session and response identifiers, model and provider names,
stop reasons, times and token counts. It never stores prompts, responses,
thinking, tool arguments or results, working directories or credentials, and
it only ever reads the tools' files.

## Development

```sh
./scripts/test.sh      # Swift Testing suites (Core + UI), no network
./scripts/verify.sh    # tests, release build, catalogue/pool checks, app bundle
```

- `Sources/PackTraceCore` — catalogues, recipes, pool, SQLite store, usage adapters
- `Sources/PackTraceUI` — SwiftUI app (menu bar, main window, opening scene)
- `Sources/PackTraceCatalogTool` — `packtrace-catalog`: fetch/verify catalogues, pool, artwork, usage
- `catalog-sources/` — per-set recipes with the evidence behind each slot
- `scripts/` — build, test, catalogue and artwork preparation

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and
[SECURITY.md](SECURITY.md) for reporting a vulnerability.

## License

Source code and documents: [MIT](LICENSE). Card data: TCGdex (MIT) — see
[NOTICE.md](NOTICE.md), which also explains what the license does not cover.

---

## 한국어

AI 코딩 작업량을 무료 포인트로 바꾸고, 포인트로 받은 카드 팩을 직접 뜯어 바인더에 모으는 macOS 메뉴바 앱입니다.
**비공식 팬 프로젝트**이며 Nintendo·Creatures·GAME FREAK·The Pokémon Company와 관계가 없습니다. 출판사 이미지를 담지 않고,
팩 내용은 PackTrace 자체 시뮬레이션입니다([NOTICE.md](NOTICE.md)).

- **적립**: OMP·Codex·Claude Code·OpenCode·pi·omo·senpi·Hermes·Grok·Kimi의 로컬 기록을 읽기만 하고, 확정된 비캐시 입력 + 출력만
  인정합니다(10,000 토큰 = 1 P). 연결한 뒤의 사용량부터 적립합니다.
- **팩**: 100 P로 무작위 팩 한 개. 시리즈를 같은 확률로 고른 뒤 그 안의 세트를 고릅니다. 1999 Base Set부터 2026년까지 영문판 138종.
  결과는 연출 전에 저장되어 다시 뽑지 않습니다.
- **바인더**: 세트별·전체 검색, 중복은 별, 업적, 개봉 기록.

시작하기: `./scripts/prepare-catalogs.sh <릴리스의 카탈로그 묶음 주소>` → `./scripts/test.sh` → `./scripts/run.sh` (명령은 위 "Getting started").
카드 카탈로그는 Git에 없고 릴리스에 첨부한 묶음이나 TCGdex(`--rebuild`)로 설치합니다. 포장 그림은 선택 사항이며 기본은 세트 로고로 만든 대체 포장입니다.
프롬프트·응답 본문, 인증정보 등은 저장하지 않고, 모든 데이터는 이 Mac 안에만 있습니다.
