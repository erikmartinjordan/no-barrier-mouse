#!/bin/sh
# Import Developer ID certificate into the default keychain for CI signing.
# Usage: import-certs.sh <base64-p12-path> <password>
set -eu

P12_B64="${1:?Usage: import-certs.sh <base64-p12-path> <password>}"
PASSWORD="${2:?Usage: import-certs.sh <base64-p12-path> <password>}"

TMP_P12="$(mktemp "${TMPDIR:-/tmp}/nobarrier-cert.XXXXXX.p12")"
base64 --decode --output "$TMP_P12" < "$P12_B64"

# Create a temporary keychain so we don't pollute the default
KEYCHAIN="NoBarrierMouseCI.keychain"
KEYCHAIN_PASSWORD="nobarrier-ci-$(uuidgen)"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security default-keychain -s "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 600 "$KEYCHAIN"

security import "$TMP_P12" \
  -k "$KEYCHAIN" \
  -P "$PASSWORD" \
  -T /usr/bin/codesign \
  -f pkcs12

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN" >/dev/null

rm -f "$TMP_P12"

echo "Certificate imported successfully."
echo "KEYCHAIN=$KEYCHAIN"
