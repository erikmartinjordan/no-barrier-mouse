#!/bin/sh
set -eu

ARCH="${1:-native}"

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

# Generate icon if needed
ICON_SRC=".build/icon/NoBarrierMouse.icns"
if [ ! -f "$ICON_SRC" ]; then
  echo "  Generating icon..."
  mkdir -p .build/icon
  "$PWD/genicon.sh" .build/icon
fi
cp "$ICON_SRC" "$RESOURCES/NoBarrierMouse.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
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
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>NoBarrierMouse</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>NoBarrierMouse connects to your other Mac on the local network to share keyboard and mouse input.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_nobarriermouse._tcp</string>
  </array>
</dict>
</plist>
PLIST

echo "$APP"
