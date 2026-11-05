#!/usr/bin/env bash
# vpn-ios-profile.sh — build an iOS .mobileconfig that carries CA + client
# identity + a ready IKEv2 VPN configuration in ONE profile.
#
# Why: the manual Settings UI certificate picker is unreliable (a half-imported
# identity stops being offered, "won't let me choose"). A configuration profile
# installs everything atomically and never touches the picker.
#
# Structure follows the Apple/strongSwan IKEv2 profile reference:
#   - com.apple.vpn.managed (IKEv2, AuthenticationMethod=Certificate,
#     PayloadCertificateUUID -> the pkcs12 payload; exactly ONE proposal each,
#     it must match the server)
#   - com.apple.security.pkcs12 (leaf-only, 3DES/PBES1 - Apple requirement;
#     no Password key: iOS prompts for the p12 passphrase at install)
#   - com.apple.security.root (the CA)
#
# Usage: vpn-ios-profile.sh <file.p12> <CA.crt> [server]
#   file.p12 — router export (leaf+CA) or an already repacked .ios.p12;
#              it is always re-exported leaf-only in 3DES/PBES1.
#   server   — VPN server FQDN; default: domain part of the leaf CN (after @).
# Asks (hidden): passphrase of the source p12. The SAME passphrase protects
# the identity inside the profile (iOS will ask for it during installation).
# Output: <peer>.mobileconfig next to the p12 (0600: contains the identity!).

set -euo pipefail
die() { echo "vpn-ios-profile: $*" >&2; exit 1; }

P12="${1:?usage: vpn-ios-profile.sh <file.p12> <CA.crt> [server]}"
CA="${2:?usage: vpn-ios-profile.sh <file.p12> <CA.crt> [server]}"
SERVER="${3:-}"
[[ -r "$P12" ]] || die "cannot read $P12"
[[ -r "$CA" ]] || die "cannot read $CA"
P12="$(cd "$(dirname "$P12")" && pwd)/$(basename "$P12")"
CA="$(cd "$(dirname "$CA")" && pwd)/$(basename "$CA")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vip.XXXXXX")"
chmod 700 "$TMP"
trap 'rm -f "$TMP"/key.pem "$TMP"/leaf.pem "$TMP"/id.p12 2>/dev/null; rm -P -f "$TMP"/key.pem 2>/dev/null || true; rmdir "$TMP" 2>/dev/null || true' EXIT

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
if printf '%s' "${CN}${SERVER}${CACN}" | grep -q '[&<>]'; then die "XML-unsafe characters in names"; fi
PEER_ID="$(printf '%s' "$PEER" | tr -d -c 'a-zA-Z0-9._-')"

# leaf-only 3DES/PBES1 re-export (Apple requirement; PBES2 half-imports)
P12ARGS=(-export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
         -in "$TMP/leaf.pem" -inkey "$TMP/key.pem" -name "$PEER" -passout env:PASS -out "$TMP/id.p12")
if ! openssl pkcs12 "${P12ARGS[@]}" -legacy 2>/dev/null; then
    /usr/bin/openssl pkcs12 "${P12ARGS[@]}" || die "3DES re-export failed"
fi
openssl asn1parse -inform DER -in "$TMP/id.p12" | grep -qi '060A2A864886F70D010C0103' \
    || die "identity p12 is not 3DES/PBES1 - Apple would reject the key"

U1="$(uuidgen)"; U2="$(uuidgen)"; U3="$(uuidgen)"; U4="$(uuidgen)"
OUT="$(dirname "$P12")/${PEER}.mobileconfig"
{
cat <<HDR
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadDisplayName</key>
	<string>IKEv2 VPN ${PEER}</string>
	<key>PayloadDescription</key>
	<string>CA, client identity and IKEv2 VPN configuration</string>
	<key>PayloadIdentifier</key>
	<string>local.iosvpn.${PEER_ID}</string>
	<key>PayloadUUID</key>
	<string>${U1}</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadIdentifier</key>
			<string>local.iosvpn.${PEER_ID}.vpn</string>
			<key>PayloadUUID</key>
			<string>${U2}</string>
			<key>PayloadType</key>
			<string>com.apple.vpn.managed</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>UserDefinedName</key>
			<string>Office VPN (${PEER})</string>
			<key>VPNType</key>
			<string>IKEv2</string>
			<key>IKEv2</key>
			<dict>
				<key>RemoteAddress</key>
				<string>${SERVER}</string>
				<key>RemoteIdentifier</key>
				<string>${SERVER}</string>
				<key>LocalIdentifier</key>
				<string>${CN}</string>
				<key>ServerCertificateIssuerCommonName</key>
				<string>${CACN}</string>
				<key>ServerCertificateCommonName</key>
				<string>${SERVER}</string>
				<key>AuthenticationMethod</key>
				<string>Certificate</string>
				<key>PayloadCertificateUUID</key>
				<string>${U3}</string>
				<key>IKESecurityAssociationParameters</key>
				<dict>
					<key>EncryptionAlgorithm</key>
					<string>AES-256</string>
					<key>IntegrityAlgorithm</key>
					<string>SHA2-256</string>
					<key>DiffieHellmanGroup</key>
					<integer>14</integer>
				</dict>
				<key>ChildSecurityAssociationParameters</key>
				<dict>
					<key>EncryptionAlgorithm</key>
					<string>AES-256</string>
					<key>IntegrityAlgorithm</key>
					<string>SHA2-256</string>
				</dict>
			</dict>
		</dict>
		<dict>
			<key>PayloadIdentifier</key>
			<string>local.iosvpn.${PEER_ID}.identity</string>
			<key>PayloadUUID</key>
			<string>${U3}</string>
			<key>PayloadType</key>
			<string>com.apple.security.pkcs12</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadContent</key>
			<data>
$(base64 < "$TMP/id.p12")
			</data>
		</dict>
		<dict>
			<key>PayloadIdentifier</key>
			<string>local.iosvpn.${PEER_ID}.ca</string>
			<key>PayloadUUID</key>
			<string>${U4}</string>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadContent</key>
			<data>
$(openssl x509 -in "$CA" -outform DER | base64)
			</data>
		</dict>
	</array>
</dict>
</plist>
HDR
} > "$OUT"
chmod 600 "$OUT"
unset PASS
plutil -lint "$OUT" >/dev/null || die "generated plist failed validation"

echo ""
echo "OK: $OUT"
echo "    VPN  : ${SERVER} (IKEv2, certificate auth, AES-256/SHA2-256/modp2048)"
echo "    Peer : ${CN} (3DES/PBES1 identity, no password embedded)"
echo "    CA   : ${CACN}"
echo "iPhone: delete the manual VPN config and old CA/identity profiles first,"
echo "       then AirDrop the .mobileconfig -> Settings > 'Profile Downloaded' > Install"
echo "       (iOS asks for the p12 passphrase) -> Settings > VPN -> toggle ON."
echo "       Delete the .mobileconfig from the Mac afterwards (it holds the identity)."
