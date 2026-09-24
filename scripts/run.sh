#!/usr/bin/env bash
# Build the bundle and launch it. Pass --wait to keep the script alive while the
# app runs, which is handy when watching the menu bar by hand.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/make-app-bundle.sh "${CONFIGURATION:-release}"

APP="$(pwd)/dist/PackTrace.app"
echo "== open ${APP} =="
if [ -n "${PACKTRACE_DATA_ROOT:-}" ]; then
  # Verification runs use a throwaway data root instead of the real collection.
  echo "   PACKTRACE_DATA_ROOT=${PACKTRACE_DATA_ROOT}"
  PACKTRACE_DATA_ROOT="${PACKTRACE_DATA_ROOT}" open -n "${APP}"
else
  open "${APP}"
fi

sleep 2
if pgrep -fl "PackTrace.app/Contents/MacOS/PackTrace" >/dev/null; then
  echo "PASS: PackTrace is running"
  pgrep -fl "PackTrace.app/Contents/MacOS/PackTrace"
else
  echo "FAIL: PackTrace is not running"
  exit 1
fi
