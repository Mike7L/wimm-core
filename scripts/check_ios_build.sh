#!/bin/bash
set -e

# Simple iOS build check script for WimmiOS target
# Usage: ./scripts/check_ios_build.sh

echo "🔍 Checking iOS build for WimmiOS..."

# Check for required tools
if ! command -v swift &> /dev/null; then
    echo "❌ Swift not found. Please install Xcode."
    exit 1
fi

# Regenerate Xcode project first to make sure it's up to date
xcodegen generate

# Try building WimmiOSApp for iOS Simulator
echo "📱 Building WimmiOSApp for iOS simulator..."
xcodebuild \
    -scheme WimmiOSApp \
    -destination "generic/platform=iOS Simulator" \
    -configuration Debug \
    -quiet \
    build \
    || {
        echo "❌ Build failed for iOS"
        echo ""
        echo "💡 Tip: To see more details, run:"
        echo "   xcodebuild -scheme WimmiOSApp -destination 'generic/platform=iOS Simulator' -configuration Debug build"
        exit 1
    }

echo "✅ iOS build successful!"
echo ""
echo "📝 Note: This only checks compilation."
echo "   To run in simulator, use Xcode or xcodebuild."
