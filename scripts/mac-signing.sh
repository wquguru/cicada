#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dir="${CICADA_SIGNING:-$HOME/.cicada-signing}"
key_id="${NOTARY_KEY_ID:-KGZAJRYTXC}"
p8="$dir/AuthKey_$key_id.p8"
issuer="${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID: the Issuer ID on App Store Connect › Users and Access › Integrations}"

security find-identity -v -p codesigning | grep "Developer ID Application" ||
  { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
openssl x509 -inform DER -in "$dir/developer_id.cer" -noout -subject -enddate

base64 -i "$dir/developer_id.p12" | gh secret set MAC_CERT_P12_BASE64
gh secret set MAC_CERT_PASSWORD < "$dir/p12.password"
base64 -i "$p8" | gh secret set NOTARY_KEY_P8_BASE64
printf %s "$key_id" | gh secret set NOTARY_KEY_ID
printf %s "$issuer" | gh secret set NOTARY_ISSUER_ID
echo "set MAC_CERT_P12_BASE64 MAC_CERT_PASSWORD NOTARY_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID"
