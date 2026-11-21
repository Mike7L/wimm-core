#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/build_budget.sh"
export WIMM_BUILD_JOBS
export WIMM_TEST_SCOPE=core
export WIMM_TEST_MODE=1
# Tests must never resolve the user's real library.
TEST_LIBRARY="$(mktemp -d "${TMPDIR:-/tmp}/wimm-fast-tests.XXXXXX")"
trap 'rm -rf "$TEST_LIBRARY"' EXIT
export WIMM_BASE_DIR="$TEST_LIBRARY"

echo "Running WIMM package tests from the root build..."
(
  # The root package declares WimmCoreTests too, so the tests reuse the WimmCore modules the
  # app build already compiled instead of a second ~1.6 GB build in Packages/WimmCore/.build.
  cd "$ROOT_DIR"
  wimm_swift test --filter WimmCoreTests
)

echo "WIMM fast checks passed."
