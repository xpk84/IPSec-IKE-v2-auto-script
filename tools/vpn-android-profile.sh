#!/usr/bin/env bash
# vpn-android-profile.sh — build a .sswan VPN profile for the strongSwan
# Android client (https://docs.strongswan.org/ androidVpnClientProfiles).
#
# Why: Android's built-in VPN client has NO profile import at all (certs only);
# the strongSwan app eats a self-contained .sswan JSON that carries the client
# identity (PKCS#12, imported into the app's own keystore, NOT the system one),
# the CA pin for the server, identities and exactly matching IKE/ESP proposals.
# One file + the p12 passphrase at import — the Android analog of the iOS
# .mobileconfig from vpn-ios-profile.sh.
#
# Usage: vpn-android-profile.sh <file.p12> <CA.crt> [server]
#   file.p12 — router export (leaf+CA) or an already repacked .ios.p12;
#              always re-exported leaf-only in 3DES/PBES1 with a readable name.
#   server   — VPN server FQDN; default: domain part of the leaf CN (after @).
# Asks (hidden): passphrase of the source p12. The SAME passphrase protects
# the identity embedded in the profile (strongSwan asks for it at import).
# Output: <peer>.sswan next to the p12 (0600: contains the identity!).

set -euo pipefail
die() { echo "vpn-android-profile: $*" >&2; exit 1; }

P12="${1:?usage: vpn-android-profile.sh <file.p12> <CA.crt> [server]}"
CA="${2:?usage: vpn-android-profile.sh <file.p12> <CA.crt> [server]}"
SERVER="${3:-}"
[[ -r "$P12" ]] || die "cannot read $P12"
[[ -r "$CA" ]] || die "cannot read $CA"
P12="$(cd "$(dirname "$P12")" && pwd)/$(basename "$P12")"
CA="$(cd "$(dirname "$CA")" && pwd)/$(basename "$CA")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vap.XXXXXX")"
chmod 700 "$TMP"
trap 'rm -f "$TMP"/key.pem "$TMP"/leaf.pem "$TMP"/id.p12 "$TMP"/ca.der; rm -P -f "$TMP"/key.pem 2>/dev/null || true; rmdir "$TMP" 2>/dev/null || true' EXIT

read -rs -p "Passphrase of the source p12: " PASS; echo
export PASS
openssl pkcs12 -in "$P12" -nocerts -nodes -passin env:PASS -out "$TMP/key.pem" 2>/dev/null \
    || die "cannot decrypt source p12 (wrong passphrase?)"
openssl pkcs12 -in "$P12" -clcerts -nokeys -passin env:PASS -out "$TMP/leaf.pem" 2>/dev/null \
    || die "cannot extract leaf certificate"
[[ "$(grep -c -- 'BEGIN CERTIFICATE' "$TMP/leaf.pem")" -eq 1 ]] || die "expected exactly 1 leaf cert"

CN="$(openssl x509 -in "$TMP/leaf.pem" -noout -subject -nameopt multiline,utf8 \
      | sed -n 's/ *commonName *= *//p' | head -1)"
[[ -n "$CN" ]] || die "cannot read CN from leaf certificate"
PEER="${CN%%@*}"
DOMAIN="${CN##*@}"
[[ "$CN" == *"@"* ]] || die "leaf CN '$CN' has no @domain - pass the server as 3rd argument"
SERVER="${SERVER:-$DOMAIN}"
CACN="$(openssl x509 -in "$CA" -noout -subject -nameopt multiline,utf8 \
        | sed -n 's/ *commonName *= *//p' | head -1)"
[[ -n "$CACN" ]] || die "cannot read CN from CA certificate"
if printf '%s' "${CN}${SERVER}${CACN}" | grep -q '[&<>"]'; then die "unsafe characters in names"; fi

# leaf-only 3DES/PBES1 re-export (uniform with the iOS helper; strongSwan
# would also eat PBES2, but one canonical client artifact per peer is simpler)
P12ARGS=(-export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
         -in "$TMP/leaf.pem" -inkey "$TMP/key.pem" -name "$PEER" -passout env:PASS -out "$TMP/id.p12")
if ! openssl pkcs12 "${P12ARGS[@]}" -legacy 2>/dev/null; then
    /usr/bin/openssl pkcs12 "${P12ARGS[@]}" || die "3DES re-export failed"
fi
openssl asn1parse -inform DER -in "$TMP/id.p12" | grep -qi '060A2A864886F70D010C0103' \
    || die "identity p12 is not 3DES/PBES1"
openssl x509 -in "$CA" -outform DER -out "$TMP/ca.der" || die "cannot encode CA as DER"

UUID="$(uuidgen)"
OUT="$(dirname "$P12")/${PEER}.sswan"
export OUT CN SERVER UUID
python3 - "$TMP/id.p12" "$TMP/ca.der" <<'PY' || die "failed to assemble the profile"
import base64, json, os, sys
p12_b64 = base64.b64encode(open(sys.argv[1], 'rb').read()).decode()
ca_b64  = base64.b64encode(open(sys.argv[2], 'rb').read()).decode()
profile = {
    "uuid": os.environ["UUID"],
    "name": f"Office VPN ({os.environ['CN'].split('@')[0]})",
    "type": "ikev2-cert",
    "remote": {
        "addr": os.environ["SERVER"],
        "id":   os.environ["SERVER"],
        "cert": ca_b64,
    },
    "local": {
        "id":  os.environ["CN"],
        "p12": p12_b64,
    },
    # exactly one proposal each, matching the server's profile/proposal:
    # IKE aes-256/sha-256/modp2048; ESP aes-256/sha-256 WITHOUT DH (pfs=none)
    "ike-proposal": "aes256-sha256-modp2048",
    "esp-proposal": "aes256-sha256",
}
with open(os.environ["OUT"], "w") as f:
    json.dump(profile, f, indent=2)
    f.write("\n")
os.chmod(os.environ["OUT"], 0o600)
# self-check: valid JSON, decodable blobs
chk = json.load(open(os.environ["OUT"]))
assert base64.b64decode(chk["local"]["p12"], validate=True)
assert base64.b64decode(chk["remote"]["cert"], validate=True)
assert chk["type"] == "ikev2-cert"
PY
unset PASS

echo ""
echo "OK: $OUT"
echo "    VPN  : ${SERVER} (IKEv2, certificate auth, aes256-sha256-modp2048)"
echo "    Peer : ${CN} (3DES identity embedded, no password in the file)"
echo "    CA   : ${CACN} (pinned via remote.cert)"
echo "Android: install the strongSwan app (Google Play, free) first, then open"
echo "       the .sswan file with it (or strongSwan -> ADD > Import VPN profile),"
echo "       enter the p12 passphrase at import. The identity lives in the app,"
echo "       not the system keystore. Delete the .sswan afterwards (holds the identity)."
