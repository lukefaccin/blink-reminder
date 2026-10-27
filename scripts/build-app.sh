#!/usr/bin/env bash
# Builds BlinkReminder.app with swiftc. Needs only the Xcode Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD_DIR="${BUILD_DIR:-build}"
APP="$BUILD_DIR/BlinkReminder.app"

mkdir -p "$BUILD_DIR/module-cache"

# Compile first so a failed build leaves the previous app bundle intact.
swiftc -O -swift-version 6 \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -o "$BUILD_DIR/BlinkReminder" \
  Sources/BlinkReminder/*.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv "$BUILD_DIR/BlinkReminder" "$APP/Contents/MacOS/BlinkReminder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
