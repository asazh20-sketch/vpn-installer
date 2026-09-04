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

# ---------- Ask for DuckDNS domain and token ----------
read -p "Enter your DuckDNS domain (just the subdomain, e.g. 'myserver' for myserver.duckdns.org): " DUCKDNS_DOMAIN
read -p "Enter your DuckDNS Token: " DUCKDNS_TOKEN

if [ -z "$DUCKDNS_DOMAIN" ] || [ -z "$DUCKDNS_TOKEN" ]; then
  echo -e "${RED}DuckDNS domain and token are both required. Exiting.${NC}"
  exit 1
fi

echo -e "${GREEN}Using DuckDNS domain: ${DUCKDNS_DOMAIN}.duckdns.org${NC}"
echo ""

# ---------- Step 1: Update Ubuntu ----------
echo -e "${YELLOW}[1/6] Updating Ubuntu packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y -o Dpkg::Options::="--force-confold"
apt install -y curl wget unzip jq > /dev/null 2>&1
echo -e "${GREEN}System updated.${NC}"
echo ""

# ---------- Enable BBR congestion control ----------
echo -e "${YELLOW}Enabling BBR congestion control...${NC}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p > /dev/null 2>&1

CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
if [ "$CURRENT_CC" = "bbr" ]; then
  echo -e "${GREEN}BBR is active.${NC}"
else
  echo -e "${YELLOW}BBR did not activate (current: $CURRENT_CC). This won't stop the install, but throughput may be lower than optimal.${NC}"
fi
echo ""

# ---------- Step 2: Fixed port and masking site (no prompts) ----------
PORT=443
DEST="www.microsoft.com:443"
SNI=$(echo "$DEST" | cut -d: -f1)
echo -e "${GREEN}Using port: $PORT${NC}"
echo -e "${GREEN}Using masking site: $DEST (SNI: $SNI)${NC}"
echo ""

# ---------- Step 4: Install Xray-core ----------
echo -e "${YELLOW}[2/6] Installing Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
echo -e "${GREEN}Xray installed.${NC}"
echo ""

# ---------- Step 5: Generate UUID, keys, short ID ----------
echo -e "${YELLOW}[3/6] Generating UUID, key pair, and short ID...${NC}"
UUID=$(xray uuid)
KEY_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "Public" | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  echo -e "${RED}Failed to generate keys. 'xray x25519' output format may have changed.${NC}"
  echo -e "${RED}Raw output was:${NC}"
  echo "$KEY_OUTPUT"
  exit 1
fi

echo -e "${GREEN}UUID, keys, and short ID generated.${NC}"
echo ""

# ---------- Step 6: Write Xray config ----------
echo -e "${YELLOW}[4/6] Writing Xray configuration...${NC}"
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
echo -e "${YELLOW}[5/6] Opening port $PORT in firewall (if ufw is active)...${NC}"
if command -v ufw > /dev/null 2>&1; then
  ufw allow "$PORT"/tcp > /dev/null 2>&1 || true
fi
echo -e "${GREEN}Done. (Remember to also open port $PORT in your Lightsail networking tab!)${NC}"
echo ""

# ---------- Step 8: Start Xray ----------
# ---------- Step 8: Start Xray ----------
echo -e "${YELLOW}[6/6] Starting Xray service...${NC}"

# Make Xray auto-restart if it ever crashes
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/restart-on-failure.conf <<EOF
[Service]
Restart=on-failure
RestartSec=5s
EOF
systemctl daemon-reload

systemctl enable xray > /dev/null 2>&1
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
  echo -e "${GREEN}Xray is running (auto-restart enabled if it ever crashes).${NC}"
else
  echo -e "${RED}Xray failed to start. Check logs with: journalctl -u xray -e${NC}"
  exit 1
fi
echo ""

# ---------- Step 9: Get server public IP ----------
PUBLIC_IP=$(curl -s -4 https://api.ipify.org || curl -s -4 ifconfig.me)
echo -e "${GREEN}Public IP: $PUBLIC_IP${NC}"
echo ""

# ---------- Step 10: Set up DuckDNS ----------
echo -e "${YELLOW}Updating DuckDNS record...${NC}"
mkdir -p /etc/duckdns
cat > /etc/duckdns/duck.sh <<EOF
#!/bin/bash
curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" > /etc/duckdns/duck.log 2>&1
EOF
chmod +x /etc/duckdns/duck.sh
/etc/duckdns/duck.sh

DUCKDNS_RESULT=$(cat /etc/duckdns/duck.log)
if [ "$DUCKDNS_RESULT" != "OK" ]; then
  echo -e "${RED}DuckDNS update failed. Response: $DUCKDNS_RESULT${NC}"
  echo -e "${RED}Double check your domain and token are correct.${NC}"
  exit 1
fi

# ---------- Step 11: Boot-time DuckDNS retry script ----------
# On every boot: wait 20s for networking, then retry the update every 5s, up to 10 attempts.
cat > /etc/duckdns/duck-boot.sh <<'EOF'
#!/bin/bash
LOGFILE="/etc/duckdns/duck-boot.log"
sleep 20

for i in $(seq 1 10); do
  /etc/duckdns/duck.sh
  RESULT=$(cat /etc/duckdns/duck.log)
  if [ "$RESULT" = "OK" ]; then
    echo "$(date): DuckDNS updated successfully on attempt $i" >> "$LOGFILE"
    exit 0
  fi
  echo "$(date): Attempt $i failed (response: $RESULT), retrying in 5s..." >> "$LOGFILE"
  sleep 5
done

echo "$(date): DuckDNS update failed after 10 attempts" >> "$LOGFILE"
exit 1
EOF
chmod +x /etc/duckdns/duck-boot.sh

# systemd service to run the boot script once networking is up
cat > /etc/systemd/system/duckdns-boot.service <<EOF
[Unit]
Description=DuckDNS IP update on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/duckdns/duck-boot.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable duckdns-boot.service > /dev/null 2>&1

# Ongoing check once the server has been up for a while: every 1 hour
( crontab -l 2>/dev/null | grep -v duck.sh ; echo "0 * * * * /etc/duckdns/duck.sh >/dev/null 2>&1" ) | crontab -

SERVER_ADDRESS="${DUCKDNS_DOMAIN}.duckdns.org"
echo -e "${GREEN}DuckDNS domain is live: $SERVER_ADDRESS${NC}"
echo -e "${GREEN}On every reboot: waits 20s, then retries every 5s (up to 10 tries) until it updates.${NC}"
echo -e "${GREEN}Ongoing check: every 1 hour.${NC}"
echo ""

# ---------- Build client link ----------
VLESS_LINK="vless://${UUID}@${SERVER_ADDRESS}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality-${SERVER_ADDRESS}"

# ---------- Final summary ----------
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}          INSTALLATION COMPLETE!${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""
echo -e "${GREEN}Server IP     :${NC} $PUBLIC_IP"
echo -e "${GREEN}DuckDNS       :${NC} $SERVER_ADDRESS"
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
DuckDNS       : $SERVER_ADDRESS
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

cat /root/vless-client-info.txt
echo ""
echo -e "${GREEN}All done. Enjoy!${NC}"
echo ""
echo -e "${YELLOW}The server will reboot in 15 seconds to make sure all system and kernel updates take effect.${NC}"
echo -e "${YELLOW}Your client info above is also saved in /root/vless-client-info.txt, so you can check it again after reboot.${NC}"
sleep 15
reboot
