#!/bin/bash
set -e

echo "🚀 Building WimmiOS using xcodebuild..."

# Find iOS simulator
DEVICE_ID=$(xcrun simctl list devices available | grep "iPhone" | grep -v "unavailable" | head -1 | grep -oE '\([0-9A-F-]+\)' | tr -d '()')

if [ -z "$DEVICE_ID" ]; then
    echo "❌ No iOS simulator found. Install one via Xcode."
    exit 1
fi

DEVICE_NAME=$(xcrun simctl list devices available | grep "$DEVICE_ID" | sed -E 's/^[[:space:]]+//' | sed -E 's/ \([^)]+\).*//')

echo "📱 Target simulator: $DEVICE_NAME"
echo "   Device ID: $DEVICE_ID"

# Boot simulator if not running
echo "🔄 Booting simulator..."
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
open -a Simulator
sleep 2

# Resolve dependencies first
echo "📦 Resolving dependencies..."
swift package resolve

# Build using xcodebuild (properly links UIKit)
echo "🔨 Building for iOS Simulator..."

xcodebuild \
    -scheme wimm-ios \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath .build/xcode \
    -configuration Debug \
    build

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ Build failed."
    echo ""
    echo "💡 Try cleaning and rebuilding:"
    echo "   rm -rf .build"
    echo "   ./scripts/build_ios_xcode.sh"
    exit 1
fi

# Find the built app
APP_PATH=$(find .build/xcode/Build/Products/Debug-iphonesimulator -name "*.app" -type d 2>/dev/null | head -1)

# If no .app bundle found, check for executable and package it manually
if [ -z "$APP_PATH" ]; then
    EXECUTABLE=".build/xcode/Build/Products/Debug-iphonesimulator/wimm-ios"
    if [ -f "$EXECUTABLE" ]; then
        echo "⚠️ .app bundle not found, but executable exists. Packaging manually..."
        
        APP_NAME="WimmiOS"
        APP_PATH=".build/xcode/Build/Products/Debug-iphonesimulator/$APP_NAME.app"
        APP_EXECUTABLE="$APP_PATH/$APP_NAME"
        
        mkdir -p "$APP_PATH"
        cp "$EXECUTABLE" "$APP_EXECUTABLE"
        chmod +x "$APP_EXECUTABLE"
        
        # Create Info.plist
        cat > "$APP_PATH/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WimmiOS</string>
    <key>CFBundleIdentifier</key>
    <string>com.wimm.ios</string>
    <key>CFBundleName</key>
    <string>Wimm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>UILaunchScreen</key>
    <dict/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Wimm needs microphone access to record voice notes</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Wimm uses speech recognition to transcribe your recordings</string>
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
    </array>
</dict>
</plist>
EOF
    else
        echo "❌ .app bundle not found and executable ($EXECUTABLE) not found."
        exit 1
    fi
fi

if [ -z "$APP_PATH" ]; then
    echo "❌ .app bundle not found"
    exit 1
fi

echo "✅ Build successful!"
echo "📦 App bundle: $APP_PATH"

# Install to simulator
echo "📲 Installing to simulator..."
xcrun simctl install "$DEVICE_ID" "$APP_PATH"

# Get bundle ID
BUNDLE_ID=$(defaults read "$APP_PATH/Info.plist" CFBundleIdentifier 2>/dev/null || echo "com.wimm.ios")

echo "🚀 Launching app..."
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"

echo ""
echo "✅ WimmiOS is running in the simulator!"
echo "   Device: $DEVICE_NAME"
echo "   Bundle ID: $BUNDLE_ID"
