#!/bin/bash
set -euo pipefail

# VPNSmart Russia Server Setup
# Run as root on a fresh Ubuntu 22.04+ / Debian 12+ server

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== VPNSmart Russia Server Setup ===${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Update system
echo -e "${YELLOW}Updating system...${NC}"
apt update && apt upgrade -y

# Install Docker
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Installing Docker...${NC}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# Install docker-compose plugin
if ! docker compose version &> /dev/null; then
    echo -e "${YELLOW}Installing Docker Compose plugin...${NC}"
    apt install -y docker-compose-plugin
fi

# Install jq for config manipulation
apt install -y jq

# Apply sysctl settings
echo -e "${YELLOW}Applying sysctl settings...${NC}"
cat > /etc/sysctl.d/99-vpnsmart.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
SYSCTL
sysctl --system

# Configure firewall
echo -e "${YELLOW}Configuring firewall...${NC}"
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    ufw --force enable
else
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p udp --dport 443 -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -P INPUT DROP
fi

echo -e "${GREEN}=== Russia server setup complete ===${NC}"
echo ""
echo "Next steps:"
echo "1. Edit sing-box/config.json — replace all \${...} placeholders with actual values"
echo "2. Run: docker compose up -d"
echo "3. Verify: docker compose logs -f"
echo "4. Test: curl -x socks5://127.0.0.1:1080 https://ifconfig.me"
