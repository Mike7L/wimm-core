#!/usr/bin/env bash
# Builds the iOS app, installs it on a simulator and launches it.
#   scripts/run_ios.sh                  # first available iPhone simulator
#   scripts/run_ios.sh "iPhone 17 Pro"  # by name
# Simulator builds keep the default signing: without the CloudKit
# entitlement the app traps at launch.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/build_budget.sh"

NAME="${1:-iPhone}"
DEVICE_ID=$(xcrun simctl list devices available | grep -F "$NAME" | head -n 1 \
  | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()' || true)
if [[ -z "$DEVICE_ID" ]]; then
  echo "No available simulator matches '$NAME':" >&2
  xcrun simctl list devices available | grep -E "iPhone|iPad" >&2 || true
  exit 1
fi

xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
open -a Simulator

xcodegen generate --quiet
DERIVED="$ROOT_DIR/.build/xcode-ios"
wimm_xcodebuild -project Wimm.xcodeproj -scheme WimmiOSApp -configuration Debug \
  -destination "id=$DEVICE_ID" -derivedDataPath "$DERIVED" -quiet build

APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/WimmiOSApp.app"
[[ -d "$APP_PATH" ]] || { echo "Built app not found at $APP_PATH" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")

xcrun simctl install "$DEVICE_ID" "$APP_PATH"
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
echo "Launched $BUNDLE_ID on $DEVICE_ID"
