#!/usr/bin/env bash
# Bundle the installed catalogues (checked against catalog-manifest.json) into
# a .tar.gz that ./scripts/prepare-catalogs.sh can install. Default output:
# .build/packtrace-catalogs-<pool>.tar.gz
set -euo pipefail
cd "$(dirname "$0")/.."
exec /usr/bin/python3 scripts/catalogs.py pack "$@"
