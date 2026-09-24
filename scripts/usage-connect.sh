#!/usr/bin/env bash
# Connect an AI tool's usage storage to the real wallet (production profile).
#
# The same action the settings panel offers. The connection moment becomes that
# tool's baseline, so nothing already in the storage is credited; only usage that
# happens after this runs earns points. Safe to run at any time, and reversible
# with `disconnect`.
#
# Usage:
#   ./scripts/usage-connect.sh codex|claude-code|opencode
#   ./scripts/usage-connect.sh --status
#   ./scripts/usage-connect.sh --disconnect codex
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${1:-}" = "--status" ]; then
  exec swift run -c release packtrace-catalog usage status
fi
if [ "${1:-}" = "--disconnect" ]; then
  exec swift run -c release packtrace-catalog usage disconnect --tool "${2:?tool name required}"
fi
if [ -z "${1:-}" ]; then
  echo "usage: $0 codex|claude-code|opencode | --status | --disconnect <tool>" >&2
  exit 2
fi
exec swift run -c release packtrace-catalog usage connect --tool "$1"
