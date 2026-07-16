# NoBarrierMouse

## Build

make            → .build/release/native/NoBarrierMouse.app (ad-hoc)
make intel      → .build/release/intel/NoBarrierMouse.app (ad-hoc)
make notarize   → native + Developer ID signing + notarization
make notarize-intel → Intel + Developer ID signing + notarization
make clean      → removes build scratch dirs and release output

## Notarization setup (local)

1. Generate an app-specific password at https://appleid.apple.com/account/manage
2. `scripts/setup-notarization.sh` — stores credentials in Keychain
3. Ensure Developer ID Application certificate is in your keychain
4. `make notarize` — builds, signs, and notarizes

## CI/CD setup (GitHub Secrets)

The release workflow expects these secrets:

| Secret | Description |
|--------|-------------|
| `APPLE_DEVELOPER_ID_CERT_BASE64` | Base64-encoded Developer ID .p12 certificate |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | Password for the .p12 above |
| `APPLE_ID` | Apple ID email (e.g. erikmartinjordan@gmail.com) |
| `APPLE_ID_PASSWORD` | App-specific password from appleid.apple.com |

### Exporting the Developer ID certificate

```bash
# In Keychain Access → My Certificates → right-click Developer ID Application → Export
# Save as NoBarrierMouse.p12 (set a password)

# Encode for GitHub Secret
base64 < NoBarrierMouse.p12 | pbcopy
# Paste into GitHub repo → Settings → Secrets → Actions → APPLE_DEVELOPER_ID_CERT_BASE64
# Paste the p12 password into APPLE_DEVELOPER_ID_CERT_PASSWORD
```
