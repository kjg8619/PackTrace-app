#!/usr/bin/env bash
# Run the whole test suite.
#
# With the Command Line Tools as the active developer directory, Swift
# Testing's macros live under usr/lib/swift/host/plugins/testing, which SwiftPM
# does not add to the plugin search path on its own. Pass it explicitly then.
# With Xcode active (CI runners), Xcode's own toolchain finds them; a plugin
# from a different Command Line Tools version must not be mixed in.
set -euo pipefail

cd "$(dirname "$0")/.."

PLUGIN_DIR="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
ARGS=()
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -d "${PLUGIN_DIR}" ]; then
  echo "== using Swift Testing plugin path: ${PLUGIN_DIR} =="
  ARGS+=(-Xswiftc -plugin-path -Xswiftc "${PLUGIN_DIR}")
fi

echo "== swift test =="
# ${ARGS[@]+...}: an empty array is "unbound" under set -u in macOS's bash 3.2.
swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
