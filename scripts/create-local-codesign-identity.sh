#!/usr/bin/env bash
set -euo pipefail

IDENTITY="${NO_BARRIER_MOUSE_CODESIGN_IDENTITY:-NoBarrierMouse Local Development}"
SUPPORT_DIR="${NO_BARRIER_MOUSE_CODESIGN_DIR:-$HOME/Library/Application Support/NoBarrierMouse}"
KEYCHAIN="$SUPPORT_DIR/NoBarrierMouseDev.keychain-db"
PASSWORD_FILE="$SUPPORT_DIR/codesign-keychain-password"
CERT_DIR="$SUPPORT_DIR/codesign-cert"
ENV_FILE="$SUPPORT_DIR/codesign-env.sh"
TRUST_CERTIFICATE=0

if [[ "${1:-}" == "--trust" ]]; then
  TRUST_CERTIFICATE=1
fi

mkdir -p "$SUPPORT_DIR" "$CERT_DIR"
chmod 700 "$SUPPORT_DIR"

if [[ ! -f "$PASSWORD_FILE" ]]; then
  {
    uuidgen
    uuidgen
  } | tr -d '\n' > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
fi

PASSWORD="$(cat "$PASSWORD_FILE")"

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi

security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed 's/[\" ]//g')

if [[ ! -f "$CERT_DIR/identity.p12" ]]; then
  cat > "$CERT_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = codesign

[ dn ]
CN = $IDENTITY

[ codesign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

  openssl req \
    -newkey rsa:2048 \
    -nodes \
    -keyout "$CERT_DIR/key.pem" \
    -x509 \
    -days 3650 \
    -out "$CERT_DIR/cert.pem" \
    -config "$CERT_DIR/openssl.cnf" \
    -extensions codesign

  openssl pkcs12 \
    -export \
    -inkey "$CERT_DIR/key.pem" \
    -in "$CERT_DIR/cert.pem" \
    -name "$IDENTITY" \
    -out "$CERT_DIR/identity.p12" \
    -passout "pass:$PASSWORD"
fi

if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  security import "$CERT_DIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$PASSWORD" \
    -T /usr/bin/codesign \
    -f pkcs12

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$PASSWORD" \
    "$KEYCHAIN" >/dev/null
fi

cat > "$ENV_FILE" <<EOF
export CODESIGN_IDENTITY="$IDENTITY"
export CODESIGN_KEYCHAIN="$KEYCHAIN"
export CODESIGN_KEYCHAIN_PASSWORD_FILE="$PASSWORD_FILE"
EOF
chmod 600 "$ENV_FILE"

echo "Created stable code-signing identity:"
if security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "$IDENTITY"; then
  security find-identity -v -p codesigning "$KEYCHAIN"
else
  if [[ "$TRUST_CERTIFICATE" == "1" ]]; then
    echo "macOS will ask for Touch ID or your password to trust the local code-signing certificate."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_DIR/cert.pem"
  fi

  if security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "$IDENTITY"; then
    security find-identity -v -p codesigning "$KEYCHAIN"
  else
    echo "The certificate was created, but macOS does not trust it for code signing yet." >&2
    echo "Run this once and approve the macOS prompt:" >&2
    echo "  scripts/create-local-codesign-identity.sh --trust" >&2
    exit 2
  fi
fi

IDENTITY_HASH="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n "s/^[[:space:]]*[0-9]*) \\([A-F0-9]*\\) \\\"$IDENTITY\\\".*/\\1/p" | head -n 1)"
if [[ -n "$IDENTITY_HASH" ]]; then
  cat > "$ENV_FILE" <<EOF
export CODESIGN_IDENTITY="$IDENTITY_HASH"
export CODESIGN_KEYCHAIN="$KEYCHAIN"
export CODESIGN_KEYCHAIN_PASSWORD_FILE="$PASSWORD_FILE"
EOF
  chmod 600 "$ENV_FILE"
fi
echo
echo "Future builds will source:"
echo "  $ENV_FILE"
echo
echo "Next step: rebuild NoBarrierMouse, then grant Accessibility/Input Monitoring once to the rebuilt app."
