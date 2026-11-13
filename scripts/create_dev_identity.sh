#!/usr/bin/env bash
# Robust creation of self-signed code signing identity "WimmDev".
# Tries PKCS#12 import first, then raw key+cert with PKCS#8 fallback.
# Usage: ./scripts/create_dev_identity.sh
set -euo pipefail
NAME="WimmDev"
DAYS=3650
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
VERBOSE=${VERBOSE:-0}

if security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Identity '$NAME' already exists."
  exit 0
fi

OSSL="/usr/bin/openssl"
if ! "$OSSL" version >/dev/null 2>&1; then
  OSSL="openssl"
fi

TMP_DIR="$(mktemp -d)"
KEY="$TMP_DIR/key.pem"
CSR="$TMP_DIR/req.csr"
CERT="$TMP_DIR/cert.pem"
EXT="$TMP_DIR/ext.cnf"
PKCS12="$TMP_DIR/$NAME.p12"
PKCS8_KEY="$TMP_DIR/key-pkcs8.pem"
P12_PASS="devpass123"

cat >"$EXT" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

echo "[1/6] Generating private key…"
"$OSSL" genrsa -out "$KEY" 2048 >/dev/null 2>&1 || { echo "Failed to generate key" >&2; exit 1; }
echo "[2/6] Creating CSR…"
"$OSSL" req -new -key "$KEY" -subj "/CN=$NAME/OU=Dev/O=LocalDev/C=US" -out "$CSR" >/dev/null 2>&1 || { echo "Failed to create CSR" >&2; exit 1; }
echo "[3/6] Self-signing certificate…"
"$OSSL" x509 -req -in "$CSR" -signkey "$KEY" -out "$CERT" -days "$DAYS" -extfile "$EXT" >/dev/null 2>&1 || { echo "Failed to self-sign cert" >&2; exit 1; }
[[ $VERBOSE -eq 1 ]] && "$OSSL" x509 -noout -text -in "$CERT" | grep -E 'Subject:|X509v3 Key Usage|X509v3 Extended Key Usage'

echo "[4/6] Creating PKCS#12 bundle…"
if ! "$OSSL" pkcs12 -export -inkey "$KEY" -in "$CERT" -name "$NAME" -out "$PKCS12" -passout pass:$P12_PASS >/dev/null 2>&1; then
  echo "Warning: PKCS#12 creation failed; will rely on raw import." >&2
  PKCS12=""
fi

import_success=0

attempt_import_pkcs12() {
  local f="$1"
  [[ -z "$f" || ! -f "$f" ]] && return 1
  echo "[5/6] Importing PKCS#12 (may prompt)…"
  if security import "$f" -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null; then
    return 0
  fi
  return 1
}

attempt_import_raw() {
  echo "[5/6] Importing raw private key…"
  if security import "$KEY" -k "$KEYCHAIN" -P "" -A -T /usr/bin/codesign 2>/dev/null; then
    echo "Raw key import ok"
  else
    echo "Raw key import failed; trying explicit formats…"
    security import "$KEY" -k "$KEYCHAIN" -t priv -f openssl -P "" -A -T /usr/bin/codesign 2>/dev/null || \
    security import "$KEY" -k "$KEYCHAIN" -t priv -f pemseq  -P "" -A -T /usr/bin/codesign 2>/dev/null || {
      echo "Converting key to PKCS#8…"
      "$OSSL" pkcs8 -topk8 -nocrypt -in "$KEY" -out "$PKCS8_KEY" >/dev/null 2>&1 || return 1
      security import "$PKCS8_KEY" -k "$KEYCHAIN" -P "" -A -T /usr/bin/codesign 2>/dev/null || return 1
    }
  fi
  echo "Importing certificate…"
  security import "$CERT" -k "$KEYCHAIN" -t cert -f x509 -A -T /usr/bin/codesign 2>/dev/null || \
  security import "$CERT" -k "$KEYCHAIN" -t cert -f pemseq -A -T /usr/bin/codesign 2>/dev/null || return 1
  return 0
}

if attempt_import_pkcs12 "$PKCS12"; then
  import_success=1
else
  echo "PKCS#12 import failed; attempting raw path…" >&2
  if attempt_import_raw; then
    import_success=1
  fi
fi

echo "[6/6] Setting trust (optional)…"
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$CERT" 2>/dev/null || true

if [[ $import_success -eq 1 ]] && security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Created code signing identity '$NAME'."
  echo "Build with: CODESIGN_ID=$NAME ./scripts/make_studio.sh"
  if [[ $VERBOSE -eq 1 ]]; then
    echo "Artifacts kept in $TMP_DIR (VERBOSE=1)"
  else
    rm -rf "$TMP_DIR"
  fi
  exit 0
else
  echo "Failed to create identity '$NAME'." >&2
  echo "Troubleshooting: unlock keychain: security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
  echo "If still failing, iCloud Keychain or SIP restrictions may interfere." >&2
  if [[ $VERBOSE -ne 1 ]]; then rm -rf "$TMP_DIR"; else echo "Left temp dir: $TMP_DIR"; fi
  exit 2
fi
