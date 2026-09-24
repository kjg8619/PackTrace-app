#!/usr/bin/env bash
# Build PackTrace with the toolchain that is actually installed.
#
# This machine has Command Line Tools only (no Xcode), so SwiftPM is the build
# system: xcodebuild has no Xcode to drive. See docs/TOOLCHAIN.md.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-debug}"
echo "== swift build -c ${CONFIGURATION} =="
swift build -c "${CONFIGURATION}"

echo
echo "== xcodebuild availability =="
if xcode-select -p | grep -q "Xcode.app"; then
  echo "Xcode is selected; xcodebuild could be used for an .xcodeproj build."
else
  echo "NOT_RUN: xcodebuild requires Xcode, active developer dir is $(xcode-select -p)."
fi
