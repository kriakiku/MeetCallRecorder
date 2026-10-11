#!/opt/homebrew/bin/bash
# One-time (idempotent) setup: a local self-signed code-signing certificate
# so manage.sh can sign with a *stable* identity instead of ad-hoc (-s -).
# Ad-hoc signing hashes the binary content itself as the identity, so every
# rebuild looks like a brand new app to TCC - Screen Recording permission
# has to be re-granted after every single build. A real (if self-signed)
# identity doesn't change across rebuilds, so the grant sticks.
#
# No sudo needed - everything goes into the user's login keychain, not the
# system/admin one.
set -euo pipefail

IDENTITY_NAME="MeetCallRecorder Local Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${IDENTITY_NAME}\""; then
  echo "==> Signing identity '${IDENTITY_NAME}' already present and valid."
  exit 0
fi

echo "==> Generating local self-signed code-signing certificate..."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "${TMPDIR}/key.pem" -out "${TMPDIR}/cert.pem" -days 36500 -nodes \
  -subj "/CN=${IDENTITY_NAME}" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" >/dev/null 2>&1

# -legacy: OpenSSL 3+ defaults to AES-encrypted PKCS12, which macOS's
# Security framework can't import ("MAC verification failed") - the old
# RC2/3DES-based encoding it expects needs this flag explicitly now.
openssl pkcs12 -export -legacy -out "${TMPDIR}/cert.p12" -inkey "${TMPDIR}/key.pem" -in "${TMPDIR}/cert.pem" \
  -passout pass:temppass >/dev/null 2>&1

echo "==> Importing into login keychain..."
security import "${TMPDIR}/cert.p12" -k "$KEYCHAIN" -P temppass -T /usr/bin/codesign

echo "==> Trusting it for code signing (user store, no sudo)..."
security find-certificate -c "${IDENTITY_NAME}" -p "$KEYCHAIN" > "${TMPDIR}/trust-cert.pem"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "${TMPDIR}/trust-cert.pem"

security find-identity -v -p codesigning | grep "${IDENTITY_NAME}"
echo "==> Done. manage.sh will now sign with '${IDENTITY_NAME}' instead of ad-hoc."
