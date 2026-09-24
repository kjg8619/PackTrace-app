#!/usr/bin/env bash
# Full verification gate: tests, release build, catalogue integrity, a sample
# pack draw, the generated opening sounds, and app bundle assembly. Every step
# prints the real command it ran.
set -euo pipefail

cd "$(dirname "$0")/.."

STATUS=0
run() {
  echo
  echo "### $*"
  if "$@"; then
    echo "-> PASS: $*"
  else
    echo "-> FAIL: $*"
    STATUS=1
  fi
}

run ./scripts/test.sh
run swift build -c release
run swift run -c release packtrace-catalog verify \
  --catalog Sources/PackTraceCore/Resources/catalog/tcgdex-en-sv01-20260922.json
run swift run -c release packtrace-catalog draw \
  --catalog Sources/PackTraceCore/Resources/catalog/tcgdex-en-sv01-20260922.json --seed 7
run swift run -c release packtrace-catalog pool \
  --catalogs Sources/PackTraceCore/Resources/catalog
# The opening sounds are generated, not downloaded: the committed files must be
# exactly what the generator produces.
run /usr/bin/python3 scripts/generate-opening-sounds.py --check
run ./scripts/make-app-bundle.sh release

echo
if [ "${STATUS}" -eq 0 ]; then
  echo "VERIFY: PASS (all steps above exited 0)"
else
  echo "VERIFY: FAIL (see the step marked FAIL)"
fi
exit "${STATUS}"
