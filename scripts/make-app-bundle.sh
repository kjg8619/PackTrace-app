#!/usr/bin/env bash
# Assemble dist/PackTrace.app from the SwiftPM build products.
#
# SwiftPM has no bundle step, so the .app directory, Info.plist and resource
# bundles are laid out here. The result is a normal menu bar app that can be
# opened with `open` or the run script.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_NAME="PackTrace"
DIST="dist"
APP="${DIST}/${APP_NAME}.app"

echo "== swift build -c ${CONFIGURATION} =="
swift build -c "${CONFIGURATION}"

BIN_DIR="$(swift build -c "${CONFIGURATION}" --show-bin-path)"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp packaging/Info.plist "${APP}/Contents/Info.plist"

# SwiftPM emits one resource bundle per target that declares resources.
shopt -s nullglob
for bundle in "${BIN_DIR}"/*.bundle; do
  cp -R "${bundle}" "${APP}/Contents/Resources/"
done
shopt -u nullglob

echo "== ad-hoc code signature =="
codesign --force --sign - --timestamp=none "${APP}" 2>&1 | sed 's/^/  /'

echo
echo "app: $(pwd)/${APP}"
echo "binary: $(pwd)/${APP}/Contents/MacOS/${APP_NAME}"
