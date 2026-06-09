#!/bin/sh
set -eu

ARCH="${1:-native}"
VERSION="${VERSION:-0.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ICON_SRC="assets/NoBarrierMouse.icns"

if [ ! -f "$ICON_SRC" ]; then
  echo "Missing $ICON_SRC" >&2
  exit 1
fi

if [ "$ARCH" = "intel" ]; then
  SCRATCH=".build-intel"
  SWIFT_BUILD_ARGS="-c release --arch x86_64 --disable-sandbox --scratch-path $SCRATCH"
  BUILD_DIR="$SCRATCH/x86_64-apple-macosx/release"
  APP=".build/release/NoBarrierMouse-Intel.app"
else
  SCRATCH=".build-native"
  SWIFT_BUILD_ARGS="-c release --disable-sandbox --scratch-path $SCRATCH"
  BUILD_DIR="$SCRATCH/release"
  APP=".build/release/NoBarrierMouse.app"
fi

mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"

swift build $SWIFT_BUILD_ARGS

CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BUILD_DIR/NoBarrierMouse" "$MACOS/NoBarrierMouse"
cp "$ICON_SRC" "$RESOURCES/NoBarrierMouse.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>NoBarrierMouse</string>
  <key>CFBundleIdentifier</key>
  <string>local.nobarriermouse.app</string>
  <key>CFBundleName</key>
  <string>NoBarrierMouse</string>
  <key>CFBundleDisplayName</key>
  <string>NoBarrierMouse</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key>
  <string>NoBarrierMouse</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>NoBarrierMouse connects to your other Mac on the local network to share keyboard and mouse input.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>NoBarrierMouse needs Input Monitoring on the controller Mac to capture keyboard input while controlling another Mac.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_nobarriermouse._tcp</string>
  </array>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP"
fi

echo "$APP"
