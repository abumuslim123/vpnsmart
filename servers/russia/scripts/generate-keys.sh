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
for cmd in wg openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: '$cmd' is not installed.${NC}"
        echo "Install: apt install wireguard-tools openssl"
        exit 1
    fi
done

echo -e "${YELLOW}--- AmneziaWG Keys (Russia Server) ---${NC}"
RU_PRIVATE=$(wg genkey)
RU_PUBLIC=$(echo "$RU_PRIVATE" | wg pubkey)
echo "RUSSIA_AWG_PRIVATE_KEY=$RU_PRIVATE"
echo "RUSSIA_AWG_PUBLIC_KEY=$RU_PUBLIC"
echo ""

echo -e "${YELLOW}--- AmneziaWG Keys (Latvia Server) ---${NC}"
LV_PRIVATE=$(wg genkey)
LV_PUBLIC=$(echo "$LV_PRIVATE" | wg pubkey)
echo "LATVIA_AWG_PRIVATE_KEY=$LV_PRIVATE"
echo "LATVIA_AWG_PUBLIC_KEY=$LV_PUBLIC"
echo ""

echo -e "${YELLOW}--- AmneziaWG Preshared Key ---${NC}"
PSK=$(wg genpsk)
echo "AWG_PRESHARED_KEY=$PSK"
echo ""

echo -e "${YELLOW}--- AmneziaWG Obfuscation Parameters ---${NC}"
echo "AWG_JC=$((RANDOM % 5 + 4))"
echo "AWG_JMIN=$((RANDOM % 30 + 50))"
echo "AWG_JMAX=$((RANDOM % 700 + 800))"
echo "AWG_S1=$((RANDOM * RANDOM))"
echo "AWG_S2=$((RANDOM * RANDOM))"
echo "AWG_H1=$((RANDOM * RANDOM))"
echo "AWG_H2=$((RANDOM * RANDOM))"
echo "AWG_H3=$((RANDOM * RANDOM))"
echo "AWG_H4=$((RANDOM * RANDOM))"
echo ""

echo -e "${YELLOW}--- VLESS Reality Short ID ---${NC}"
SHORT_ID=$(openssl rand -hex 8)
echo "REALITY_SHORT_ID=$SHORT_ID"
echo ""

echo -e "${YELLOW}--- Client UUID ---${NC}"
CLIENT_UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
echo "CLIENT_UUID=$CLIENT_UUID"
echo ""

echo -e "${YELLOW}--- Reality Keypair ---${NC}"
echo "Generate on a server with Docker:"
echo "  docker run --rm ghcr.io/xtls/xray-core:latest x25519"
echo ""

echo -e "${GREEN}=== Save these values securely! ===${NC}"
echo -e "${RED}Do NOT commit them to the repository.${NC}"
echo ""
echo "Next steps:"
echo "1. Generate Reality keypair on the server (see above)"
echo "2. Create a .env file (git-ignored) with all these values"
echo "3. Run ./deploy.sh"
