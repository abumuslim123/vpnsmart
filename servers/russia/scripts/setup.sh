#!/bin/bash
set -euo pipefail

# VPNSmart Russia Server Setup
# Run as root on a fresh Ubuntu 22.04+ server
# Installs: Docker, AmneziaWG, Xray geodata

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${YELLOW}→ $1${NC}"; }
ok()    { echo -e "${GREEN}✓ $1${NC}"; }
err()   { echo -e "${RED}✗ $1${NC}"; }

if [ "$(id -u)" -ne 0 ]; then
    err "Run as root"
    exit 1
fi

echo -e "${GREEN}=== VPNSmart Russia Server Setup ===${NC}"

# ─── System update ───

info "Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt upgrade -y -qq

# ─── Docker ───

if ! command -v docker &> /dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

if ! docker compose version &> /dev/null; then
    info "Installing Docker Compose plugin..."
    apt install -y -qq docker-compose-plugin
fi

apt install -y -qq jq curl

ok "Docker ready"

# ─── AmneziaWG ───

info "Installing AmneziaWG..."

install_awg_ppa() {
    apt install -y -qq software-properties-common
    add-apt-repository -y ppa:amneziavpn/ppa
    apt update -qq
    apt install -y -qq amneziawg amneziawg-tools
}

install_awg_go() {
    info "PPA failed, building amneziawg-go from source..."
    apt install -y -qq git golang-go make
    cd /tmp
    rm -rf amneziawg-go
    git clone https://github.com/amnezia-vpn/amneziawg-go.git
    cd amneziawg-go
    make
    make install
    cd /
    rm -rf /tmp/amneziawg-go
}

if ! command -v awg &> /dev/null; then
    install_awg_ppa || install_awg_go
fi

apt install -y -qq wireguard-tools

ok "AmneziaWG installed"

# ─── sysctl ───

info "Configuring sysctl..."
cat > /etc/sysctl.d/99-vpnsmart.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
SYSCTL
sysctl --system > /dev/null

ok "sysctl configured"

# ─── Firewall ───

info "Configuring firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1
    ufw allow 443/udp > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    ok "UFW configured (22/tcp, 443/tcp+udp)"
else
    info "UFW not found, skipping firewall setup"
fi

# ─── AmneziaWG tunnel ───

mkdir -p /etc/amneziawg

if [ -f /etc/amneziawg/awg0.conf ]; then
    info "Starting AmneziaWG tunnel..."
    systemctl enable awg-quick@awg0
    systemctl restart awg-quick@awg0
    ok "AmneziaWG tunnel started"

    # Disable rp_filter for awg0 after interface is up
    sysctl -w net.ipv4.conf.awg0.rp_filter=0 > /dev/null 2>&1 || true
else
    info "awg0.conf not found — upload it to /etc/amneziawg/awg0.conf"
fi

# ─── Xray geodata ───

GEODATA_DIR="/opt/vpnsmart/xray/geodata"
mkdir -p "$GEODATA_DIR"

info "Downloading geodata (geosite_RU, geoip_RU)..."
BASE_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
curl -sSL -o "$GEODATA_DIR/geosite_RU.dat" "$BASE_URL/geosite_RU.dat" || err "Failed to download geosite_RU.dat"
curl -sSL -o "$GEODATA_DIR/geoip_RU.dat" "$BASE_URL/geoip_RU.dat" || err "Failed to download geoip_RU.dat"

ok "Geodata downloaded"

# ─── Cron for geodata updates ───

CRON_SCRIPT="/opt/vpnsmart/scripts/update-geodata.sh"
if [ -f "$CRON_SCRIPT" ]; then
    chmod +x "$CRON_SCRIPT"
    CRON_LINE="0 */6 * * * $CRON_SCRIPT"
    (crontab -l 2>/dev/null | grep -v update-geodata; echo "$CRON_LINE") | crontab -
    ok "Cron job set: geodata updates every 6 hours"
fi

# ─── Done ───

echo ""
ok "Russia server setup complete"
echo ""
echo "Next steps:"
echo "  1. Upload awg0.conf to /etc/amneziawg/awg0.conf"
echo "  2. systemctl enable --now awg-quick@awg0"
echo "  3. Edit xray/config.json — replace placeholders"
echo "  4. docker compose up -d"
