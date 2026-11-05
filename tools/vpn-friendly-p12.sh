#!/usr/bin/env bash
# vpn-friendly-p12 — rebuild a RouterOS-exported PKCS#12 into a client-friendly one.
# RouterOS p12 contains leaf + CA (two certs); iOS rejects that for identity import,
# and Android shows a hex localKeyID instead of a readable name (no key-bag friendlyName).
# Output: exactly ONE cert + its key, friendlyName = <peer>, modern PBES2 (iOS/Android OK;
# for macOS Keychain import use vpn-import-mac / -legacy rebuild instead).
#
# Usage:
#   vpn-friendly-p12 <peer>            # fetch <peer>@<DOMAIN>.p12 from the router via scp
#   vpn-friendly-p12 --file <p12> [peer]   # rebuild a local p12 file (testing / WinBox-downloaded)
# <peer> may be given with the @<DOMAIN> suffix — it is stripped.
#
# Config: ~/.config/vpn-friendly-p12.conf (bash-sourceable, 0600):
#   VFP_ROUTER=203.0.113.10
#   VFP_SSHUSER=svcuser
#   VFP_SSHKEY=/path/to/key
#   VFP_DOMAIN=vpn.example.com
# No real hosts/domains belong in this public repo file — masked example only.

set -euo pipefail

CONF="$HOME/.config/vpn-friendly-p12.conf"
OUTDIR="$HOME/work/tools/officerouter/ios-p12"

die() { echo "vpn-friendly-p12: $*" >&2; exit 1; }

[[ -r "$CONF" ]] || die "config $CONF not found (see tools/vpn-friendly-p12.conf.example)"
# shellcheck disable=SC1090
source "$CONF"
: "${VFP_ROUTER:?}" "${VFP_SSHUSER:?}" "${VFP_SSHKEY:?}" "${VFP_DOMAIN:?}"
[[ -r "$VFP_SSHKEY" ]] || die "ssh key $VFP_SSHKEY not readable"

MODE=router; SRC=""; PEER=""
if [[ "${1:-}" == "--file" ]]; then
    MODE=file; SRC="${2:?--file requires a path}"; PEER="${3:-}"
    [[ -r "$SRC" ]] || die "cannot read $SRC"
    shift 2
else
    PEER="${1:?usage: vpn-friendly-p12 <peer> | --file <p12> [peer]}"
fi
# strip @domain suffix if present (fixed normalization, nothing else is derived)
SFX="@${VFP_DOMAIN}"
if [[ "$PEER" == *"$SFX" ]]; then PEER="${PEER%"$SFX"}"; fi
[[ -n "$PEER" ]] || die "empty peer name"
[[ "$PEER" == *"/"* || "$PEER" == *".."* ]] && die "bad peer name"

mkdir -p "$OUTDIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vfp.XXXXXX")"
chmod 700 "$TMP"
trap 'rm -P -f "$TMP"/key.pem "$TMP"/leaf.pem 2>/dev/null || rm -f "$TMP"/key.pem "$TMP"/leaf.pem; rm -f "$TMP"/src.p12; rmdir "$TMP" 2>/dev/null || true' EXIT

if [[ "$MODE" == router ]]; then
    SRC="$TMP/src.p12"
    REMOTE="/${PEER}@${VFP_DOMAIN}.p12"
    echo ">> fetching ${PEER}@${VFP_DOMAIN}.p12 from ${VFP_ROUTER}"
    scp -q -i "$VFP_SSHKEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
        -o ControlPath=none -o ConnectTimeout=15 \
        "${VFP_SSHUSER}@${VFP_ROUTER}:${REMOTE}" "$SRC" || die "scp failed (peer exists? p12 in Files?)"
else
    SRC="$SRC"
fi

read -rs -p "Passphrase of the source p12 (issuance): " SRC_PASS; echo
read -rs -p "New passphrase for the rebuilt p12: " OUT_PASS; echo
read -rs -p "Confirm new passphrase: " OUT_PASS2; echo
[[ "$OUT_PASS" == "$OUT_PASS2" ]] || die "passphrases differ"
[[ ${#OUT_PASS} -ge 8 ]] || die "passphrase must be >= 8 chars"

export SRC_PASS OUT_PASS
echo ">> extracting client key and leaf certificate (CA chain dropped)"
openssl pkcs12 -in "$SRC" -nocerts -nodes -passin env:SRC_PASS -out "$TMP/key.pem" 2>/dev/null \
    || die "cannot decrypt source p12 (wrong passphrase?)"
openssl pkcs12 -in "$SRC" -clcerts -nokeys -passin env:SRC_PASS -out "$TMP/leaf.pem" 2>/dev/null \
    || die "cannot extract leaf cert"

OUT="${OUTDIR}/${PEER}.ios.p12"
echo ">> rebuilding: 1 cert + 1 key, friendlyName='${PEER}'"
openssl pkcs12 -export -in "$TMP/leaf.pem" -inkey "$TMP/key.pem" -name "$PEER" \
    -passout env:OUT_PASS -out "$OUT" || die "rebuild failed"

# verification: exactly one cert, one key, readable name, dates
CERTS=$(grep -c -- "BEGIN CERTIFICATE" "$TMP/leaf.pem")
[[ "$CERTS" -eq 1 ]] || die "expected exactly 1 leaf cert, got $CERTS"
INFO=$(openssl pkcs12 -info -in "$OUT" -passin env:OUT_PASS -nokeys 2>/dev/null)
echo "$INFO" | grep -qi "friendlyName: ${PEER}$" || die "friendlyName missing in output"
SUBJ=$(openssl x509 -in "$TMP/leaf.pem" -noout -subject | sed 's/.*CN=//')
EXPIRY=$(openssl x509 -in "$TMP/leaf.pem" -noout -enddate | cut -d= -f2)
unset SRC_PASS OUT_PASS OUT_PASS2

echo ""
echo "OK: $OUT"
echo "     subject CN : $SUBJ"
echo "     expires    : $EXPIRY"
echo "     contents   : 1 certificate + 1 private key (no CA), PBES2 (iOS/Android OK)"
echo ""
echo "iPhone: AirDrop $OUT -> tap it in Files -> Settings: 'Profile Downloaded' -> Install"
echo "        (enter the NEW passphrase). Also install the CA profile (cert_export_CA...crt)"
echo "        separately, then pick this identity in the IKEv2 VPN config."
echo "Android: import $OUT as 'VPN & app user certificate'; the offered name is readable."
