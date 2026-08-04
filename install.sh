#!/bin/bash
#
# VLESS + Reality Installer for Ubuntu 24 (Amazon Lightsail or any VPS)
# Run as root: sudo bash install.sh
#

set -e

# ---------- Colors ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}   VLESS + Reality Auto Installer (Ubuntu 24)${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

# ---------- Must be root ----------
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root (use: sudo bash install.sh)${NC}"
  exit 1
fi

# ---------- Step 1: Update Ubuntu ----------
echo -e "${YELLOW}[1/7] Updating Ubuntu packages...${NC}"
apt update -y && apt upgrade -y
apt install -y curl wget unzip jq qrencode > /dev/null 2>&1
echo -e "${GREEN}System updated.${NC}"
echo ""

# ---------- Step 2: Ask for port ----------
read -p "Enter the port you want VLESS+Reality to run on [default: 443]: " USER_PORT
PORT=${USER_PORT:-443}
echo -e "${GREEN}Using port: $PORT${NC}"
echo ""

# ---------- Step 3: Ask for masking domain (SNI) ----------
echo "Reality needs a real website to disguise your traffic as (this site is never actually"
echo "proxied, it's just used for the TLS handshake fingerprint)."
read -p "Enter destination site [default: www.microsoft.com]: " USER_DEST
DEST=${USER_DEST:-www.microsoft.com}
SNI=$(echo "$DEST" | cut -d: -f1)
echo -e "${GREEN}Using masking site: $DEST (SNI: $SNI)${NC}"
echo ""

# ---------- Step 4: Install Xray-core ----------
echo -e "${YELLOW}[2/7] Installing Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
echo -e "${GREEN}Xray installed.${NC}"
echo ""

# ---------- Step 5: Generate UUID, keys, short ID ----------
echo -e "${YELLOW}[3/7] Generating UUID, key pair, and short ID...${NC}"
UUID=$(xray uuid)
KEY_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "Public" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
echo -e "${GREEN}UUID, keys, and short ID generated.${NC}"
echo ""

# ---------- Step 6: Write Xray config ----------
echo -e "${YELLOW}[4/7] Writing Xray configuration...${NC}"
mkdir -p /usr/local/etc/xray

cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

echo -e "${GREEN}Config written to $XRAY_CONFIG${NC}"
echo ""

# ---------- Step 7: Firewall ----------
echo -e "${YELLOW}[5/7] Opening port $PORT in firewall (if ufw is active)...${NC}"
if command -v ufw > /dev/null 2>&1; then
  ufw allow "$PORT"/tcp > /dev/null 2>&1 || true
fi
echo -e "${GREEN}Done. (Remember to also open port $PORT in your Lightsail networking tab!)${NC}"
echo ""

# ---------- Step 8: Start Xray ----------
echo -e "${YELLOW}[6/7] Starting Xray service...${NC}"
systemctl enable xray > /dev/null 2>&1
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
  echo -e "${GREEN}Xray is running.${NC}"
else
  echo -e "${RED}Xray failed to start. Check logs with: journalctl -u xray -e${NC}"
  exit 1
fi
echo ""

# ---------- Step 9: Get server public IP ----------
echo -e "${YELLOW}[7/7] Fetching server public IP...${NC}"
PUBLIC_IP=$(curl -s -4 https://api.ipify.org || curl -s -4 ifconfig.me)
echo -e "${GREEN}Public IP: $PUBLIC_IP${NC}"
echo ""

# ---------- Build client link ----------
VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality-${PUBLIC_IP}"

# ---------- Final summary ----------
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}          INSTALLATION COMPLETE!${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""
echo -e "${GREEN}Server IP     :${NC} $PUBLIC_IP"
echo -e "${GREEN}Port          :${NC} $PORT"
echo -e "${GREEN}UUID          :${NC} $UUID"
echo -e "${GREEN}Public Key    :${NC} $PUBLIC_KEY"
echo -e "${GREEN}Private Key   :${NC} $PRIVATE_KEY (keep this on server, don't share)"
echo -e "${GREEN}Short ID      :${NC} $SHORT_ID"
echo -e "${GREEN}SNI (masking) :${NC} $SNI"
echo -e "${GREEN}Flow          :${NC} xtls-rprx-vision"
echo -e "${GREEN}Network       :${NC} tcp"
echo ""
echo -e "${YELLOW}Client Import Link (copy this into v2rayNG, NekoBox, Streisand, etc):${NC}"
echo ""
echo "$VLESS_LINK"
echo ""

# Save to file for later reference
cat > /root/vless-client-info.txt <<EOF
Server IP     : $PUBLIC_IP
Port          : $PORT
UUID          : $UUID
Public Key    : $PUBLIC_KEY
Private Key   : $PRIVATE_KEY
Short ID      : $SHORT_ID
SNI           : $SNI
Flow          : xtls-rprx-vision
Network       : tcp

Client Link:
$VLESS_LINK
EOF

echo -e "${CYAN}This info was also saved to /root/vless-client-info.txt${NC}"
echo ""

# QR code if qrencode installed
if command -v qrencode > /dev/null 2>&1; then
  echo -e "${YELLOW}Scan this QR code with your client app:${NC}"
  qrencode -t ANSIUTF8 "$VLESS_LINK"
fi

echo ""
echo -e "${GREEN}All done. Enjoy!${NC}"
