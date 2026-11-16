#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/build_budget.sh"
CONFIG=release
case "${1:--i}" in
  -i|--incremental) ;;
  --debug) CONFIG=debug ;;
  -h|--help)
    echo 'Usage: scripts/make_cli.sh [-i|--debug]'
    exit 0 ;;
  *) echo "Unknown CLI build option: $1" >&2; exit 2 ;;
esac

CLI_NAME="WimmCLI"
CLI_APP_DIR="$ROOT_DIR/$CLI_NAME.app"
CLI_INFO_TEMPLATE="$ROOT_DIR/Sources/WimmCLI/Info.plist"
CLI_ENTITLEMENTS_FILE="$ROOT_DIR/Sources/WimmCLI/entitlements.plist"
BIN="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIG/$CLI_NAME"

echo "Building $CLI_NAME ($CONFIG)..."
wimm_swift build --product "$CLI_NAME" -c "$CONFIG" \
  --build-path "$ROOT_DIR/.build" --triple arm64-apple-macosx

mkdir -p "$CLI_APP_DIR/Contents/MacOS" "$CLI_APP_DIR/Contents/Resources"
if [[ -f "$CLI_INFO_TEMPLATE" ]]; then
  cp "$CLI_INFO_TEMPLATE" "$CLI_APP_DIR/Contents/Info.plist"
else
  cp "$ROOT_DIR/AppBundle/Info.plist" "$CLI_APP_DIR/Contents/Info.plist"
fi
CLI_PLIST_PATH="$CLI_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $CLI_NAME" "$CLI_PLIST_PATH" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $CLI_NAME" "$CLI_PLIST_PATH" >/dev/null
CLI_BUNDLE_ID="${WIMM_CLI_BUNDLE_ID:-com.micha.wimm.cli}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $CLI_BUNDLE_ID" "$CLI_PLIST_PATH" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $CLI_BUNDLE_ID" "$CLI_PLIST_PATH" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleName $CLI_NAME" "$CLI_PLIST_PATH" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $CLI_NAME" "$CLI_PLIST_PATH" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$CLI_PLIST_PATH" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$CLI_PLIST_PATH" >/dev/null

cp "$BIN" "$CLI_APP_DIR/Contents/MacOS/$CLI_NAME"
chmod +x "$CLI_APP_DIR/Contents/MacOS/$CLI_NAME"

if [[ -f "$ROOT_DIR/Assets/Wimm.icns" ]]; then
  cp "$ROOT_DIR/Assets/Wimm.icns" "$CLI_APP_DIR/Contents/Resources/Wimm.icns"
fi
printf "APPL????" > "$CLI_APP_DIR/Contents/PkgInfo"

for resource in "$(dirname "$BIN")/"*.bundle; do
  [[ -d "$resource" ]] || continue
  rsync -rlpc --delete "$resource/" "$CLI_APP_DIR/Contents/Resources/$(basename "$resource")/"
done

if [[ -d "$ROOT_DIR/Wimm.app/Contents/MacOS" ]]; then
  cp "$BIN" "$ROOT_DIR/Wimm.app/Contents/MacOS/$CLI_NAME"
  chmod +x "$ROOT_DIR/Wimm.app/Contents/MacOS/$CLI_NAME"
fi

mkdir -p "$HOME/.local/share/wimm"
cp "$BIN" "$HOME/.local/share/wimm/$CLI_NAME"
chmod +x "$HOME/.local/share/wimm/$CLI_NAME"

WIMM_BUILD_SIGNING_IDENTITIES="$(security find-identity -p codesigning -v 2>/dev/null || true)"
CODESIGN_ID="${CODESIGN_ID:-}"
if [[ -z "$CODESIGN_ID" ]]; then
  CODESIGN_ID=$( { printf '%s\n' "$WIMM_BUILD_SIGNING_IDENTITIES" | grep 'Developer ID Application'; \
                   printf '%s\n' "$WIMM_BUILD_SIGNING_IDENTITIES" | grep 'Apple Development'; } \
                 | head -n1 | sed -E 's/.*"(.*)"/\1/') || true
fi
if [[ -z "$CODESIGN_ID" ]] && printf '%s\n' "$WIMM_BUILD_SIGNING_IDENTITIES" | grep -q '"WimmDev"'; then
  CODESIGN_ID=WimmDev
fi

if [[ -n "$CODESIGN_ID" && "$CODESIGN_ID" != "-" ]]; then
  codesign --force --options runtime --entitlements "$CLI_ENTITLEMENTS_FILE" -s "$CODESIGN_ID" "$CLI_APP_DIR/Contents/MacOS/$CLI_NAME" || true
  codesign --force --deep --options runtime --entitlements "$CLI_ENTITLEMENTS_FILE" -s "$CODESIGN_ID" "$CLI_APP_DIR" || true
  if [[ -f "$ROOT_DIR/Wimm.app/Contents/MacOS/$CLI_NAME" ]]; then
    codesign --force --options runtime --entitlements "$ROOT_DIR/WimmProdCloud.entitlements" -s "$CODESIGN_ID" "$ROOT_DIR/Wimm.app/Contents/MacOS/$CLI_NAME" || true
  fi
  codesign --force --options runtime --entitlements "$CLI_ENTITLEMENTS_FILE" -s "$CODESIGN_ID" "$HOME/.local/share/wimm/$CLI_NAME" || true
else
  codesign --force --deep -s - "$CLI_APP_DIR" || true
fi

# Studio runs the WimmCLI.app next to its own bundle first
# (SecretaryDispatcher.locateWimmCLI). When Studio is installed outside the
# checkout (WIMM_STUDIO_APP, read as in make_studio.sh), put the signed bundle
# there too, or Studio keeps calling whatever old copy lies beside it.
# rsync replaces files by rename, so a running copy is not overwritten in place.
if [[ -z "${WIMM_STUDIO_APP:-}" && -f "$ROOT_DIR/.env" ]]; then
  WIMM_STUDIO_APP=$(sed -nE 's/^WIMM_STUDIO_APP=["'\'']?([^"'\'']*)["'\'']?[[:space:]]*$/\1/p' "$ROOT_DIR/.env" | tail -n1)
fi
STUDIO_APP="${WIMM_STUDIO_APP:-}"
STUDIO_APP="${STUDIO_APP/#\~/$HOME}"
STUDIO_CLI_APP=""
if [[ "$STUDIO_APP" == *.app && -d "$(dirname "$STUDIO_APP")" ]]; then
  STUDIO_CLI_APP="$(cd "$(dirname "$STUDIO_APP")" && pwd)/$CLI_NAME.app"
  if [[ "$STUDIO_CLI_APP" != "$CLI_APP_DIR" ]]; then
    mkdir -p "$STUDIO_CLI_APP"
    rsync -a --delete "$CLI_APP_DIR/" "$STUDIO_CLI_APP/"
  else
    STUDIO_CLI_APP=""
  fi
fi

echo "Built and signed $CLI_NAME at $CLI_APP_DIR, $HOME/.local/share/wimm/$CLI_NAME${STUDIO_CLI_APP:+, $STUDIO_CLI_APP}"
