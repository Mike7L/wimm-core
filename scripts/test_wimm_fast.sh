#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/build_budget.sh"
export WIMM_BUILD_JOBS
export WIMM_TEST_SCOPE=core
export WIMM_TEST_MODE=1
# Subprocess smoke checks must never resolve the user's real library.
TEST_LIBRARY="$(mktemp -d "${TMPDIR:-/tmp}/wimm-fast-tests.XXXXXX")"
trap 'rm -rf "$TEST_LIBRARY"' EXIT
export WIMM_BASE_DIR="$TEST_LIBRARY"
export WIMM_ROOT_DIR="$TEST_LIBRARY/tui"

echo "[1/2] Running WIMM package tests from the root build..."
(
  # The root package declares WimmCoreTests too, so the tests reuse the WimmCore modules the
  # app build already compiled instead of a second ~1.6 GB build in Packages/WimmCore/.build.
  # wimm-tui is built for the TUI smoke tests, which skip without it.
  cd "$ROOT_DIR"
  wimm_swift build --product wimm-tui
  wimm_swift test --filter WimmCoreTests
)

echo "[2/2] Running WimmCLI -> WIMM bridge smoke (no full Wimm build)..."
(
  cd "$ROOT_DIR"
  WIMM_USE_TUI=1 WIMM_TRANSCRIBER=mock ./scripts/run_wimm_cli.sh queue status --details
)

echo "WIMM fast checks passed."
