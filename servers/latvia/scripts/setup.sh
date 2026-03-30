#!/bin/bash
set -euo pipefail

# VPNSmart — Latvia server setup (AmneziaWG exit node)

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

# ─── System update ───

info "Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt upgrade -y -qq

# ─── Install AmneziaWG ───

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

# Install wireguard-tools for wg CLI compatibility
apt install -y -qq wireguard-tools

ok "AmneziaWG installed: $(awg --version 2>&1 || echo 'ok')"

# ─── sysctl ───

info "Configuring sysctl..."
cat > /etc/sysctl.d/99-vpnsmart.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
SYSCTL
sysctl --system > /dev/null

ok "IP forwarding enabled"

# ─── Firewall ───

info "Configuring firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow 51820/udp > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    ok "UFW configured (22/tcp, 51820/udp)"
else
    info "UFW not found, skipping firewall setup"
fi

# ─── AmneziaWG directory ───

mkdir -p /etc/amneziawg

# ─── Enable AmneziaWG service ───

if [ -f /etc/amneziawg/awg0.conf ]; then
    info "Starting AmneziaWG..."
    systemctl enable awg-quick@awg0
    systemctl restart awg-quick@awg0
    ok "AmneziaWG started"
else
    info "awg0.conf not found yet — upload it to /etc/amneziawg/awg0.conf and run:"
    info "  systemctl enable --now awg-quick@awg0"
fi

ok "Latvia server setup complete"
