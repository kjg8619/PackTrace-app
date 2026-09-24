# Contributing

Thanks for looking at PackTrace. It is a small, personal-scale app; pull
requests that keep it that way are the easiest to accept.

## Before you start

1. Install the card catalogues (`./scripts/prepare-catalogs.sh`, see README).
2. Run `./scripts/test.sh`. Everything should pass before you change anything.
3. For a change the app shows, also run `./scripts/verify.sh`.

## Ground rules

These come from how the app is meant to behave, and reviews check them:

- **A drawn pack is never drawn again.** Results are stored before any
  animation; retries, restarts and double clicks return the stored result.
- **Points and usage are separate ledgers.** Crediting usage, exchanging and
  opening are idempotent and transactional.
- **Say when something is a simulation.** If the real pull rates or slot
  layout are not known, the recipe says so. A card that was never in a
  booster is not put in one; `catalog-sources/` records the evidence.
- **Usage data stays private.** Adapters read the tools' records only; they
  never store prompts, responses, tool arguments, paths or credentials.
  Parsers are written against the real record format, documented in
  `docs/USAGE_SOURCES.md`.
- **Tests never touch real data.** Use the synthetic fixtures and temporary
  stores; opt-in probes that read a real profile stay opt-in.
- **No publisher images in the repository** (cards, pack art, logos), and no
  catalogue snapshots — see NOTICE.md.

## Pull requests

- One topic per pull request, with tests for the behaviour it changes.
- Don't weaken an assertion or delete a test to make it pass; explain a
  changed expectation in the PR.
- Describe what you ran (`./scripts/test.sh`, `./scripts/verify.sh`) and
  what you could not verify (for example, how it looks in the real window).

## Adding a set

1. Write `catalog-sources/<set-id>.json`: slots, exclusions, evidence and
   what is unverified.
2. `swift run packtrace-catalog fetch --products catalog-sources/<set-id>.json`
3. `swift run packtrace-catalog verify --catalog <snapshot>` must report
   0 unreachable prints and 0 foreign-set cards.
4. Add the product to a new pool version (`Resources/pool/`), never by editing
   an existing one, and refresh `catalog-manifest.json`
   (`python3 scripts/catalogs.py manifest`).
