#!/usr/bin/env bash
# Check what the usage adapters make of the tools installed on this machine.
#
# Read-only: it inspects each tool's storage and parses a bounded slice of it
# into a throwaway database. It never appends to, rewrites or configures another
# tool's storage, and it never touches the real wallet.
#
# Usage:
#   ./scripts/usage-check.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== installed tools =="
for tool in omp codex claude opencode; do
  printf '  %-9s ' "$tool"
  if command -v "$tool" >/dev/null 2>&1; then
    "$tool" --version 2>&1 | head -1
  else
    echo "not found"
  fi
done

echo
echo "== adapters against the real storages (read-only, bounded) =="
PLUGIN_DIR="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
ARGS=()
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -d "${PLUGIN_DIR}" ]; then
  ARGS+=(-Xswiftc -plugin-path -Xswiftc "${PLUGIN_DIR}")
fi
PACKTRACE_REAL_USAGE_PROBE=1 swift test ${ARGS[@]+"${ARGS[@]}"} --filter RealUsageCorpusProbeTests 2>&1 \
  | grep -E '^\[|^   |^== |SKIPPED|error:' || true

cat <<'TEXT'

읽는 법:
  support=supported  어댑터가 그 저장 형식을 인식했다
  files/records      이번 예산 안에서 읽은 파일·레코드 수
  parsedEvents       실제로 파싱된 확정 usage 호출 수
  tokensIfNew        그 호출들이 '신규'였다면 인정될 토큰(여기서는 전부 과거 기록이므로 지급되지 않음)
  excluded           인식했지만 정책상 제외한 기록 수

이 명령은 아무것도 적립하지 않습니다. 실제 적립은 앱에서 도구를 연결한 뒤
그 시점 이후에 발생한 사용량부터 이뤄집니다.
TEXT
