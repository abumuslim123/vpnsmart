#!/bin/bash
set -euo pipefail

# VPNSmart Routing Tests
# Run from the Russia server to verify routing logic

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

RUSSIA_IP="${RUSSIA_IP:-}"
LATVIA_IP="${LATVIA_IP:-}"

if [ -z "$RUSSIA_IP" ] || [ -z "$LATVIA_IP" ]; then
    echo "Usage: RUSSIA_IP=x.x.x.x LATVIA_IP=y.y.y.y ./test-routing.sh"
    exit 1
fi

echo -e "${YELLOW}Testing blocked sites (should be reachable via Latvia)...${NC}"

BLOCKED_SITES=("linkedin.com" "instagram.com" "medium.com" "youtube.com")

for site in "${BLOCKED_SITES[@]}"; do
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
echo -e "${YELLOW}Testing Russian sites (should go direct)...${NC}"

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
echo -e "${YELLOW}Testing AmneziaWG tunnel connectivity...${NC}"

if ping -c 2 -W 3 10.10.0.2 &> /dev/null; then
    echo -e "${GREEN}[PASS]${NC} AmneziaWG tunnel to Latvia (10.10.0.2) is up"
    PASS=$((PASS + 1))
else
    echo -e "${RED}[FAIL]${NC} AmneziaWG tunnel to Latvia (10.10.0.2) is down"
    FAIL=$((FAIL + 1))
fi

echo ""
echo -e "${YELLOW}Testing policy routing...${NC}"

if ip rule show | grep -q "fwmark"; then
    echo -e "${GREEN}[PASS]${NC} fwmark policy rule exists"
    PASS=$((PASS + 1))
else
    echo -e "${RED}[FAIL]${NC} fwmark policy rule missing"
    FAIL=$((FAIL + 1))
fi

if ip route show table 100 2>/dev/null | grep -q "awg0"; then
    echo -e "${GREEN}[PASS]${NC} routing table 100 routes via awg0"
    PASS=$((PASS + 1))
else
    echo -e "${RED}[FAIL]${NC} routing table 100 not configured"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=============================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================="

exit $FAIL
