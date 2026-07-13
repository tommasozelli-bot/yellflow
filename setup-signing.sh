#!/usr/bin/env bash
#
# Creates a STABLE self-signed code-signing identity in a dedicated keychain we
# fully control (so no login-keychain password is ever needed). Signing Yell Flow
# with this identity gives it a stable "designated requirement", which means macOS
# permission grants (Accessibility, Input Monitoring, Microphone) PERSIST across
# rebuilds — no more re-granting every time the app is recompiled.
#
# Run once. build.sh auto-detects the identity and uses it; otherwise falls back
# to ad-hoc signing.
#
set -euo pipefail

IDENTITY="Yell Flow Local"
KEYCHAIN="yellflow-signing.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN"
KPW="yellflow"

if security find-identity -v "$KEYCHAIN_PATH" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ Signing identity '$IDENTITY' already exists."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cfg" <<'CFG'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Yell Flow Local
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG

echo "▸ Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cfg" >/dev/null 2>&1
# Non-empty password + SHA1 MAC so Apple's `security` tool can import it.
openssl pkcs12 -export -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:yellflow -macalg sha1 >/dev/null 2>&1 \
  || openssl pkcs12 -export -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -passout pass:yellflow >/dev/null 2>&1

echo "▸ Creating dedicated keychain and importing the identity…"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KPW" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN_PATH"            # disable auto-lock timeout
security unlock-keychain -p "$KPW" "$KEYCHAIN_PATH"
security import "$WORK/id.p12" -k "$KEYCHAIN_PATH" -P yellflow -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KPW" "$KEYCHAIN_PATH" >/dev/null 2>&1
# Make codesign -s "Yell Flow Local" able to find it, keeping the login keychain first.
security list-keychains -d user -s login.keychain-db "$KEYCHAIN_PATH"

echo "✅ Created signing identity '$IDENTITY'."
security find-identity -v "$KEYCHAIN_PATH" | grep "$IDENTITY" || true
