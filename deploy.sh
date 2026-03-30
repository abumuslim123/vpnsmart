#!/bin/bash
set -euo pipefail

# VPNSmart — One-click deployment
# Deploys: Xray + AmneziaWG on entry server, AmneziaWG exit node on exit server
#
# You need 2 VPS servers (Ubuntu 22.04+) with root SSH access:
#   - Entry server (e.g. Russia) — clients connect here
#   - Exit server (e.g. Europe)  — blocked traffic exits here

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

header() { echo -e "\n${GREEN}══════════════════════════════════════${NC}"; echo -e "${GREEN}  $1${NC}"; echo -e "${GREEN}══════════════════════════════════════${NC}\n"; }
info()   { echo -e "${YELLOW}→ $1${NC}"; }
ok()     { echo -e "${GREEN}✓ $1${NC}"; }
err()    { echo -e "${RED}✗ $1${NC}"; }
ask()    { echo -en "${CYAN}? $1: ${NC}"; }

# ─── Step 0: Check local dependencies ───

header "Checking local dependencies"

MISSING=()
for cmd in ssh scp jq wg curl openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    err "Missing required tools: ${MISSING[*]}"
    echo "Install them:"
    echo "  macOS:  brew install wireguard-tools jq curl openssl"
    echo "  Linux:  apt install wireguard-tools jq curl openssl"
    exit 1
fi

ok "All dependencies present"

# ─── Step 1: Collect server IPs and bot credentials ───

header "Server configuration"

if [ -f "$ENV_FILE" ]; then
    info "Found existing .env file — loading saved values"
    source "$ENV_FILE"
fi

if [ -z "${ENTRY_IP:-}" ]; then
    ask "Entry server IP (where clients connect, e.g. Russia)"
    read -r ENTRY_IP
fi

if [ -z "${EXIT_IP:-}" ]; then
    ask "Exit server IP (where blocked traffic exits, e.g. Europe)"
    read -r EXIT_IP
fi

if [ -z "${BOT_TOKEN:-}" ]; then
    echo ""
    info "Telegram bot is optional but recommended for client management."
    info "Create a bot via @BotFather and paste the token, or press Enter to skip."
    ask "Telegram bot token (or Enter to skip)"
    read -r BOT_TOKEN
    BOT_TOKEN="${BOT_TOKEN:-CHANGE_ME}"
fi

if [ "$BOT_TOKEN" != "CHANGE_ME" ] && [ -z "${ADMIN_ID:-}" ]; then
    info "Your Telegram user ID (send /start to @userinfobot to find out)"
    ask "Telegram admin ID"
    read -r ADMIN_ID
    ADMIN_ID="${ADMIN_ID:-CHANGE_ME}"
fi
ADMIN_ID="${ADMIN_ID:-CHANGE_ME}"

ENTRY_SSH_USER="${ENTRY_SSH_USER:-root}"
EXIT_SSH_USER="${EXIT_SSH_USER:-root}"

# Auto-detect SSH key
SSH_KEY=""
for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
    if [ -f "$key" ]; then
        SSH_KEY="$key"
        break
    fi
done

SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

echo ""
info "Entry:  $ENTRY_SSH_USER@$ENTRY_IP"
info "Exit:   $EXIT_SSH_USER@$EXIT_IP"

# ─── Step 2: Test SSH connectivity ───

header "Testing SSH connectivity"

for target in "$ENTRY_SSH_USER@$ENTRY_IP" "$EXIT_SSH_USER@$EXIT_IP"; do
    if ssh $SSH_OPTS "$target" "echo ok" &> /dev/null; then
        ok "SSH to $target"
    else
        err "Cannot SSH to $target"
        echo "Make sure:"
        echo "  1. SSH key is added: ssh-copy-id $target"
        echo "  2. Server is reachable: ping ${target#*@}"
        exit 1
    fi
done

# ─── Step 3: Generate keys ───

header "Generating cryptographic keys"

info "AmneziaWG keypair (entry server)..."
ENTRY_AWG_PRIVATE=$(wg genkey)
ENTRY_AWG_PUBLIC=$(echo "$ENTRY_AWG_PRIVATE" | wg pubkey)

info "AmneziaWG keypair (exit server)..."
EXIT_AWG_PRIVATE=$(wg genkey)
EXIT_AWG_PUBLIC=$(echo "$EXIT_AWG_PRIVATE" | wg pubkey)

info "AmneziaWG preshared key..."
AWG_PSK=$(wg genpsk)

info "AmneziaWG obfuscation parameters..."
AWG_JC=$((RANDOM % 5 + 4))
AWG_JMIN=$((RANDOM % 30 + 50))
AWG_JMAX=$((RANDOM % 700 + 800))
AWG_S1=$((RANDOM % 100 + 15))
AWG_S2=$((RANDOM % 100 + 15))
AWG_H1=$((RANDOM * RANDOM % 2147483647))
AWG_H2=$((RANDOM * RANDOM % 2147483647))
AWG_H3=$((RANDOM * RANDOM % 2147483647))
AWG_H4=$((RANDOM * RANDOM % 2147483647))

info "VLESS client UUID..."
CLIENT_UUID=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || python3 -c "import uuid; print(uuid.uuid4())")

info "Reality keypair (generating on entry server)..."
REALITY_OUTPUT=$(ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "
    if command -v docker &> /dev/null; then
        docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null
    else
        curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
        systemctl enable docker > /dev/null 2>&1
        systemctl start docker > /dev/null 2>&1
        docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null
    fi
")
REALITY_PRIVATE=$(echo "$REALITY_OUTPUT" | grep -i "private" | awk '{print $NF}')
REALITY_PUBLIC=$(echo "$REALITY_OUTPUT" | grep -i "public" | awk '{print $NF}')

if [ -z "$REALITY_PRIVATE" ] || [ -z "$REALITY_PUBLIC" ]; then
    err "Failed to generate Reality keypair. Make sure Docker works on the entry server."
    exit 1
fi

info "Reality short ID..."
SHORT_ID=$(openssl rand -hex 8)

ok "All keys generated"

# Save to .env
cat > "$ENV_FILE" << EOF
# VPNSmart keys — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# DO NOT commit this file!

ENTRY_IP=$ENTRY_IP
EXIT_IP=$EXIT_IP
ENTRY_SSH_USER=$ENTRY_SSH_USER
EXIT_SSH_USER=$EXIT_SSH_USER

BOT_TOKEN=$BOT_TOKEN
ADMIN_ID=$ADMIN_ID

ENTRY_AWG_PRIVATE_KEY=$ENTRY_AWG_PRIVATE
ENTRY_AWG_PUBLIC_KEY=$ENTRY_AWG_PUBLIC
EXIT_AWG_PRIVATE_KEY=$EXIT_AWG_PRIVATE
EXIT_AWG_PUBLIC_KEY=$EXIT_AWG_PUBLIC
AWG_PRESHARED_KEY=$AWG_PSK

AWG_JC=$AWG_JC
AWG_JMIN=$AWG_JMIN
AWG_JMAX=$AWG_JMAX
AWG_S1=$AWG_S1
AWG_S2=$AWG_S2
AWG_H1=$AWG_H1
AWG_H2=$AWG_H2
AWG_H3=$AWG_H3
AWG_H4=$AWG_H4

REALITY_PRIVATE_KEY=$REALITY_PRIVATE
REALITY_PUBLIC_KEY=$REALITY_PUBLIC
REALITY_SHORT_ID=$SHORT_ID

CLIENT_UUID=$CLIENT_UUID
EOF

ok "Keys saved to .env (git-ignored)"

# ─── Step 4: Prepare configs with actual values ───

header "Preparing configurations"

# Exit server AmneziaWG config
EXIT_AWG_CONF=$(cat << EOF
[Interface]
PrivateKey = $EXIT_AWG_PRIVATE
Address = 10.10.0.2/24
ListenPort = 51820

Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

PostUp = iptables -t nat -A POSTROUTING -o \$(ip route show default | awk '{print \$5}') -j MASQUERADE
PostUp = ip6tables -t nat -A POSTROUTING -o \$(ip route show default | awk '{print \$5}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o \$(ip route show default | awk '{print \$5}') -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -o \$(ip route show default | awk '{print \$5}') -j MASQUERADE

[Peer]
PublicKey = $ENTRY_AWG_PUBLIC
PresharedKey = $AWG_PSK
AllowedIPs = 10.10.0.1/32
EOF
)

# Entry server AmneziaWG config
ENTRY_AWG_CONF=$(cat << EOF
[Interface]
PrivateKey = $ENTRY_AWG_PRIVATE
Address = 10.10.0.1/24
Table = off

Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

PostUp = ip rule add fwmark 1 table 100
PostUp = ip route add default dev awg0 table 100
PostDown = ip rule del fwmark 1 table 100
PostDown = ip route del default dev awg0 table 100

[Peer]
PublicKey = $EXIT_AWG_PUBLIC
PresharedKey = $AWG_PSK
Endpoint = $EXIT_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
)

# Entry server Xray config — build with jq
ENTRY_XRAY_CONF=$(jq -n \
    --arg client_uuid "$CLIENT_UUID" \
    --arg reality_private "$REALITY_PRIVATE" \
    --arg short_id "$SHORT_ID" \
'{
  "log": { "loglevel": "warning" },
  "api": { "tag": "api", "services": ["HandlerService", "StatsService"] },
  "dns": {
    "hosts": { "cloudflare-dns.com": ["1.1.1.1","1.0.0.1"], "common.dot.dns.yandex.net": ["77.88.8.8","77.88.8.1"] },
    "servers": [
      { "address": "https://cloudflare-dns.com/dns-query", "domains": ["ext:geosite_RU.dat:ru-blocked"], "queryStrategy": "UseIPv4", "skipFallback": true },
      { "address": "https+local://common.dot.dns.yandex.net/dns-query", "queryStrategy": "UseIPv4" }
    ],
    "queryStrategy": "UseIPv4", "tag": "dns"
  },
  "stats": {},
  "inbounds": [
    { "tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" } },
    {
      "tag": "vless-in", "listen": "0.0.0.0", "port": 443, "protocol": "vless",
      "settings": { "clients": [{ "email": "client1", "id": $client_uuid, "flow": "xtls-rprx-vision" }], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "dest": "ya.ru:443", "xver": 0, "serverNames": ["ya.ru"], "privateKey": $reality_private, "shortIds": [$short_id] } },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false, "routeOnly": true }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "awg", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" }, "streamSettings": { "sockopt": { "mark": 1 } } },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
      { "type": "field", "inboundTag": ["dns"], "outboundTag": "awg" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "domain": ["ext:geosite_RU.dat:ru-blocked"], "outboundTag": "awg" },
      { "type": "field", "ip": ["ext:geoip_RU.dat:ru-blocked","ext:geoip_RU.dat:ru-blocked-community","ext:geoip_RU.dat:re-filter"], "outboundTag": "awg" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  },
  "policy": { "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } }, "system": { "statsInboundUplink": true, "statsInboundDownlink": true, "statsOutboundUplink": true, "statsOutboundDownlink": true } }
}')

ok "Configs prepared with actual keys"

# ─── Step 5: Deploy exit server ───

header "Deploying exit server ($EXIT_IP)"

info "Installing AmneziaWG (this may take a few minutes on first run)..."
ssh $SSH_OPTS "$EXIT_SSH_USER@$EXIT_IP" << 'REMOTE_SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt update -qq
apt upgrade -y -qq
apt install -y -qq git make wireguard-tools iptables

# Install Go (needed to build AmneziaWG)
if ! command -v go &> /dev/null || ! go version 2>/dev/null | grep -qE 'go1\.(2[4-9]|[3-9])'; then
    rm -rf /usr/local/go
    curl -sSL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz -o /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh
fi
export PATH=/usr/local/go/bin:$PATH

# Build AmneziaWG if not installed
if ! command -v awg &> /dev/null; then
    cd /tmp && rm -rf amneziawg-go amneziawg-tools
    git clone https://github.com/amnezia-vpn/amneziawg-go.git
    cd amneziawg-go && make && cp amneziawg-go /usr/bin/amneziawg-go
    cd /tmp && git clone https://github.com/amnezia-vpn/amneziawg-tools.git
    cd amneziawg-tools/src && make && make install
    rm -rf /tmp/amneziawg-go /tmp/amneziawg-tools
fi

# sysctl
cat > /etc/sysctl.d/99-vpnsmart.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
SYSCTL
sysctl --system > /dev/null

# Firewall
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow 51820/udp > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
fi

mkdir -p /etc/amnezia/amneziawg
REMOTE_SETUP

ok "Exit server: system configured"

info "Uploading AmneziaWG config..."
echo "$EXIT_AWG_CONF" | ssh $SSH_OPTS "$EXIT_SSH_USER@$EXIT_IP" "cat > /etc/amnezia/amneziawg/awg0.conf && chmod 600 /etc/amnezia/amneziawg/awg0.conf"

info "Starting AmneziaWG..."
ssh $SSH_OPTS "$EXIT_SSH_USER@$EXIT_IP" "systemctl daemon-reload && systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0"

ok "Exit server deployed"

# ─── Step 6: Deploy entry server ───

header "Deploying entry server ($ENTRY_IP)"

info "Installing Docker and AmneziaWG..."
ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" << 'REMOTE_SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt update -qq
apt upgrade -y -qq
apt install -y -qq jq curl git make wireguard-tools iptables

# Install Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi
if ! docker compose version &> /dev/null; then
    apt install -y -qq docker-compose-plugin
fi

# Install Go for AmneziaWG
if ! command -v go &> /dev/null || ! go version 2>/dev/null | grep -qE 'go1\.(2[4-9]|[3-9])'; then
    rm -rf /usr/local/go
    curl -sSL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz -o /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh
fi
export PATH=/usr/local/go/bin:$PATH

# Build AmneziaWG if not installed
if ! command -v awg &> /dev/null; then
    apt install -y -qq gcc
    cd /tmp && rm -rf amneziawg-go amneziawg-tools
    git clone https://github.com/amnezia-vpn/amneziawg-go.git
    cd amneziawg-go && make && cp amneziawg-go /usr/bin/amneziawg-go
    cd /tmp && git clone https://github.com/amnezia-vpn/amneziawg-tools.git
    cd amneziawg-tools/src && make && make install
    rm -rf /tmp/amneziawg-go /tmp/amneziawg-tools
fi

# sysctl
cat > /etc/sysctl.d/99-vpnsmart.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
SYSCTL
sysctl --system > /dev/null

# Firewall
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1
    ufw allow 443/udp > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
fi

mkdir -p /etc/amnezia/amneziawg /opt/vpnsmart/xray/geodata /opt/vpnsmart/scripts /opt/vpnsmart/bot

# Download geodata
BASE_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
curl -sSL -o /opt/vpnsmart/xray/geodata/geosite_RU.dat "$BASE_URL/geosite.dat" || true
curl -sSL -o /opt/vpnsmart/xray/geodata/geoip_RU.dat "$BASE_URL/geoip.dat" || true
REMOTE_SETUP

ok "Entry server: system configured"

info "Uploading AmneziaWG config..."
echo "$ENTRY_AWG_CONF" | ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "cat > /etc/amnezia/amneziawg/awg0.conf && chmod 600 /etc/amnezia/amneziawg/awg0.conf"

info "Starting AmneziaWG tunnel..."
ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "systemctl daemon-reload && systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0 && sysctl -w net.ipv4.conf.awg0.rp_filter=0 > /dev/null 2>&1 || true"

info "Uploading Xray config..."
echo "$ENTRY_XRAY_CONF" | ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "cat > /opt/vpnsmart/xray/config.json"

info "Uploading project files..."
scp $SSH_OPTS "$SCRIPT_DIR/servers/russia/docker-compose.yml" "$ENTRY_SSH_USER@$ENTRY_IP":/opt/vpnsmart/docker-compose.yml
scp $SSH_OPTS "$SCRIPT_DIR/servers/russia/bot/"* "$ENTRY_SSH_USER@$ENTRY_IP":/opt/vpnsmart/bot/
scp $SSH_OPTS "$SCRIPT_DIR/servers/russia/scripts/"* "$ENTRY_SSH_USER@$ENTRY_IP":/opt/vpnsmart/scripts/

ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "chmod +x /opt/vpnsmart/scripts/*.sh && (crontab -l 2>/dev/null | grep -v update-geodata; echo '0 */6 * * * /opt/vpnsmart/scripts/update-geodata.sh') | crontab -"

info "Creating bot .env..."
cat << EOF | ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "cat > /opt/vpnsmart/.env.bot"
BOT_TOKEN=$BOT_TOKEN
ADMIN_ID=$ADMIN_ID
RUSSIA_IP=$ENTRY_IP
REALITY_PUBLIC_KEY=$REALITY_PUBLIC
REALITY_SHORT_ID=$SHORT_ID
XRAY_CONFIG=/opt/vpnsmart/xray/config.json
XRAY_CONTAINER=vpnsmart-xray-russia
DB_PATH=/data/vpnsmart.db
EOF

info "Starting containers..."
ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "cd /opt/vpnsmart && docker compose down 2>/dev/null; docker compose up -d --build"

info "Registering first client in bot database..."
sleep 3
ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "docker exec vpnsmart-bot python3 -c \"
import sqlite3
conn = sqlite3.connect('/data/vpnsmart.db')
conn.execute('CREATE TABLE IF NOT EXISTS clients (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, uuid TEXT UNIQUE NOT NULL, note TEXT DEFAULT \\'\\', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)')
try:
    conn.execute('INSERT INTO clients (name, uuid, note) VALUES (?, ?, ?)', ('client1', '$CLIENT_UUID', 'Initial deploy client'))
    conn.commit()
    print('client1 registered in bot DB')
except Exception:
    print('client1 already in DB')
conn.close()
\""

ok "Entry server deployed"

# ─── Step 7: Verify tunnel ───

header "Verifying tunnel connectivity"

sleep 5

info "Testing AmneziaWG tunnel..."
TUNNEL_OK=false
for attempt in 1 2 3; do
    if ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "ping -c 2 -W 3 10.10.0.2" &> /dev/null; then
        TUNNEL_OK=true
        break
    fi
    info "Attempt $attempt/3 — waiting..."
    sleep 5
done

if [ "$TUNNEL_OK" = true ]; then
    ok "AmneziaWG tunnel is UP"
else
    err "AmneziaWG tunnel is DOWN"
    echo "Debug:"
    echo "  Entry: ssh $ENTRY_SSH_USER@$ENTRY_IP 'awg show; ip rule show; ip route show table 100'"
    echo "  Exit:  ssh $EXIT_SSH_USER@$EXIT_IP 'awg show'"
fi

info "Checking policy routing..."
ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "ip rule show | grep -q 'fwmark 0x1' && echo 'fwmark rule OK' || echo 'fwmark rule MISSING'"
ssh $SSH_OPTS "$ENTRY_SSH_USER@$ENTRY_IP" "ip route show table 100 | grep -q 'awg0' && echo 'route table 100 OK' || echo 'route table 100 MISSING'"

# ─── Step 8: Generate VLESS link ───

header "Client configuration"

VLESS_LINK="vless://${CLIENT_UUID}@${ENTRY_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=ya.ru&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#vpnsmart"

echo "VLESS link (import into v2rayN / Hiddify / sing-box):"
echo ""
echo -e "  ${CYAN}${VLESS_LINK}${NC}"
echo ""

# ─── Done ───

header "DEPLOYMENT COMPLETE"

echo -e "${GREEN}VPN is ready!${NC}"
echo ""
echo "Your servers:"
echo -e "  Entry: ${CYAN}$ENTRY_IP${NC} (Xray + VLESS + Reality + AmneziaWG)"
echo -e "  Exit:  ${CYAN}$EXIT_IP${NC} (AmneziaWG exit node)"
echo ""
echo "Client apps:"
echo "  v2rayN (Windows), Hiddify (Android/iOS), sing-box (all platforms)"
echo "  Import the VLESS link above."
echo ""
if [ "$BOT_TOKEN" != "CHANGE_ME" ]; then
    echo "Telegram bot is configured. Send /start to your bot to manage clients."
else
    echo "Telegram bot is not configured."
    echo "To enable it later, edit /opt/vpnsmart/.env.bot on the entry server"
    echo "and restart: docker compose restart bot"
fi
echo ""
echo "Keys and credentials saved in: ${CYAN}.env${NC}"
echo -e "${RED}Do NOT share or commit the .env file!${NC}"
