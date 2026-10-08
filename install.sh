#!/bin/bash
set -euo pipefail

SNI="www.nvidia.com"
PORT=443
XHTTP_PATH="/xhttp-stream"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
ACCESS_FILE="/etc/xray/access_info.txt"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget jq uuid-runtime openssl ca-certificates

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
[[ -x "$XRAY_BIN" ]] || { echo "xray not found"; exit 1; }

UUID=$(uuidgen)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -iE 'PrivateKey|Private key' | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | grep -iE 'Password|PublicKey|Public key' | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)
SERVER_IP=$(curl -4 -s --max-time 5 icanhazip.com || curl -4 -s --max-time 5 ifconfig.me)

[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$UUID" ]] || { echo "keygen failed"; exit 1; }

mkdir -p /usr/local/etc/xray /etc/xray

cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none",
        "fallbacks": [{ "path": "$XHTTP_PATH", "dest": "@xhttp-in", "xver": 0 }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    },
    {
      "listen": "@xhttp-in",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "host": "$SNI",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

cat > "$ACCESS_FILE" <<EOF
SNI: $SNI
UUID: $UUID
PrivateKey: $PRIVATE_KEY
PublicKey: $PUBLIC_KEY
ShortID: $SHORT_ID
ServerIP: $SERVER_IP
Port: $PORT
XHTTP_PATH: $XHTTP_PATH
EOF
chmod 600 "$ACCESS_FILE"

systemctl enable xray
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager; exit 1; }

echo
echo "Vision:"
echo "vless://\( {UUID}@ \){SERVER_IP}:\( {PORT}?security=reality&encryption=none&pbk= \){PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=\( {SNI}&sid= \){SHORT_ID}&spx=%2F#Vision-NVIDIA"
echo
echo "XHTTP (в клиенте включить xmux/h2mux):"
echo "vless://\( {UUID}@ \){SERVER_IP}:\( {PORT}?security=reality&encryption=none&pbk= \){PUBLIC_KEY}&headerType=none&fp=chrome&type=xhttp&path=\( {XHTTP_PATH}&host= \){SNI}&sni=\( {SNI}&sid= \){SHORT_ID}#XHTTP-NVIDIA"
echo
echo "Доступы: $ACCESS_FILE"
