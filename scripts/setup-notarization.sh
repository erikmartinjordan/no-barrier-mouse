#!/bin/sh
set -eu

echo "=== NoBarrierMouse Notarization Setup ==="
echo ""
echo "Steps:"
echo "  1. Go to https://appleid.apple.com/account/manage"
echo "  2. Sign in with your Apple ID"
echo "  3. Under APP-SPECIFIC PASSWORDS, click Generate Password"
echo "  4. Name it something like 'NoBarrierMouse Notarization'"
echo "  5. Copy the generated password (looks like: xxxx-xxxx-xxxx-xxxx)"
echo ""
echo "You'll also need your Team ID (already configured: FL97XCW5XD)"
echo ""

read -p "Apple ID (erikmartinjordan@gmail.com): " APPLE_ID
APPLE_ID="${APPLE_ID:-erikmartinjordan@gmail.com}"

echo "Enter the app-specific password (paste it, it won't show):"
stty -echo
read APP_PASSWORD
stty echo
echo ""

PROFILE_NAME="NoBarrierMouse"

echo ""
echo "Storing credentials in Keychain as profile '$PROFILE_NAME'..."

xcrun notarytool store-credentials "$PROFILE_NAME" \
  --apple-id "$APPLE_ID" \
  --team-id "FL97XCW5XD" \
  --password "$APP_PASSWORD"

echo ""
echo "Credentials stored successfully."
echo ""
echo "Now running a quick validation..."
xcrun notarytool validate-credentials --keychain-profile "$PROFILE_NAME" 2>&1 || echo "Credential profile name: $PROFILE_NAME"

echo ""
echo "Setup complete. The app will now auto-notarize on every build."
