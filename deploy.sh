#!/bin/bash
set -euo pipefail

# VPNSmart — One-click deployment
# Deploys the full VPN stack to both servers

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
for cmd in ssh rsync jq wg; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING+=("$cmd")
    fi
done

# sing-box is optional locally — we can generate UUID with uuidgen
HAS_SINGBOX=false
if command -v sing-box &> /dev/null; then
    HAS_SINGBOX=true
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    err "Missing required tools: ${MISSING[*]}"
    echo "Install them:"
    echo "  macOS:  brew install wireguard-tools jq"
    echo "  Linux:  apt install wireguard-tools jq"
    exit 1
fi

if [ "$HAS_SINGBOX" = false ]; then
    info "sing-box not found locally — will use uuidgen for UUID and generate Reality keys on the server"
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

if [ -z "${FINLAND_IP:-}" ]; then
    ask "Finland server IP"
    read -r FINLAND_IP
fi

RUSSIA_SSH_USER="${RUSSIA_SSH_USER:-root}"
FINLAND_SSH_USER="${FINLAND_SSH_USER:-root}"

echo ""
info "Russia:  $RUSSIA_SSH_USER@$RUSSIA_IP"
info "Finland: $FINLAND_SSH_USER@$FINLAND_IP"

# ─── Step 2: Test SSH connectivity ───

header "Testing SSH connectivity"

for target in "$RUSSIA_SSH_USER@$RUSSIA_IP" "$FINLAND_SSH_USER@$FINLAND_IP"; do
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$target" "echo ok" &> /dev/null; then
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

info "WireGuard keypair (Russia)..."
RUSSIA_WG_PRIVATE=$(wg genkey)
RUSSIA_WG_PUBLIC=$(echo "$RUSSIA_WG_PRIVATE" | wg pubkey)

info "WireGuard keypair (Finland)..."
FINLAND_WG_PRIVATE=$(wg genkey)
FINLAND_WG_PUBLIC=$(echo "$FINLAND_WG_PRIVATE" | wg pubkey)

info "WireGuard preshared key..."
WG_PSK=$(wg genpsk)

info "VLESS client UUID..."
if [ "$HAS_SINGBOX" = true ]; then
    CLIENT_UUID=$(sing-box generate uuid)
else
    CLIENT_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
fi

info "Reality keypair..."
if [ "$HAS_SINGBOX" = true ]; then
    REALITY_OUTPUT=$(sing-box generate reality-keypair)
    REALITY_PRIVATE=$(echo "$REALITY_OUTPUT" | grep -i private | awk '{print $NF}')
    REALITY_PUBLIC=$(echo "$REALITY_OUTPUT" | grep -i public | awk '{print $NF}')
else
    info "Generating Reality keypair on Russia server..."
    # Install sing-box on Russia server temporarily for key generation
    REALITY_OUTPUT=$(ssh "$RUSSIA_SSH_USER@$RUSSIA_IP" "
        if ! command -v sing-box &> /dev/null; then
            bash <(curl -fsSL https://sing-box.app/deb-install.sh) 2>/dev/null || {
                curl -Lo /tmp/sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-\$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d'\"' -f4 | sed 's/v//')-linux-amd64.tar.gz 2>/dev/null
                tar -xzf /tmp/sing-box.tar.gz -C /tmp/
                cp /tmp/sing-box-*/sing-box /usr/local/bin/
                rm -rf /tmp/sing-box*
            }
        fi
        sing-box generate reality-keypair
    ")
    REALITY_PRIVATE=$(echo "$REALITY_OUTPUT" | grep -i private | awk '{print $NF}')
    REALITY_PUBLIC=$(echo "$REALITY_OUTPUT" | grep -i public | awk '{print $NF}')
fi

info "Reality short ID..."
SHORT_ID=$(openssl rand -hex 8)

ok "All keys generated"

# Save to .env for reference
cat > "$ENV_FILE" << EOF
# VPNSmart keys — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# DO NOT commit this file!

RUSSIA_IP=$RUSSIA_IP
FINLAND_IP=$FINLAND_IP
RUSSIA_SSH_USER=$RUSSIA_SSH_USER
FINLAND_SSH_USER=$FINLAND_SSH_USER

RUSSIA_WG_PRIVATE_KEY=$RUSSIA_WG_PRIVATE
RUSSIA_WG_PUBLIC_KEY=$RUSSIA_WG_PUBLIC
FINLAND_WG_PRIVATE_KEY=$FINLAND_WG_PRIVATE
FINLAND_WG_PUBLIC_KEY=$FINLAND_WG_PUBLIC
WG_PRESHARED_KEY=$WG_PSK

REALITY_PRIVATE_KEY=$REALITY_PRIVATE
REALITY_PUBLIC_KEY=$REALITY_PUBLIC
REALITY_SHORT_ID=$SHORT_ID

CLIENT_UUID=$CLIENT_UUID
EOF

ok "Keys saved to .env (git-ignored)"

# ─── Step 4: Prepare configs with actual values ───

header "Preparing configurations"

# Finland WireGuard config
FINLAND_WG_CONF=$(cat << EOF
[Interface]
PrivateKey = $FINLAND_WG_PRIVATE
Address = 10.10.0.2/24
ListenPort = 51820

PostUp = iptables -t nat -A POSTROUTING -o \$(ip route show default | awk '{print \$5}') -j MASQUERADE
PostUp = ip6tables -t nat -A POSTROUTING -o \$(ip route show default | awk '{print \$5}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o \$(ip route show default | awk '{print \$5}') -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -o \$(ip route show default | awk '{print \$5}') -j MASQUERADE

[Peer]
PublicKey = $RUSSIA_WG_PUBLIC
PresharedKey = $WG_PSK
AllowedIPs = 10.10.0.1/32
EOF
)

# Russia sing-box config — build with jq for correctness
RUSSIA_SINGBOX_CONF=$(jq -n \
    --arg client_uuid "$CLIENT_UUID" \
    --arg reality_private "$REALITY_PRIVATE" \
    --arg short_id "$SHORT_ID" \
    --arg finland_ip "$FINLAND_IP" \
    --arg ru_wg_private "$RUSSIA_WG_PRIVATE" \
    --arg fi_wg_public "$FINLAND_WG_PUBLIC" \
    --arg wg_psk "$WG_PSK" \
'{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-google",
        "address": "tls://8.8.8.8",
        "detour": "direct"
      },
      {
        "tag": "dns-google-proxy",
        "address": "tls://8.8.8.8",
        "detour": "wg-finland"
      },
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns-local"
      },
      {
        "rule_set": "antizapret",
        "server": "dns-google-proxy"
      }
    ],
    "final": "dns-google"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "client1",
          "uuid": $client_uuid,
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": $reality_private,
          "short_id": [$short_id],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "wireguard",
      "tag": "wg-finland",
      "server": $finland_ip,
      "server_port": 51820,
      "local_address": ["10.10.0.1/24"],
      "private_key": $ru_wg_private,
      "peer_public_key": $fi_wg_public,
      "pre_shared_key": $wg_psk,
      "mtu": 1280
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {"protocol": "dns", "outbound": "dns-out"},
      {"ip_is_private": true, "outbound": "direct"},
      {"rule_set": "geoip-ru", "outbound": "direct"},
      {"rule_set": "antizapret", "outbound": "wg-finland"}
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "antizapret",
        "format": "binary",
        "url": "https://github.com/savely-krasovsky/antizapret-sing-box/releases/latest/download/antizapret.srs",
        "download_detour": "direct",
        "update_interval": "6h"
      },
      {
        "type": "remote",
        "tag": "geoip-ru",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
        "download_detour": "direct",
        "update_interval": "24h"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}')

ok "Configs prepared with actual keys"

# ─── Step 5: Deploy Finland server ───

header "Deploying Finland server"

info "Installing Docker and WireGuard..."
ssh "$FINLAND_SSH_USER@$FINLAND_IP" << 'REMOTE_SETUP'
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

# Docker Compose plugin
if ! docker compose version &> /dev/null; then
    apt install -y -qq docker-compose-plugin
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

mkdir -p /opt/vpnsmart/wireguard
REMOTE_SETUP

ok "Finland: system configured"

info "Uploading WireGuard config..."
echo "$FINLAND_WG_CONF" | ssh "$FINLAND_SSH_USER@$FINLAND_IP" "cat > /opt/vpnsmart/wireguard/wg0.conf && chmod 600 /opt/vpnsmart/wireguard/wg0.conf"

# Upload docker-compose
cat "$SCRIPT_DIR/servers/finland/docker-compose.yml" | ssh "$FINLAND_SSH_USER@$FINLAND_IP" "cat > /opt/vpnsmart/docker-compose.yml"

info "Starting WireGuard container..."
ssh "$FINLAND_SSH_USER@$FINLAND_IP" "cd /opt/vpnsmart && docker compose down 2>/dev/null; docker compose up -d"

ok "Finland server deployed"

# ─── Step 6: Deploy Russia server ───

header "Deploying Russia server"

info "Installing Docker and sing-box..."
ssh "$RUSSIA_SSH_USER@$RUSSIA_IP" << 'REMOTE_SETUP'
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

# Docker Compose plugin
if ! docker compose version &> /dev/null; then
    apt install -y -qq docker-compose-plugin
fi

# Install jq for add-client script
apt install -y -qq jq

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
    ufw allow 443/tcp > /dev/null 2>&1
    ufw allow 443/udp > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
fi

mkdir -p /opt/vpnsmart/sing-box /opt/vpnsmart/scripts
REMOTE_SETUP

ok "Russia: system configured"

info "Uploading sing-box config..."
echo "$RUSSIA_SINGBOX_CONF" | ssh "$RUSSIA_SSH_USER@$RUSSIA_IP" "cat > /opt/vpnsmart/sing-box/config.json"

# Upload docker-compose
cat "$SCRIPT_DIR/servers/russia/docker-compose.yml" | ssh "$RUSSIA_SSH_USER@$RUSSIA_IP" "cat > /opt/vpnsmart/docker-compose.yml"

# Upload add-client script
cat "$SCRIPT_DIR/servers/russia/scripts/add-client.sh" | ssh "$RUSSIA_SSH_USER@$RUSSIA_IP" "cat > /opt/vpnsmart/scripts/add-client.sh && chmod +x /opt/vpnsmart/scripts/add-client.sh"

info "Starting sing-box container..."
ssh "$RUSSIA_SSH_USER@$RUSSIA_IP" "cd /opt/vpnsmart && docker compose down 2>/dev/null; docker compose up -d"

ok "Russia server deployed"

# ─── Step 7: Verify tunnel ───

header "Verifying tunnel connectivity"

sleep 5  # Wait for containers to initialize

info "Testing WireGuard tunnel (Russia → Finland)..."
TUNNEL_OK=false
for attempt in 1 2 3; do
    if ssh "$RUSSIA_SSH_USER@$RUSSIA_IP" "docker exec vpnsmart-singbox-russia ping -c 2 -W 3 10.10.0.2" &> /dev/null; then
        TUNNEL_OK=true
        break
    fi
    info "Attempt $attempt/3 — waiting..."
    sleep 5
done

if [ "$TUNNEL_OK" = true ]; then
    ok "WireGuard tunnel is UP"
else
    err "WireGuard tunnel is DOWN — check logs with: make logs-finland / make logs-russia"
fi

# ─── Step 8: Generate client config ───

header "Client configuration"

CLIENT_CONFIG=$(cat << EOF
{
  "log": {"level": "info"},
  "dns": {
    "servers": [
      {"tag": "proxy-dns", "address": "tls://8.8.8.8", "detour": "proxy"},
      {"tag": "direct-dns", "address": "local", "detour": "direct"}
    ],
    "rules": [{"outbound": "any", "server": "direct-dns"}],
    "final": "proxy-dns"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true,
      "strict_route": true,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$RUSSIA_IP",
      "server_port": 443,
      "uuid": "$CLIENT_UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "$REALITY_PUBLIC",
          "short_id": "$SHORT_ID"
        }
      }
    },
    {"type": "direct", "tag": "direct"},
    {"type": "dns", "tag": "dns-out"}
  ],
  "route": {
    "rules": [{"protocol": "dns", "outbound": "dns-out"}],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF
)

CLIENT_FILE="$SCRIPT_DIR/clients/client1.json"
echo "$CLIENT_CONFIG" > "$CLIENT_FILE"

ok "Client config saved to clients/client1.json"

# ─── Done ───

header "DEPLOYMENT COMPLETE"

echo -e "${GREEN}VPN is ready!${NC}"
echo ""
echo "Your servers:"
echo -e "  Russia:  ${CYAN}$RUSSIA_IP${NC} (sing-box + VLESS + Reality)"
echo -e "  Finland: ${CYAN}$FINLAND_IP${NC} (WireGuard exit node)"
echo ""
echo "Client setup:"
echo "  1. Install sing-box app:"
echo "     iOS:     Search 'sing-box' in App Store (SFI)"
echo "     Android: Search 'sing-box' in Google Play (SFA)"
echo "     macOS:   Search 'sing-box' in App Store (SFM)"
echo ""
echo "  2. Import config from: ${CYAN}clients/client1.json${NC}"
echo ""
echo "  3. Connect and verify:"
echo "     - vk.com → should show Russian IP"
echo "     - linkedin.com → should show Finnish IP"
echo ""
echo "Add more clients:"
echo -e "  ${CYAN}./deploy.sh add-client <name>${NC}"
echo ""
echo "Keys and credentials saved in: ${CYAN}.env${NC}"
echo -e "${RED}Do NOT share or commit the .env file!${NC}"
