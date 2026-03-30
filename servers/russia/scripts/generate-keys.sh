#!/bin/bash
set -euo pipefail

# VPNSmart Key Generator
# Generates all cryptographic material needed for deployment.
# Keys are printed to stdout — save them securely, they are NOT stored in the repo.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== VPNSmart Key Generation ===${NC}"
echo ""

# Check dependencies
for cmd in wg sing-box; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: '$cmd' is not installed.${NC}"
        echo "Install WireGuard: apt install wireguard-tools"
        echo "Install sing-box: https://sing-box.sagernet.org/installation/"
        exit 1
    fi
done

echo -e "${YELLOW}--- WireGuard Keys (Russia Server) ---${NC}"
RU_PRIVATE=$(wg genkey)
RU_PUBLIC=$(echo "$RU_PRIVATE" | wg pubkey)
echo "RUSSIA_WG_PRIVATE_KEY=$RU_PRIVATE"
echo "RUSSIA_WG_PUBLIC_KEY=$RU_PUBLIC"
echo ""

echo -e "${YELLOW}--- WireGuard Keys (Finland Server) ---${NC}"
FI_PRIVATE=$(wg genkey)
FI_PUBLIC=$(echo "$FI_PRIVATE" | wg pubkey)
echo "FINLAND_WG_PRIVATE_KEY=$FI_PRIVATE"
echo "FINLAND_WG_PUBLIC_KEY=$FI_PUBLIC"
echo ""

echo -e "${YELLOW}--- WireGuard Preshared Key ---${NC}"
PSK=$(wg genpsk)
echo "WG_PRESHARED_KEY=$PSK"
echo ""

echo -e "${YELLOW}--- VLESS Reality Keypair ---${NC}"
REALITY_OUTPUT=$(sing-box generate reality-keypair)
REALITY_PRIVATE=$(echo "$REALITY_OUTPUT" | grep -i private | awk '{print $NF}')
REALITY_PUBLIC=$(echo "$REALITY_OUTPUT" | grep -i public | awk '{print $NF}')
echo "REALITY_PRIVATE_KEY=$REALITY_PRIVATE"
echo "REALITY_PUBLIC_KEY=$REALITY_PUBLIC"
echo ""

echo -e "${YELLOW}--- VLESS Short ID ---${NC}"
SHORT_ID=$(openssl rand -hex 8)
echo "REALITY_SHORT_ID=$SHORT_ID"
echo ""

echo -e "${YELLOW}--- Client UUID (first client) ---${NC}"
CLIENT_UUID=$(sing-box generate uuid)
echo "CLIENT_UUID=$CLIENT_UUID"
echo ""

echo -e "${GREEN}=== Save these values securely! ===${NC}"
echo -e "${RED}Do NOT commit them to the repository.${NC}"
echo ""
echo "Next steps:"
echo "1. Create a .env file (git-ignored) with these values"
echo "2. Run 'make deploy-finland' and 'make deploy-russia'"
