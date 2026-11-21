#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/build_budget.sh"
CONFIG="${WIMM_CLI_CONFIG:-debug}"
ARCH="${WIMM_CLI_ARCH:-$(uname -m)}"
TRIPLE="${ARCH}-apple-macosx"
# WimmLocal by default: Wimm.entitlements carries restricted iCloud keys that
# AMFI rejects on a bare CLI binary (no embedded provisioning profile) — the
# process dies with SIGKILL (exit 137) before main.
ENTITLEMENTS_FILE="${WIMM_CLI_ENTITLEMENTS:-$ROOT_DIR/WimmLocal.entitlements}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "Unsupported WIMM_CLI_CONFIG: $CONFIG (expected: debug|release)" >&2
  exit 2
fi

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "Unsupported architecture: $ARCH (expected: arm64|x86_64)" >&2
  exit 2
fi

echo "Building WimmCLI ($CONFIG, $TRIPLE)..."
wimm_swift build --product WimmCLI -c "$CONFIG" --build-path "$ROOT_DIR/.build" --triple "$TRIPLE"

BIN="$ROOT_DIR/.build/$TRIPLE/$CONFIG/WimmCLI"
if [[ ! -f "$BIN" ]]; then
  echo "WimmCLI binary not found: $BIN" >&2
  exit 1
fi

CODESIGN_ID="${WIMM_CLI_CODESIGN_ID:-}"
if [[ -z "$CODESIGN_ID" ]]; then
  CANDIDATE=$(
    security find-identity -p codesigning -v 2>/dev/null \
      | grep -E 'Developer ID Application|Apple Development|WimmDev' \
      | head -n1 \
      | sed -E 's/.*"(.*)".*/\1/' || true
  )
  if [[ -n "$CANDIDATE" ]]; then
    CODESIGN_ID="$CANDIDATE"
  fi
fi

if [[ -f "$ENTITLEMENTS_FILE" ]]; then
  if [[ -n "$CODESIGN_ID" ]]; then
    echo "Signing WimmCLI with identity: $CODESIGN_ID"
    codesign --force --options runtime --entitlements "$ENTITLEMENTS_FILE" -s "$CODESIGN_ID" "$BIN"
  else
    echo "Signing WimmCLI ad-hoc with entitlements"
    codesign --force --entitlements "$ENTITLEMENTS_FILE" -s - "$BIN"
  fi
else
  if [[ -n "$CODESIGN_ID" ]]; then
    echo "Signing WimmCLI with identity: $CODESIGN_ID (no entitlements file)"
    codesign --force --options runtime -s "$CODESIGN_ID" "$BIN"
  else
    echo "Signing WimmCLI ad-hoc (no entitlements file)"
    codesign --force -s - "$BIN"
  fi
fi

exec "$BIN" "$@"
