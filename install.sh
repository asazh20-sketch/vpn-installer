#!/bin/bash
# Multi-Protocol VPN Installer for Ubuntu 24 (Amazon Lightsail or any VPS)
# Installs automatically: VLESS+Reality (TCP) -> VLESS+Reality+XHTTP -> Trojan (TLS) -> Hysteria2
# WARP is the only optional step (Y/N).

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo).${NC}"
    exit 1
fi

retry() {
    local max_attempts="$1"; shift
    local delay="$1"; shift
    local attempt=1
    until "$@"; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo -e "${RED}Command failed after $attempt attempts: $*${NC}"
            return 1
        fi
        echo -e "${YELLOW}Attempt $attempt failed. Retrying in ${delay}s...${NC}"
        attempt=$((attempt + 1))
        sleep "$delay"
    done
}

echo -e "${CYAN}=== DuckDNS Setup ===${NC}"
read -r -p "Enter your DuckDNS domain (without .duckdns.org): " DUCKDNS_DOMAIN
read -r -p "Enter your DuckDNS token: " DUCKDNS_TOKEN
SERVER_ADDRESS="${DUCKDNS_DOMAIN}.duckdns.org"

echo -e "${CYAN}=== Updating system ===${NC}"
export DEBIAN_FRONTEND=noninteractive
retry 5 5 apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confold"
apt-get install -y curl wget jq openssl certbot ufw

echo -e "${CYAN}=== Enabling BBR ===${NC}"
cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p >/dev/null 2>&1 || true

echo -e "${CYAN}=== Installing Xray-core ===${NC}"
retry 5 5 bash -c "bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)"

mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/restart-on-failure.conf <<EOF
[Service]
Restart=on-failure
RestartSec=5s
EOF
systemctl daemon-reload

wait_for_xray() {
    local i=0
    while [ $i -lt 15 ]; do
        if systemctl is-active --quiet xray; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

#######################################
# [1/4] VLESS + REALITY (TCP, port 443)
#######################################
echo -e "${CYAN}=== [1/4] Installing VLESS + Reality (TCP) ===${NC}"

PORT=443
DEST="www.apple.com:443"
SNI="www.apple.com"

UUID=$(xray uuid)
KEY_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "Public" | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}Failed to generate Reality keys. Aborting.${NC}"
    exit 1
fi

mkdir -p /usr/local/etc/xray
cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": [ "$SNI" ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [ "$SHORT_ID" ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

systemctl enable xray >/dev/null 2>&1
systemctl restart xray
if ! wait_for_xray; then
    echo -e "${RED}Xray failed to start. Check: journalctl -u xray -e${NC}"
    exit 1
fi

PUBLIC_IP=$(curl -s -4 https://api.ipify.org || curl -s -4 https://ifconfig.me)

VLESS_LINK="vless://${UUID}@${SERVER_ADDRESS}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality-${SERVER_ADDRESS}"

cat > /root/vless-client-info.txt <<EOF
=== VLESS + Reality (TCP, port $PORT) ===
$VLESS_LINK
EOF

#################################################
# [2/4] VLESS + REALITY + XHTTP (port 8443)
#################################################
echo -e "${CYAN}=== [2/4] Installing VLESS + Reality + XHTTP ===${NC}"

XHTTP_PORT=8443
XHTTP_UUID=$(xray uuid)
XHTTP_PATH="/xhttp-api"

cp "$XRAY_CONFIG" "${XRAY_CONFIG}.before-xhttp"

jq --arg uuid "$XHTTP_UUID" \
   --arg dest "$DEST" \
   --arg sni "$SNI" \
   --arg pk "$PRIVATE_KEY" \
   --arg sid "$SHORT_ID" \
   --arg path "$XHTTP_PATH" \
   --argjson port "$XHTTP_PORT" \
   '.inbounds += [{
      "tag": "vless-xhttp-in",
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": $uuid } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": { "path": $path, "mode": "auto" },
        "realitySettings": {
          "show": false,
          "dest": $dest,
          "xver": 0,
          "serverNames": [ $sni ],
          "privateKey": $pk,
          "shortIds": [ $sid ]
        }
      }
    }]' "$XRAY_CONFIG" > /tmp/xray-config-xhttp.json && mv /tmp/xray-config-xhttp.json "$XRAY_CONFIG"

ufw allow "$XHTTP_PORT"/tcp >/dev/null 2>&1 || true

if xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    systemctl restart xray
    if ! wait_for_xray; then
        echo -e "${RED}Xray failed to start after XHTTP install. Rolling back.${NC}"
        cp "${XRAY_CONFIG}.before-xhttp" "$XRAY_CONFIG"
        systemctl restart xray
        wait_for_xray || true
    else
        XHTTP_LINK="vless://${XHTTP_UUID}@${SERVER_ADDRESS}:${XHTTP_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}&mode=auto#VLESS-XHTTP-${SERVER_ADDRESS}"
        cat >> /root/vless-client-info.txt <<EOF

=== VLESS + Reality + XHTTP (port $XHTTP_PORT) ===
$XHTTP_LINK
EOF
    fi
else
    echo -e "${RED}XHTTP config validation failed. Skipping XHTTP install.${NC}"
    cp "${XRAY_CONFIG}.before-xhttp" "$XRAY_CONFIG"
fi

#######################################################
# Shared Let's Encrypt certificate (for Trojan + Hysteria2)
#######################################################
echo -e "${CYAN}=== Obtaining TLS certificate for Trojan / Hysteria2 ===${NC}"

ufw allow 80/tcp >/dev/null 2>&1 || true

if [ ! -d "/etc/letsencrypt/live/${SERVER_ADDRESS}" ]; then
    retry 3 10 certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$SERVER_ADDRESS" || true
fi

CERT_OK=0
if [ -f "/etc/letsencrypt/live/${SERVER_ADDRESS}/fullchain.pem" ] && \
   [ -f "/etc/letsencrypt/live/${SERVER_ADDRESS}/privkey.pem" ]; then
    CERT_OK=1
fi

#######################################
# [3/4] TROJAN (TLS, port 2096)
#######################################
if [ "$CERT_OK" -eq 1 ]; then
    echo -e "${CYAN}=== [3/4] Installing Trojan (TLS) ===${NC}"

    TROJAN_PORT=2096
    TROJAN_PASSWORD=$(openssl rand -hex 16)
    CERT_FILE="/etc/letsencrypt/live/${SERVER_ADDRESS}/fullchain.pem"
    KEY_FILE="/etc/letsencrypt/live/${SERVER_ADDRESS}/privkey.pem"

    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.before-trojan"

    jq --arg password "$TROJAN_PASSWORD" \
       --arg cert "$CERT_FILE" \
       --arg key "$KEY_FILE" \
       --argjson port "$TROJAN_PORT" \
       '.inbounds += [{
          "tag": "trojan-in",
          "listen": "0.0.0.0",
          "port": $port,
          "protocol": "trojan",
          "settings": {
            "clients": [ { "password": $password } ]
          },
          "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
              "certificates": [ { "certificateFile": $cert, "keyFile": $key } ]
            }
          }
        }]' "$XRAY_CONFIG" > /tmp/xray-config-trojan.json && mv /tmp/xray-config-trojan.json "$XRAY_CONFIG"

    ufw allow "$TROJAN_PORT"/tcp >/dev/null 2>&1 || true

    if xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        systemctl restart xray
        if ! wait_for_xray; then
            echo -e "${RED}Xray failed to start after Trojan install. Rolling back.${NC}"
            cp "${XRAY_CONFIG}.before-trojan" "$XRAY_CONFIG"
            systemctl restart xray
            wait_for_xray || true
        else
            TROJAN_LINK="trojan://${TROJAN_PASSWORD}@${SERVER_ADDRESS}:${TROJAN_PORT}?security=tls&sni=${SERVER_ADDRESS}&type=tcp#Trojan-${SERVER_ADDRESS}"
            cat >> /root/vless-client-info.txt <<EOF

=== Trojan (TLS, port $TROJAN_PORT) ===
$TROJAN_LINK
EOF
        fi
    else
        echo -e "${RED}Trojan config validation failed. Skipping Trojan install.${NC}"
        cp "${XRAY_CONFIG}.before-trojan" "$XRAY_CONFIG"
    fi
else
    echo -e "${YELLOW}Could not obtain TLS certificate. Skipping Trojan and Hysteria2.${NC}"
fi

#######################################
# [4/4] HYSTERIA2 (UDP, port 8443)
#######################################
if [ "$CERT_OK" -eq 1 ]; then
    echo -e "${CYAN}=== [4/4] Installing Hysteria2 ===${NC}"

    retry 3 5 bash -c "bash <(curl -fsSL https://get.hy2.sh/)"

    mkdir -p /etc/hysteria/tls
    cp "/etc/letsencrypt/live/${SERVER_ADDRESS}/fullchain.pem" /etc/hysteria/tls/fullchain.pem
    cp "/etc/letsencrypt/live/${SERVER_ADDRESS}/privkey.pem" /etc/hysteria/tls/privkey.pem
    id -u hysteria >/dev/null 2>&1 && chown hysteria:hysteria /etc/hysteria/tls/*.pem || true
    chmod 750 /etc/hysteria/tls
    chmod 644 /etc/hysteria/tls/fullchain.pem
    chmod 600 /etc/hysteria/tls/privkey.pem

    HY2_PORT=8443
    HY2_PASSWORD=$(openssl rand -hex 16)

    cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY2_PORT}

tls:
  cert: /etc/hysteria/tls/fullchain.pem
  key: /etc/hysteria/tls/privkey.pem

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF

    ufw allow 8443/udp >/dev/null 2>&1 || true

    systemctl enable hysteria-server.service >/dev/null 2>&1 || true
    systemctl restart hysteria-server.service

    HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_ADDRESS}:${HY2_PORT}/?sni=${SERVER_ADDRESS}&insecure=0#Hysteria2-${SERVER_ADDRESS}"

    cat > /root/hysteria2-client-info.txt <<EOF
=== Hysteria2 (UDP, port $HY2_PORT) ===
$HY2_LINK
EOF
fi

#######################################
# OPTIONAL: CLOUDFLARE WARP (Y/N)
#######################################
echo ""
read -r -p "Do you want to install Cloudflare WARP (route all Xray traffic through WARP)? [Y/N]: " INSTALL_WARP
case "$INSTALL_WARP" in
    [Yy]*)
        echo -e "${CYAN}=== Installing Cloudflare WARP ===${NC}"

        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ noble main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        retry 5 5 apt-get update -y
        retry 5 5 apt-get install -y cloudflare-warp

        systemctl enable warp-svc >/dev/null 2>&1
        systemctl start warp-svc

        wait_for_warp_daemon() {
            local i=0
            while [ $i -lt 20 ]; do
                if warp-cli --accept-tos status >/dev/null 2>&1; then
                    return 0
                fi
                sleep 1
                i=$((i + 1))
            done
            return 1
        }
        wait_for_warp_daemon || echo -e "${YELLOW}WARP daemon slow to start, continuing anyway.${NC}"

        if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
            retry 5 5 warp-cli --accept-tos registration new
        fi

        warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
        warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 || true
        warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1 || true
        warp-cli --accept-tos connect >/dev/null 2>&1 || true

        WARP_OK=0
        i=0
        while [ $i -lt 60 ]; do
            if curl -s --max-time 5 --proxy socks5h://127.0.0.1:40000 https://api.ipify.org >/dev/null 2>&1; then
                WARP_OK=1
                break
            fi
            if [ $i -eq 30 ]; then
                warp-cli --accept-tos connect >/dev/null 2>&1 || true
            fi
            sleep 1
            i=$((i + 1))
        done

        if [ "$WARP_OK" -eq 1 ]; then
            cp "$XRAY_CONFIG" "${XRAY_CONFIG}.before-warp"
            jq '.outbounds = [{
                  "protocol": "socks",
                  "tag": "warp",
                  "settings": {
                    "servers": [ { "address": "127.0.0.1", "port": 40000 } ]
                  }
                }]' "$XRAY_CONFIG" > /tmp/xray-config-warp.json && mv /tmp/xray-config-warp.json "$XRAY_CONFIG"

            if xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
                systemctl restart xray
                if ! wait_for_xray; then
                    echo -e "${RED}Xray failed to start after WARP install. Rolling back.${NC}"
                    cp "${XRAY_CONFIG}.before-warp" "$XRAY_CONFIG"
                    systemctl restart xray
                    wait_for_xray || true
                else
                    echo -e "${GREEN}WARP is active. All Xray traffic now routes through WARP.${NC}"
                fi
            else
                echo -e "${RED}WARP outbound config validation failed. Rolling back.${NC}"
                cp "${XRAY_CONFIG}.before-warp" "$XRAY_CONFIG"
            fi
        else
            echo -e "${RED}WARP did not come online in time. Skipping WARP integration.${NC}"
        fi
        ;;
    *)
        echo -e "${YELLOW}Skipping WARP installation.${NC}"
        ;;
esac

#######################################
# DuckDNS setup
#######################################
echo -e "${CYAN}=== Configuring DuckDNS ===${NC}"
mkdir -p /etc/duckdns

cat > /etc/duckdns/duck.sh <<EOF
#!/bin/bash
curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" -o /etc/duckdns/duck.log
EOF
chmod 700 /etc/duckdns/duck.sh

cat > /etc/duckdns/duck-boot.sh <<EOF
#!/bin/bash
sleep 20
for i in \$(seq 1 10); do
    /etc/duckdns/duck.sh
    if grep -q "OK" /etc/duckdns/duck.log 2>/dev/null; then
        exit 0
    fi
    sleep 5
done
EOF
chmod 700 /etc/duckdns/duck-boot.sh

cat > /etc/systemd/system/duckdns-boot.service <<EOF
[Unit]
Description=DuckDNS boot update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/duckdns/duck-boot.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable duckdns-boot.service >/dev/null 2>&1
systemctl start duckdns-boot.service >/dev/null 2>&1 || true

( crontab -l 2>/dev/null | grep -v duckdns ; echo "0 * * * * /etc/duckdns/duck.sh >/dev/null 2>&1" ) | crontab -

retry 3 5 /etc/duckdns/duck.sh

#######################################
# FINAL: ALL INSTALLED PROTOCOLS + CLIENT LINKS
#######################################
echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}         VPN Setup Complete - Client Links       ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
echo -e "${CYAN}Server address:${NC} $SERVER_ADDRESS"
echo -e "${CYAN}Public IP:${NC} $PUBLIC_IP"
echo ""
echo -e "${CYAN}1) VLESS + Reality (TCP, port $PORT):${NC}"
echo "$VLESS_LINK"
echo ""
if [ -n "${XHTTP_LINK:-}" ]; then
    echo -e "${CYAN}2) VLESS + Reality + XHTTP (port $XHTTP_PORT):${NC}"
    echo "$XHTTP_LINK"
    echo ""
fi
if [ -n "${TROJAN_LINK:-}" ]; then
    echo -e "${CYAN}3) Trojan TLS (port $TROJAN_PORT):${NC}"
    echo "$TROJAN_LINK"
    echo ""
fi
if [ -n "${HY2_LINK:-}" ]; then
    echo -e "${CYAN}4) Hysteria2 (UDP, port $HY2_PORT):${NC}"
    echo "$HY2_LINK"
    echo ""
fi

{
    echo "=== VPN Client Links - $SERVER_ADDRESS ==="
    echo ""
    echo "1) VLESS + Reality (TCP, port $PORT):"
    echo "$VLESS_LINK"
    echo ""
    if [ -n "${XHTTP_LINK:-}" ]; then
        echo "2) VLESS + Reality + XHTTP (port $XHTTP_PORT):"
        echo "$XHTTP_LINK"
        echo ""
    fi
    if [ -n "${TROJAN_LINK:-}" ]; then
        echo "3) Trojan TLS (port $TROJAN_PORT):"
        echo "$TROJAN_LINK"
        echo ""
    fi
    if [ -n "${HY2_LINK:-}" ]; then
        echo "4) Hysteria2 (UDP, port $HY2_PORT):"
        echo "$HY2_LINK"
        echo ""
    fi
} > /root/all-client-links.txt

chmod 600 /root/all-client-links.txt
chmod 600 /root/vless-client-info.txt 2>/dev/null || true
chmod 600 /root/hysteria2-client-info.txt 2>/dev/null || true

echo -e "${YELLOW}Keep the links above private. Do not share them.${NC}"
echo -e "${YELLOW}Saved to /root/all-client-links.txt (root-only readable).${NC}"
echo ""
echo -e "${GREEN}Setup is complete.${NC}"
