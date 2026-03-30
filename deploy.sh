#!/bin/bash
set -euo pipefail

# VPNSmart — One-click deployment
# Deploys: Xray + AmneziaWG on Russia, AmneziaWG exit node on Latvia

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
for cmd in ssh rsync jq wg curl; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    err "Missing required tools: ${MISSING[*]}"
    echo "Install them:"
    echo "  macOS:  brew install wireguard-tools jq curl"
    echo "  Linux:  apt install wireguard-tools jq curl"
    exit 1
fi

ok "All dependencies present"

# ─── Step 1: Collect server IPs ───

header "Server configuration"

if [ -f "$ENV_FILE" ]; then
    info "Found existing .env file"
    source "$ENV_FILE"
fi

if [ -z "${RUSSIA_IP:-}" ]; then
    ask "Russia server IP"
    read -r RUSSIA_IP
fi

if [ -z "${LATVIA_IP:-}" ]; then
    ask "Latvia server IP"
    read -r LATVIA_IP
fi

RUSSIA_SSH_USER="${RUSSIA_SSH_USER:-root}"
LATVIA_SSH_USER="${LATVIA_SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_vpnsmart}"

SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes"
if [ -f "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

echo ""
info "Russia:  $RUSSIA_SSH_USER@$RUSSIA_IP"
info "Latvia:  $LATVIA_SSH_USER@$LATVIA_IP"

# ─── Step 2: Test SSH connectivity ───

header "Testing SSH connectivity"

for target in "$RUSSIA_SSH_USER@$RUSSIA_IP" "$LATVIA_SSH_USER@$LATVIA_IP"; do
    if ssh $SSH_OPTS "$target" "echo ok" &> /dev/null; then
        ok "SSH to $target"
    else
        err "Cannot SSH to $target"
        echo "Make sure:"
        echo "  1. SSH key is added: ssh-copy-id -i $SSH_KEY $target"
        echo "  2. Server is reachable: ping ${target#*@}"
        exit 1
    fi
done

# ─── Step 3: Generate keys ───

header "Generating cryptographic keys"

info "AmneziaWG keypair (Russia)..."
RUSSIA_AWG_PRIVATE=$(wg genkey)
RUSSIA_AWG_PUBLIC=$(echo "$RUSSIA_AWG_PRIVATE" | wg pubkey)

info "AmneziaWG keypair (Latvia)..."
LATVIA_AWG_PRIVATE=$(wg genkey)
LATVIA_AWG_PUBLIC=$(echo "$LATVIA_AWG_PRIVATE" | wg pubkey)

info "AmneziaWG preshared key..."
AWG_PSK=$(wg genpsk)

info "AmneziaWG obfuscation parameters..."
AWG_JC=$((RANDOM % 5 + 4))
AWG_JMIN=$((RANDOM % 30 + 50))
AWG_JMAX=$((RANDOM % 700 + 800))
AWG_S1=$((RANDOM * RANDOM))
AWG_S2=$((RANDOM * RANDOM))
AWG_H1=$((RANDOM * RANDOM))
AWG_H2=$((RANDOM * RANDOM))
AWG_H3=$((RANDOM * RANDOM))
AWG_H4=$((RANDOM * RANDOM))

info "VLESS client UUID..."
CLIENT_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')

info "Reality keypair (generating on Russia server)..."
REALITY_OUTPUT=$(ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "
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

info "Reality short ID..."
SHORT_ID=$(openssl rand -hex 8)

ok "All keys generated"

# Save to .env
cat > "$ENV_FILE" << EOF
# VPNSmart keys — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# DO NOT commit this file!

RUSSIA_IP=$RUSSIA_IP
LATVIA_IP=$LATVIA_IP
RUSSIA_SSH_USER=$RUSSIA_SSH_USER
LATVIA_SSH_USER=$LATVIA_SSH_USER

RUSSIA_AWG_PRIVATE_KEY=$RUSSIA_AWG_PRIVATE
RUSSIA_AWG_PUBLIC_KEY=$RUSSIA_AWG_PUBLIC
LATVIA_AWG_PRIVATE_KEY=$LATVIA_AWG_PRIVATE
LATVIA_AWG_PUBLIC_KEY=$LATVIA_AWG_PUBLIC
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

# Latvia AmneziaWG config
LATVIA_AWG_CONF=$(cat << EOF
[Interface]
PrivateKey = $LATVIA_AWG_PRIVATE
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
PublicKey = $RUSSIA_AWG_PUBLIC
PresharedKey = $AWG_PSK
AllowedIPs = 10.10.0.1/32
EOF
)

# Russia AmneziaWG config
RUSSIA_AWG_CONF=$(cat << EOF
[Interface]
PrivateKey = $RUSSIA_AWG_PRIVATE
Address = 10.10.0.1/24

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
PublicKey = $LATVIA_AWG_PUBLIC
PresharedKey = $AWG_PSK
Endpoint = $LATVIA_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
)

# Russia Xray config — build with jq
RUSSIA_XRAY_CONF=$(jq -n \
    --arg client_uuid "$CLIENT_UUID" \
    --arg reality_private "$REALITY_PRIVATE" \
    --arg short_id "$SHORT_ID" \
'{
  "log": { "loglevel": "warning" },
  "api": { "tag": "api", "services": ["HandlerService", "StatsService"] },
  "dns": {
    "hosts": {
      "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"],
      "common.dot.dns.yandex.net": ["77.88.8.8", "77.88.8.1"]
    },
    "servers": [
      { "address": "https://cloudflare-dns.com/dns-query", "domains": ["ext:geosite_RU.dat:ru-blocked"], "queryStrategy": "UseIPv4", "skipFallback": true },
      { "address": "https+local://common.dot.dns.yandex.net/dns-query", "queryStrategy": "UseIPv4" }
    ],
    "queryStrategy": "UseIPv4",
    "disableFallbackIfMatch": false,
    "tag": "dns"
  },
  "stats": {},
  "inbounds": [
    { "tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" } },
    {
      "tag": "vless-in", "listen": "0.0.0.0", "port": 443, "protocol": "vless",
      "settings": { "clients": [{ "email": "client1", "id": $client_uuid, "flow": "xtls-rprx-vision" }], "decryption": "none" },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": { "show": false, "dest": "ya.ru:443", "xver": 0, "serverNames": ["ya.ru"], "privateKey": $reality_private, "shortIds": [$short_id] }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false, "routeOnly": true }
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
      { "type": "field", "ip": ["ext:geoip_RU.dat:ru-blocked", "ext:geoip_RU.dat:ru-blocked-community", "ext:geoip_RU.dat:re-filter"], "outboundTag": "awg" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  },
  "policy": { "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } }, "system": { "statsInboundUplink": true, "statsInboundDownlink": true, "statsOutboundUplink": true, "statsOutboundDownlink": true } }
}')

ok "Configs prepared with actual keys"

# ─── Step 5: Deploy Latvia server ───

header "Deploying Latvia server"

info "Running setup script..."
ssh $SSH_OPTS "$LATVIA_SSH_USER@$LATVIA_IP" << 'REMOTE_SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt update -qq
apt upgrade -y -qq

# Install AmneziaWG
if ! command -v awg &> /dev/null; then
    apt install -y -qq software-properties-common
    add-apt-repository -y ppa:amneziavpn/ppa 2>/dev/null || true
    apt update -qq
    apt install -y -qq amneziawg amneziawg-tools 2>/dev/null || {
        apt install -y -qq git golang-go make wireguard-tools
        cd /tmp && rm -rf amneziawg-go
        git clone https://github.com/amnezia-vpn/amneziawg-go.git
        cd amneziawg-go && make && make install
        cd / && rm -rf /tmp/amneziawg-go
    }
fi

apt install -y -qq wireguard-tools

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

mkdir -p /etc/amneziawg
REMOTE_SETUP

ok "Latvia: system configured"

info "Uploading AmneziaWG config..."
echo "$LATVIA_AWG_CONF" | ssh $SSH_OPTS "$LATVIA_SSH_USER@$LATVIA_IP" "cat > /etc/amneziawg/awg0.conf && chmod 600 /etc/amneziawg/awg0.conf"

info "Starting AmneziaWG..."
ssh $SSH_OPTS "$LATVIA_SSH_USER@$LATVIA_IP" "systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0"

ok "Latvia server deployed"

# ─── Step 6: Deploy Russia server ───

header "Deploying Russia server"

info "Running setup script..."
ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" << 'REMOTE_SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt update -qq
apt upgrade -y -qq

# Install Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

if ! docker compose version &> /dev/null; then
    apt install -y -qq docker-compose-plugin
fi

apt install -y -qq jq curl

# Install AmneziaWG
if ! command -v awg &> /dev/null; then
    apt install -y -qq software-properties-common
    add-apt-repository -y ppa:amneziavpn/ppa 2>/dev/null || true
    apt update -qq
    apt install -y -qq amneziawg amneziawg-tools 2>/dev/null || {
        apt install -y -qq git golang-go make wireguard-tools
        cd /tmp && rm -rf amneziawg-go
        git clone https://github.com/amnezia-vpn/amneziawg-go.git
        cd amneziawg-go && make && make install
        cd / && rm -rf /tmp/amneziawg-go
    }
fi

apt install -y -qq wireguard-tools

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

mkdir -p /etc/amneziawg /opt/vpnsmart/xray/geodata /opt/vpnsmart/scripts /opt/vpnsmart/bot

# Download geodata
BASE_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
curl -sSL -o /opt/vpnsmart/xray/geodata/geosite_RU.dat "$BASE_URL/geosite_RU.dat" || true
curl -sSL -o /opt/vpnsmart/xray/geodata/geoip_RU.dat "$BASE_URL/geoip_RU.dat" || true
REMOTE_SETUP

ok "Russia: system configured"

info "Uploading AmneziaWG config..."
echo "$RUSSIA_AWG_CONF" | ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "cat > /etc/amneziawg/awg0.conf && chmod 600 /etc/amneziawg/awg0.conf"

info "Starting AmneziaWG tunnel..."
ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0 && sysctl -w net.ipv4.conf.awg0.rp_filter=0 > /dev/null 2>&1 || true"

info "Uploading Xray config..."
echo "$RUSSIA_XRAY_CONF" | ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "cat > /opt/vpnsmart/xray/config.json"

# Upload docker-compose and bot
info "Uploading project files..."
rsync -avz --exclude='.git' --exclude='*.dat' --exclude='.env' \
    "$SCRIPT_DIR/servers/russia/docker-compose.yml" \
    "$RUSSIA_SSH_USER@$RUSSIA_IP":/opt/vpnsmart/docker-compose.yml

rsync -avz "$SCRIPT_DIR/servers/russia/bot/" "$RUSSIA_SSH_USER@$RUSSIA_IP":/opt/vpnsmart/bot/
rsync -avz "$SCRIPT_DIR/servers/russia/scripts/" "$RUSSIA_SSH_USER@$RUSSIA_IP":/opt/vpnsmart/scripts/

# Upload update-geodata script and set cron
ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "chmod +x /opt/vpnsmart/scripts/*.sh && (crontab -l 2>/dev/null | grep -v update-geodata; echo '0 */6 * * * /opt/vpnsmart/scripts/update-geodata.sh') | crontab -"

info "Creating bot .env..."
ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "cat > /opt/vpnsmart/.env.bot" << EOF
BOT_TOKEN=${BOT_TOKEN:-CHANGE_ME}
ADMIN_ID=${ADMIN_ID:-CHANGE_ME}
RUSSIA_IP=$RUSSIA_IP
REALITY_PUBLIC_KEY=$REALITY_PUBLIC
REALITY_SHORT_ID=$SHORT_ID
XRAY_CONFIG=/opt/vpnsmart/xray/config.json
XRAY_CONTAINER=vpnsmart-xray-russia
DB_PATH=/data/vpnsmart.db
EOF

info "Starting containers..."
ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "cd /opt/vpnsmart && docker compose down 2>/dev/null; docker compose up -d --build"

ok "Russia server deployed"

# ─── Step 7: Verify tunnel ───

header "Verifying tunnel connectivity"

sleep 5

info "Testing AmneziaWG tunnel (Russia → Latvia)..."
TUNNEL_OK=false
for attempt in 1 2 3; do
    if ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "ping -c 2 -W 3 10.10.0.2" &> /dev/null; then
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
    echo "  Russia: ssh $RUSSIA_SSH_USER@$RUSSIA_IP 'awg show; ip rule show; ip route show table 100'"
    echo "  Latvia: ssh $LATVIA_SSH_USER@$LATVIA_IP 'awg show'"
fi

# Verify policy routing
info "Checking policy routing..."
ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "ip rule show | grep -q 'fwmark 0x1' && echo 'fwmark rule OK' || echo 'fwmark rule MISSING'"
ssh $SSH_OPTS "$RUSSIA_SSH_USER@$RUSSIA_IP" "ip route show table 100 | grep -q 'awg0' && echo 'route table 100 OK' || echo 'route table 100 MISSING'"

# ─── Step 8: Generate VLESS link ───

header "Client configuration"

VLESS_LINK="vless://${CLIENT_UUID}@${RUSSIA_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=ya.ru&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#vpnsmart"

echo "VLESS link (import into v2rayN / Hiddify / sing-box):"
echo ""
echo -e "  ${CYAN}${VLESS_LINK}${NC}"
echo ""

# ─── Done ───

header "DEPLOYMENT COMPLETE"

echo -e "${GREEN}VPN is ready!${NC}"
echo ""
echo "Your servers:"
echo -e "  Russia: ${CYAN}$RUSSIA_IP${NC} (Xray + VLESS + Reality + AmneziaWG)"
echo -e "  Latvia: ${CYAN}$LATVIA_IP${NC} (AmneziaWG exit node)"
echo ""
echo "Client apps:"
echo "  v2rayN (Windows), Hiddify (Android/iOS), sing-box (all platforms)"
echo "  Import the VLESS link above."
echo ""
echo "Manage clients via Telegram bot (set BOT_TOKEN and ADMIN_ID in .env.bot)"
echo ""
echo "Keys and credentials saved in: ${CYAN}.env${NC}"
echo -e "${RED}Do NOT share or commit the .env file!${NC}"
