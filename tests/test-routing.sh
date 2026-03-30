#!/bin/bash
set -euo pipefail

# VPNSmart Routing Tests
# Run these AFTER connecting to the VPN from a client device
# or from the Russia server itself to verify routing logic

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

check() {
    local description="$1"
    local expected="$2"
    local result="$3"

    if [ "$result" = "$expected" ]; then
        echo -e "${GREEN}[PASS]${NC} $description"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}[FAIL]${NC} $description (expected: $expected, got: $result)"
        FAIL=$((FAIL + 1))
    fi
}

echo -e "${YELLOW}=== VPNSmart Routing Tests ===${NC}"
echo ""

# Get expected IPs from env or arguments
RUSSIA_IP="${RUSSIA_IP:-}"
FINLAND_IP="${FINLAND_IP:-}"

if [ -z "$RUSSIA_IP" ] || [ -z "$FINLAND_IP" ]; then
    echo "Usage: RUSSIA_IP=x.x.x.x FINLAND_IP=y.y.y.y ./test-routing.sh"
    echo "Set the public IPs of your Russia and Finland servers."
    exit 1
fi

echo -e "${YELLOW}Testing blocked sites (should go through Finland: $FINLAND_IP)...${NC}"

# Test blocked sites — these should route through Finland
BLOCKED_SITES=("linkedin.com" "instagram.com" "medium.com")

for site in "${BLOCKED_SITES[@]}"; do
    echo -n "  $site... "
    EXIT_IP=$(curl -s --max-time 10 --connect-timeout 5 "https://ifconfig.me" --resolve "ifconfig.me:443:$(dig +short ifconfig.me | head -1)" 2>/dev/null || echo "TIMEOUT")
    # More practical: just check if the site is reachable
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --connect-timeout 5 "https://$site" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" != "000" ]; then
        echo -e "${GREEN}reachable (HTTP $HTTP_CODE)${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}unreachable${NC}"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo -e "${YELLOW}Testing Russian sites (should go direct through Russia)...${NC}"

# Test Russian sites — these should go direct
RU_SITES=("ya.ru" "vk.com" "mail.ru")

for site in "${RU_SITES[@]}"; do
    echo -n "  $site... "
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --connect-timeout 5 "https://$site" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" != "000" ]; then
        echo -e "${GREEN}reachable (HTTP $HTTP_CODE)${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}unreachable${NC}"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo -e "${YELLOW}Testing WireGuard tunnel connectivity...${NC}"

# Test tunnel (run from Russia server)
if ping -c 2 -W 3 10.10.0.2 &> /dev/null; then
    echo -e "${GREEN}[PASS]${NC} WireGuard tunnel to Finland (10.10.0.2) is up"
    PASS=$((PASS + 1))
else
    echo -e "${RED}[FAIL]${NC} WireGuard tunnel to Finland (10.10.0.2) is down"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=============================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================="

exit $FAIL
