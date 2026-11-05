#!/usr/bin/env bash
# vpn-cert-for-ios.sh — repack a RouterOS-exported PKCS#12 for iOS import.
# RouterOS puts leaf + CA (two certs) into one p12; iOS rejects that for an identity
# profile («...только один сертификат и его уникальный ключ»), Android shows a hex name.
# Output: exactly ONE cert + its key, friendlyName = file name (readable), PBES2.
#
# Usage: vpn-cert-for-ios.sh <file.p12>
# Asks (hidden): passphrase of the source p12, then a new passphrase (>= 8 chars) twice.

set -euo pipefail
die() { echo "vpn-cert-for-ios: $*" >&2; exit 1; }

SRC="${1:?usage: vpn-cert-for-ios.sh <file.p12>}"
[[ -r "$SRC" ]] || die "cannot read $SRC"
SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"   # absolute, same-dir output

PEER="$(basename "$SRC" .p12)"
PEER="${PEER%%@*}"                                          # strip @domain label if present
[[ -n "$PEER" ]] || die "cannot derive a name from file name"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vci.XXXXXX")"
chmod 700 "$TMP"
trap 'rm -P -f "$TMP"/key.pem "$TMP"/leaf.pem 2>/dev/null || rm -f "$TMP"/key.pem "$TMP"/leaf.pem; rmdir "$TMP" 2>/dev/null || true' EXIT

read -rs -p "Passphrase of the source p12: " SRC_PASS; echo
read -rs -p "New passphrase for iOS: " OUT_PASS; echo
read -rs -p "Confirm new passphrase: " OUT_PASS2; echo
[[ "$OUT_PASS" == "$OUT_PASS2" ]] || die "passphrases differ"
[[ ${#OUT_PASS} -ge 8 ]] || die "passphrase must be >= 8 chars"
export SRC_PASS OUT_PASS

openssl pkcs12 -in "$SRC" -nocerts -nodes -passin env:SRC_PASS -out "$TMP/key.pem" 2>/dev/null \
    || die "cannot decrypt source p12 (wrong passphrase?)"
openssl pkcs12 -in "$SRC" -clcerts -nokeys -passin env:SRC_PASS -out "$TMP/leaf.pem" 2>/dev/null \
    || die "cannot extract leaf certificate"
[[ "$(grep -c -- 'BEGIN CERTIFICATE' "$TMP/leaf.pem")" -eq 1 ]] || die "expected exactly 1 leaf cert"

OUT="$(dirname "$SRC")/${PEER}.ios.p12"
openssl pkcs12 -export -in "$TMP/leaf.pem" -inkey "$TMP/key.pem" -name "$PEER" \
    -passout env:OUT_PASS -out "$OUT" || die "rebuild failed"
openssl pkcs12 -info -in "$OUT" -passin env:OUT_PASS -nokeys 2>/dev/null | grep -qi "friendlyName: ${PEER}$" \
    || die "verification failed"
unset SRC_PASS OUT_PASS OUT_PASS2

SUBJ=$(openssl x509 -in "$TMP/leaf.pem" -noout -subject | sed 's/.*CN=//')
EXPIRY=$(openssl x509 -in "$TMP/leaf.pem" -noout -enddate | cut -d= -f2)
echo ""
echo "OK: $OUT"
echo "     CN: $SUBJ | expires: $EXPIRY"
echo "     1 certificate + 1 key (CA dropped), name: ${PEER}"
echo "iPhone: AirDrop -> tap in Files -> Settings > 'Profile Downloaded' > Install (NEW passphrase)."
echo "        Install the CA profile separately, then pick this identity in the IKEv2 VPN config."
