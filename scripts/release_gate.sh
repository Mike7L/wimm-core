#!/usr/bin/env bash
# Full pre-release check: every test, the release build (SWIFTDATA_ENABLED),
# the iOS Release build and the web tests. Nothing is signed or installed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/build_budget.sh"

echo "[release-gate] 1/5 swift test"
WIMM_TEST_MODE=1 wimm_swift test

echo "[release-gate] 2/5 swift build -c release"
wimm_swift build -c release

echo "[release-gate] 3/5 xcodegen generate"
xcodegen generate --quiet

echo "[release-gate] 4/5 xcodebuild iOS Release (no signing)"
wimm_xcodebuild -project Wimm.xcodeproj -scheme WimmiOSApp -configuration Release \
  -destination "generic/platform=iOS" build CODE_SIGNING_ALLOWED=NO

echo "[release-gate] 5/5 web and script tests"
npm --prefix Apps/WimmStudioWeb test
python3 -m unittest discover -s scripts/tests -p 'test_*.py'

echo "[release-gate] PASS"
