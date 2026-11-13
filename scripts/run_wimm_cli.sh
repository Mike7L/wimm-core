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
USE_TUI="${WIMM_USE_TUI:-1}"

if [[ "$USE_TUI" == "1" || "$USE_TUI" == "true" || "$USE_TUI" == "yes" ]]; then
  args=("$@")
  run_tui=1

  if [[ "${#args[@]}" -gt 0 ]]; then
    case "${args[0]}" in
      queue|list|search|wimm|capture|notes|interactive|stats|transcript|export|import|clean|doctor)
        run_tui=1
        ;;
      record)
        # record command → maps to capture in WIMM TUI
        run_tui=1
        args=("capture" "${args[@]:1}")
        ;;
      process)
        # process <file> [opts] — route to WIMM when a file argument is given
        if [[ "${#args[@]}" -ge 2 ]]; then
          run_tui=1
        else
          run_tui=0
        fi
        ;;
      *)
        run_tui=0
        ;;
    esac
  fi

  if [[ "$run_tui" == "1" ]]; then
    echo "Running WIMM TUI via root package (WIMM_USE_TUI=$USE_TUI)..."
    if [[ -n "${WIMM_BASE_DIR:-}" && -z "${WIMM_ROOT_DIR:-}" ]]; then
      export WIMM_ROOT_DIR="$WIMM_BASE_DIR"
    fi

    # Legacy compatibility: `queue --details` => `queue status --details`
    if [[ "${#args[@]}" -ge 1 && "${args[0]}" == "queue" ]]; then
      if [[ "${#args[@]}" -eq 1 ]]; then
        args=("queue" "status")
      elif [[ "${args[1]}" != "status" && "${args[1]}" != "process" && "${args[1]}" != "retry" && "${args[1]}" != "report" ]]; then
        args=("queue" "status" "${args[@]:1}")
      fi
    fi

    # Legacy compatibility: `wimm <...>` => direct wimm-tui passthrough.
    if [[ "${#args[@]}" -ge 1 && "${args[0]}" == "wimm" ]]; then
      args=("${args[@]:1}")
    fi

    exec nice -n 10 swift run --jobs "$WIMM_BUILD_JOBS" \
      -Xswiftc -num-threads -Xswiftc "$WIMM_BUILD_JOBS" \
      --package-path "$ROOT_DIR" wimm-tui "${args[@]}"
  fi

  echo "WIMM_USE_TUI=$USE_TUI but command is not WIMM-compatible; falling back to WimmCLI legacy."
fi

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
