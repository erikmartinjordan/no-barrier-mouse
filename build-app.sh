#!/bin/sh
set -eu

ARCH="${1:-native}"
VERSION="${VERSION:-0.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ICON_SRC="assets/NoBarrierMouse.icns"
DEFAULT_CODESIGN_ENV="$HOME/Library/Application Support/NoBarrierMouse/codesign-env.sh"
ENTITLEMENTS="NoBarrierMouse.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-NoBarrierMouse}"

if [ -f "$DEFAULT_CODESIGN_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DEFAULT_CODESIGN_ENV"
fi

# Auto-detect Developer ID identity when notarizing
if [ "${NOTARIZE:-false}" = "true" ]; then
  DEV_ID="$(security find-identity -v -p basic 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)"
  if [ -n "$DEV_ID" ]; then
    CODESIGN_IDENTITY="$DEV_ID"
    echo "Using Developer ID identity: $CODESIGN_IDENTITY" >&2
  else
    echo "ERROR: NOTARIZE=true but no Developer ID Application certificate found." >&2
    echo "Run 'security find-identity -v -p basic' to check your certificates." >&2
    exit 1
  fi
fi

if [ ! -f "$ICON_SRC" ]; then
  echo "Missing $ICON_SRC" >&2
  exit 1
fi

if [ "$ARCH" = "intel" ]; then
  SCRATCH=".build-intel"
  SWIFT_BUILD_ARGS="-c release --arch x86_64 --disable-sandbox --scratch-path $SCRATCH"
  BUILD_DIR="$SCRATCH/x86_64-apple-macosx/release"
  APP=".build/release/intel/NoBarrierMouse.app"
else
  SCRATCH=".build-native"
  SWIFT_BUILD_ARGS="-c release --disable-sandbox --scratch-path $SCRATCH"
  BUILD_DIR="$SCRATCH/release"
  APP=".build/release/native/NoBarrierMouse.app"
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
  <string>com.erikmartinjordan.NoBarrierMouse</string>
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
  <key>CFBundleIconName</key>
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

# Determine signing strategy
DO_NOTARIZE=false

if [ "${NO_CODESIGN:-0}" = "1" ]; then
  echo "Skipping codesign because NO_CODESIGN=1" >&2
elif command -v codesign >/dev/null 2>&1; then
  if [ -n "${CODESIGN_KEYCHAIN:-}" ] && [ -f "${CODESIGN_KEYCHAIN_PASSWORD_FILE:-}" ]; then
    security unlock-keychain -p "$(cat "$CODESIGN_KEYCHAIN_PASSWORD_FILE")" "$CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
  fi

  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    # Check if this is a Developer ID (notarizable distribution identity)
    case "$CODESIGN_IDENTITY" in
      *"Developer ID Application"*)
        DO_NOTARIZE=${NOTARIZE:-true}
        SIGN_FLAGS="--force --deep --timestamp --options=runtime"
        if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
          SIGN_FLAGS="$SIGN_FLAGS --keychain $CODESIGN_KEYCHAIN"
        fi
        if [ -f "$ENTITLEMENTS" ]; then
          SIGN_FLAGS="$SIGN_FLAGS --entitlements $ENTITLEMENTS"
        fi
        ;;
      *)
        SIGN_FLAGS="--force --deep --timestamp=none"
        if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
          SIGN_FLAGS="$SIGN_FLAGS --keychain $CODESIGN_KEYCHAIN"
        fi
        ;;
    esac

    SIGN_LOG="$(mktemp "${TMPDIR:-/tmp}/nobarrier-codesign.XXXXXX")"
    if codesign $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$APP" 2>"$SIGN_LOG"; then
      echo "Signed with identity: $CODESIGN_IDENTITY" >&2
      rm -f "$SIGN_LOG"
    else
      echo "WARNING: codesign failed for identity: $CODESIGN_IDENTITY" >&2
      cat "$SIGN_LOG" >&2
      rm -f "$SIGN_LOG"
      echo "Falling back to ad-hoc signing..." >&2
      codesign --force --deep --sign - "$APP"
    fi
  else
    codesign --force --deep --sign - "$APP"
    echo "WARNING: signed ad-hoc. macOS may ask for Accessibility/Input Monitoring again after each rebuild." >&2
    if [ -f "$DEFAULT_CODESIGN_ENV" ]; then
      echo "Run scripts/create-local-codesign-identity.sh --trust and approve the macOS prompt once." >&2
    else
      echo "Run scripts/create-local-codesign-identity.sh once to create a stable local signing identity." >&2
    fi
  fi
fi

# Notarization
if [ "$DO_NOTARIZE" = "true" ]; then
  echo "Submitting for notarization (profile: $NOTARY_PROFILE)..." >&2
  ZIP_PATH="$(mktemp "${TMPDIR:-/tmp}/nobarrier-notarize.XXXXXX").zip"
  ditto -c -k --keepParent "$APP" "$ZIP_PATH"

  SUBMISSION_LOG="$(mktemp "${TMPDIR:-/tmp}/nobarrier-submission.XXXXXX")"
  if xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format plist \
    > "$SUBMISSION_LOG" 2>&1; then
    echo "Notarization submitted successfully." >&2
    rm -f "$ZIP_PATH"

    # Check status
    STATUS=$(plutil -extract "status" raw - < "$SUBMISSION_LOG" 2>/dev/null || echo "unknown")
    echo "Notarization status: $STATUS" >&2

    if [ "$STATUS" = "Accepted" ]; then
      echo "Stapling notarization ticket..." >&2
      if xcrun stapler staple "$APP"; then
        echo "Notarization ticket stapled." >&2
      else
        echo "WARNING: stapling failed." >&2
      fi
    else
      echo "WARNING: notarization was not accepted (status=$STATUS)." >&2
      echo "Full output:" >&2
      cat "$SUBMISSION_LOG" >&2
    fi
  else
    echo "WARNING: notarytool submission failed." >&2
    cat "$SUBMISSION_LOG" >&2
    rm -f "$ZIP_PATH"
  fi
  rm -f "$SUBMISSION_LOG"
fi

echo "$APP"
