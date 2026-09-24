#!/usr/bin/env bash
# Install the real pack artwork this app is registered to use.
#
# Explicit preparation step, not part of a build: it downloads the three
# registered images from the sources recorded in the registry, checks the bytes
# (format, decode, hash, pixel limits), resamples them and writes them into the
# local asset directory. The app only ever reads that directory, so a build or a
# launch never needs the network.
#
# Usage:
#   ./scripts/fetch-pack-artwork.sh                 # install / refresh
#   ./scripts/fetch-pack-artwork.sh --write-manifest # also refresh normalised hashes
#   ./scripts/fetch-pack-artwork.sh verify          # check installed files, no network
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="fetch"
if [ "${1:-}" = "verify" ] || [ "${1:-}" = "list" ]; then
  MODE="$1"
  shift
fi

swift run packtrace-catalog artwork "${MODE}" "$@"
