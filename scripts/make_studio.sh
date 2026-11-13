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
    echo 'Usage: scripts/make_studio.sh [-i|--debug] (WIMM_NO_OPEN=1 to skip opening)'
    exit 0 ;;
  *) echo "Unknown Studio build option: $1" >&2; exit 2 ;;
esac
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode-beta.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
STARTED=$SECONDS
mkdir -p "$ROOT_DIR/logs"
exec > >(tee "$ROOT_DIR/logs/studio_build_log.txt") 2>&1
APP_DIR="$ROOT_DIR/Wimm Studio.app"
BIN="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIG/wimm-studio"
# Resolve signing before the cache check: a newly available certificate must
# invalidate a previously ad-hoc package, even when its executable is unchanged.
WIMM_BUILD_SIGNING_IDENTITIES="$(security find-identity -p codesigning -v 2>/dev/null || true)"
export WIMM_BUILD_SIGNING_IDENTITIES
CODESIGN_ID="${CODESIGN_ID:-}"
if [[ -z "$CODESIGN_ID" ]]; then
  # Developer ID first: only it gets production push, which CloudKit needs
  # before it lets Studio subscribe to instant changes from the iPhone.
  CODESIGN_ID=$( { printf '%s\n' "$WIMM_BUILD_SIGNING_IDENTITIES" | grep 'Developer ID Application'; \
                   printf '%s\n' "$WIMM_BUILD_SIGNING_IDENTITIES" | grep 'Apple Development'; } \
                 | head -n1 | sed -E 's/.*"(.*)"/\1/') || true
fi
if [[ -z "$CODESIGN_ID" ]] && printf '%s\n' "$WIMM_BUILD_SIGNING_IDENTITIES" | grep -q '"WimmDev"'; then
  CODESIGN_ID=WimmDev
fi
if [[ -z "$CODESIGN_ID" || "$CODESIGN_ID" == "-" ]]; then
  if [[ "${ALLOW_ADHOC:-0}" != "1" ]]; then
    echo 'Studio needs a signing identity to retain screen-recording permission. Set CODESIGN_ID or create WimmDev with scripts/create_dev_identity.sh. ALLOW_ADHOC=1 explicitly permits a temporary ad-hoc build.' >&2
    exit 1
  fi
  CODESIGN_ID=-
  echo 'Warning: ad-hoc Studio builds may require screen-recording permission again after each update.' >&2
fi
export CODESIGN_ID
wimm_swift build --product wimm-studio -c "$CONFIG" \
  --build-path "$ROOT_DIR/.build" --triple arm64-apple-macosx
BUILD_DONE=$SECONDS
echo "⏱ Studio build: $((BUILD_DONE - STARTED)) s"
update_receipt() {
  python3 "$ROOT_DIR/scripts/app_update_cache.py" "$1" \
    --kind studio --root "$ROOT_DIR" --binary "$BIN"
}
if update_receipt check; then
  echo '✓ Studio is unchanged; keeping the running app.'
else
  process_pattern="^${APP_DIR//./\\.}/Contents/MacOS/wimm-studio$"
  pkill -f "$process_pattern" || true
  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! pgrep -f "$process_pattern" >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -f "$process_pattern" >/dev/null; then
    echo 'Studio is still shutting down; installed bundle was not changed.' >&2
    exit 1
  fi
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  cp "$ROOT_DIR/Apps/WimmStudio/Info.plist" "$APP_DIR/Contents/Info.plist"
  staged="$APP_DIR/Contents/MacOS/wimm-studio.installing.$$"
  cp "$BIN" "$staged"
  chmod +x "$staged"
  mv -f "$staged" "$APP_DIR/Contents/MacOS/wimm-studio"
  chmod -R u+w "$APP_DIR/Contents/Resources"
  for resource in "$(dirname "$BIN")/"*.bundle; do
    [[ -d "$resource" ]] || continue
    rsync -rlpc --delete "$resource/" "$APP_DIR/Contents/Resources/$(basename "$resource")/"
  done
  printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
  # CloudKit sync with the iPhone needs the same identity as Wimm: Studio's
  # bundle id is com.micha.wimm.macos, so the profile make_app.sh embeds fits.
  # Restricted iCloud entitlements without the profile get the app SIGKILLed at
  # launch, so they are used only together; otherwise sync stays off.
  ENTITLEMENTS="$ROOT_DIR/WimmLocal.entitlements"
  # A Developer ID identity needs the Developer ID profile (ProvisionsAllDevices,
  # production push) and WimmProdCloud.entitlements; a development identity the
  # development profile. Mixing them gets the app killed at launch.
  if [[ "$CODESIGN_ID" == *"Developer ID Application"* ]]; then
    CLOUD_ENTITLEMENTS="$ROOT_DIR/WimmProdCloud.entitlements"; WANT_DIRECT_PROFILE=1
  else
    CLOUD_ENTITLEMENTS="$ROOT_DIR/WimmDevCloud.entitlements"; WANT_DIRECT_PROFILE=0
  fi
  CLOUD_PROFILE="${WIMM_MAC_PROFILE:-}"
  if [[ -z "$CLOUD_PROFILE" && ( "$CODESIGN_ID" == *"Apple Development"* || "$CODESIGN_ID" == *"Developer ID Application"* ) ]]; then
    for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile \
                   "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile; do
      [[ -f "$profile" ]] || continue
      decoded=$(security cms -D -i "$profile" 2>/dev/null) || continue
      if grep -q "32KX9D23R9.com.micha.wimm.macos" <<<"$decoded" \
         && grep -q "iCloud.com.micha.wimm" <<<"$decoded"; then
        IS_DIRECT=0
        grep -q "ProvisionsAllDevices" <<<"$decoded" && IS_DIRECT=1
        [[ "$IS_DIRECT" == "$WANT_DIRECT_PROFILE" ]] || continue
        CLOUD_PROFILE="$profile"
        break
      fi
    done
  fi
  if [[ -n "$CLOUD_PROFILE" && -f "$CLOUD_PROFILE" ]]; then
    echo "☁️  Studio CloudKit signing: embedding profile $(basename "$CLOUD_PROFILE")"
    cp "$CLOUD_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
    ENTITLEMENTS="$CLOUD_ENTITLEMENTS"
  else
    rm -f "$APP_DIR/Contents/embedded.provisionprofile"
    echo '⚠️  No Apple Development/Developer ID identity or no matching profile with iCloud.com.micha.wimm: Studio sync stays off.' >&2
  fi
  echo "🔏 Studio entitlements: $(basename "$ENTITLEMENTS")"
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" -s "$CODESIGN_ID" "$APP_DIR"
  # Failure to verify must never produce a successful update or cache receipt.
  update_receipt record
fi
if [[ "${WIMM_NO_OPEN:-0}" != "1" ]]; then open -a "$APP_DIR"; fi
echo "⏱ Studio update and launch: $((SECONDS - BUILD_DONE)) s"
echo "⏱ Studio total: $((SECONDS - STARTED)) s"
