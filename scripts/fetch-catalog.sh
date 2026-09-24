#!/usr/bin/env bash
# Fetch catalogue snapshots from live TCGdex data.
# Reviewed product and recipe facts live in catalog-sources/<set>.json; this
# script merges them with freshly fetched card data and writes a *new* dated
# snapshot per set. Sealed packs are pinned to the snapshot version they were
# exchanged under, so an existing version is never replaced: the tool refuses
# (pass --version for a new name, or --force only for a snapshot no pack uses).
set -euo pipefail

cd "$(dirname "$0")/.."

CATALOG_DIR="Sources/PackTraceCore/Resources/catalog"

# Every set, or only the ones named: ./scripts/fetch-catalog.sh [set-id ...]
# (extra fetch flags such as --version go through FETCH_FLAGS).
if [ "$#" -gt 0 ]; then
  SOURCES=()
  for ID in "$@"; do SOURCES+=("catalog-sources/${ID}.json"); done
else
  SOURCES=()
  for SOURCE in catalog-sources/*.json; do
    case "$(basename "${SOURCE}")" in pool-*) continue;; esac
    SOURCES+=("${SOURCE}")
  done
fi
for SOURCE in "${SOURCES[@]}"; do
  echo "== fetch ${SOURCE} =="
  # shellcheck disable=SC2086
  swift run packtrace-catalog fetch --products "${SOURCE}" ${FETCH_FLAGS:-}
done

echo
echo "== verify every snapshot (local, no network) =="
for SNAPSHOT in "${CATALOG_DIR}"/*.json; do
  echo "-- ${SNAPSHOT}"
  swift run packtrace-catalog verify --catalog "${SNAPSHOT}"
  echo "   file hash: $(shasum -a 256 "${SNAPSHOT}" | cut -d' ' -f1)"
done

echo
echo "== resolve the exchange pool against the snapshots =="
swift run packtrace-catalog pool --catalogs "${CATALOG_DIR}"

echo
echo "== describe the installed snapshots (catalog-manifest.json) =="
/usr/bin/python3 scripts/catalogs.py manifest
