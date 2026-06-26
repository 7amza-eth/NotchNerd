#!/usr/bin/env bash
#
# setup-dev-signing.sh — create a STABLE local code-signing identity for NotchNerd dev builds.
#
# WHY: NotchNerd is unsandboxed (Phase 0) and its agent features rely on Automation +
# Accessibility (TCC) grants. macOS keys those grants to the binary's code-signing identity
# (its Designated Requirement / cdhash lineage). boring.notch's default local signing is
# ad-hoc ("-"), which produces a NEW cdhash on every build, so every rebuild silently RESETS
# your Automation/Accessibility grants and you must re-approve them constantly.
#
# Signing every local build with the SAME self-signed identity keeps the Designated Requirement
# stable, so TCC grants persist across rebuilds. (Mirrors Open Island's scripts/setup-dev-signing.sh.)
#
# This script is idempotent and non-destructive. It does NOT require sudo and does NOT add the
# cert to the system trust store — local run + a stable identity is all the TCC-stability goal needs.
#
# Usage:  zsh tooling/scripts/setup-dev-signing.sh
#
set -euo pipefail

IDENTITY_NAME="NotchNerd Dev"
LOGIN_KEYCHAIN="$(security default-keychain | tr -d ' "')"

echo "==> NotchNerd dev signing setup"
echo "    Identity: ${IDENTITY_NAME}"
echo "    Keychain: ${LOGIN_KEYCHAIN}"

# 1. Already present? Then we're done.
if security find-identity -v -p codesigning "${LOGIN_KEYCHAIN}" 2>/dev/null | grep -q "\"${IDENTITY_NAME}\""; then
  echo "==> A code-signing identity named '${IDENTITY_NAME}' already exists. Nothing to do."
  security find-identity -v -p codesigning "${LOGIN_KEYCHAIN}" | grep "${IDENTITY_NAME}" || true
  exit 0
fi

echo "==> No '${IDENTITY_NAME}' identity found. Generating a stable self-signed code-signing certificate..."

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
KEY="${WORKDIR}/key.pem"
CRT="${WORKDIR}/cert.pem"
P12="${WORKDIR}/notchnerd-dev.p12"

# 2. Self-signed cert with the Code Signing extended-key-usage (10-year validity for a stable lineage).
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${KEY}" -out "${CRT}" -days 3650 \
  -subj "/CN=${IDENTITY_NAME}/O=NotchNerd Local Dev" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# 3. Bundle key+cert into a passwordless PKCS#12 and import into the login keychain,
#    pre-authorizing /usr/bin/codesign to use the private key without an interactive prompt.
openssl pkcs12 -export -inkey "${KEY}" -in "${CRT}" -out "${P12}" -passout pass: -name "${IDENTITY_NAME}" >/dev/null 2>&1

security import "${P12}" -k "${LOGIN_KEYCHAIN}" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1

# 4. Allow codesign to access the key non-interactively (best-effort; harmless if it no-ops).
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "" "${LOGIN_KEYCHAIN}" >/dev/null 2>&1 || true

echo "==> Done. Verifying:"
security find-identity -v -p codesigning "${LOGIN_KEYCHAIN}" | grep "${IDENTITY_NAME}" || {
  echo "!! Could not verify the new identity. If this failed, create it manually via Keychain Access:"
  echo "   Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…"
  echo "     Name: ${IDENTITY_NAME}   Identity Type: Self Signed Root   Certificate Type: Code Signing"
  exit 1
}

cat <<EOF

==> NEXT: point local dev builds at this identity (do NOT commit this — it's per-developer):

  In Xcode:  target NotchNerd ▸ Signing & Capabilities ▸ uncheck
             "Automatically manage signing" ▸ set Signing Certificate to "${IDENTITY_NAME}".

  OR via a local-only xcconfig (gitignored), set:
      CODE_SIGN_IDENTITY = ${IDENTITY_NAME}
      CODE_SIGN_STYLE = Manual

  Then do a clean build. Your Automation/Accessibility grants will now survive rebuilds.
  NOTE: CI release builds keep using the real "Apple Development"/Developer-ID cert — this
  identity is for LOCAL iteration only.
EOF
