#!/usr/bin/env bash
# Install the card catalogues a checkout needs before building or testing.
#
# The catalogues are generated from TCGdex data and are not tracked in Git;
# catalog-manifest.json names each one with its hash. Install them from a
# published bundle, or rebuild them from TCGdex (slow, and the source data may
# have moved on since the bundle was made).
#
# Usage:
#   ./scripts/prepare-catalogs.sh <bundle.tar.gz | https://…/bundle.tar.gz>
#   PACKTRACE_CATALOG_BUNDLE=<path or URL> ./scripts/prepare-catalogs.sh
#   ./scripts/prepare-catalogs.sh --rebuild [set-id ...]
set -euo pipefail

cd "$(dirname "$0")/.."

if /usr/bin/python3 scripts/catalogs.py verify >/dev/null 2>&1; then
  echo "catalogues already installed and matching catalog-manifest.json"
  exit 0
fi

if [ "${1:-}" = "--rebuild" ]; then
  shift
  exec /usr/bin/python3 scripts/catalogs.py rebuild "$@"
fi

SOURCE="${1:-${PACKTRACE_CATALOG_BUNDLE:-}}"
if [ -z "${SOURCE}" ]; then
  echo "catalogues are not installed."
  echo "usage: ./scripts/prepare-catalogs.sh <bundle.tar.gz | https URL>   (see README: Card catalogues)"
  echo "   or: ./scripts/prepare-catalogs.sh --rebuild                     (from TCGdex, slow)"
  exit 2
fi
exec /usr/bin/python3 scripts/catalogs.py install "${SOURCE}"
