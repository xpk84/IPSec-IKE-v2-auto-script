#!/bin/bash
# vpn-import-mac — импорт клиентского IKEv2 p12 (RouterOS 7.7+) в macOS System keychain.
#
# Зачем: RouterOS 7.7+ упаковывает приватный ключ в PKCS#12 как PBES2/AES-256,
# а Keychain Access / `security import` молча выбрасывают такой ключ (пароль при
# этом "принимается"): импортируется сертификат без ключа — identity не создаётся,
# Machine Certificate не выбирается. Скрипт пересобирает p12 в legacy-3DES,
# чистит безключевые дубли и ставит identity в System keychain.
#
# Usage:   vpn-import-mac <peer-name> [path-to-p12]
# Пример:  vpn-import-mac ike2_alice_mobile_2026
#
# Конфиг:  ~/.config/vpn-import-mac.conf (см. vpn-import-mac.conf.example):
#          VPN_IMPORT_SSH      user@router      — для автоскачивания p12 (scp)
#          VPN_IMPORT_DOMAIN   vpn.example.com  — суффикс имени сертификата
#          VPN_IMPORT_KEY      путь-к-ssh-ключу (необязательно)
#          VPN_IMPORT_WORKDIR  рабочая папка    (по умолчанию ~/.cache/vpn-import)
#
# Спрашивает: 1) пароль p12 (read -s, не в историю/argv), 2) пароль macOS (sudo),
#             3) ещё раз пароль p12 (диалог security import).
set -euo pipefail

PEER="${1:?usage: vpn-import-mac <peer-name> [p12-file]}"
CONF="${VPN_IMPORT_CONF:-$HOME/.config/vpn-import-mac.conf}"
[ -f "$CONF" ] && . "$CONF"
HOST="${VPN_IMPORT_DOMAIN:?задайте VPN_IMPORT_DOMAIN в $CONF}"
RTR="${VPN_IMPORT_SSH:?задайте VPN_IMPORT_SSH в $CONF}"
KEY="${VPN_IMPORT_KEY:-}"
WORK="${VPN_IMPORT_WORKDIR:-$HOME/.cache/vpn-import}"
CERT="${PEER}@${HOST}"

SCP_OPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15)
[ -n "$KEY" ] && SCP_OPTS+=(-i "$KEY")

mkdir -p "$WORK"; cd "$WORK"

# --- 1. Где взять p12: аргумент или скачать с роутера ---
if [ -n "${2:-}" ]; then
  SRC="$2"
else
  SRC="${CERT}.p12"
  if [ ! -f "$SRC" ]; then
    echo ">> качаю ${SRC} с роутера..."
    scp "${SCP_OPTS[@]}" "${RTR}:${SRC}" .
  fi
fi
[ -f "$SRC" ] || { echo "!! файл ${SRC} не найден"; exit 1; }

# --- 2. Пароль (не попадает ни в argv, ни в историю) ---
read -rsp "Пароль p12 для ${PEER}: " PW; echo
export PW
trap 'unset PW; rm -f "$WORK/tmp_bundle.pem"' EXIT

# --- 3. Распаковка + проверка, что ключ внутри есть ---
if ! openssl pkcs12 -in "$SRC" -passin env:PW -out tmp_bundle.pem -nodes 2>/dev/null; then
  echo "!! не расшифровывается — неверный пароль или битый файл"; exit 1
fi
grep -q "PRIVATE KEY" tmp_bundle.pem || { echo "!! в p12 нет приватного ключа (баг экспорта?)"; exit 1; }
echo ">> ключ в p12 найден, пересобираю в legacy-формат (3DES)..."

# --- 4. Пересборка: macOS-совместимый p12 ---
if ! openssl pkcs12 -export -in tmp_bundle.pem -inkey tmp_bundle.pem -name "$CERT" \
     -passout env:PW -out "${PEER}.legacy.p12" -legacy 2>/dev/null; then
  openssl pkcs12 -export -in tmp_bundle.pem -inkey tmp_bundle.pem -name "$CERT" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout env:PW -out "${PEER}.legacy.p12"
fi
rm -f tmp_bundle.pem

# --- 5. Чистим безключевые дубли этого серта (login и System) ---
sudo security delete-certificate -c "$CERT" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
sudo security delete-certificate -c "$CERT" /Library/Keychains/System.keychain 2>/dev/null || true

# --- 6. Импорт identity в System keychain (-A: VPN-демон получает доступ к ключу без GUI-промптов) ---
echo ">> security спросит пароль от p12 ещё раз (это тот же пароль)"
sudo security import "${PEER}.legacy.p12" -k /Library/Keychains/System.keychain -A

# --- 7. Верификация ---
if security find-identity -v /Library/Keychains/System.keychain | grep -q "$CERT"; then
  echo "✅ identity ${CERT} в System keychain — выбирайте её как Machine Certificate"
  rm -f "${PEER}.legacy.p12"
else
  echo "⚠️ сертификат импортирован, но identity не видна — гляньте Keychain Access вручную"
fi
unset PW
