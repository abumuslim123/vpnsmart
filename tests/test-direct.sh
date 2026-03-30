#!/bin/bash
set -euo pipefail

# VPNSmart Direct Routing Test
# Verifies that traffic to Russian resources exits with a Russian IP

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== VPNSmart Direct Route Verification ===${NC}"
echo ""

echo -e "${YELLOW}Checking exit IP...${NC}"
EXIT_IP=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "FAILED")
echo "Current exit IP: $EXIT_IP"
echo ""

echo -e "${YELLOW}Checking IP geolocation...${NC}"
GEO_INFO=$(curl -s --max-time 10 "http://ip-api.com/json/$EXIT_IP?fields=country,countryCode,city,isp" 2>/dev/null || echo "{}")
echo "Geolocation: $GEO_INFO"
echo ""

COUNTRY=$(echo "$GEO_INFO" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)

if [ "$COUNTRY" = "RU" ]; then
    echo -e "${GREEN}[PASS]${NC} Default traffic exits through Russia"
else
    echo -e "${YELLOW}[INFO]${NC} Default traffic exits through $COUNTRY (expected RU for direct route)"
fi

echo ""
echo -e "${YELLOW}Testing latency to Russian services...${NC}"

SITES=("ya.ru" "vk.com" "mail.ru" "gosuslugi.ru")

for site in "${SITES[@]}"; do
    START=$(date +%s%N)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --connect-timeout 5 "https://$site" 2>/dev/null || echo "000")
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000000 ))

    if [ "$HTTP_CODE" != "000" ]; then
        echo -e "  ${GREEN}$site${NC}: HTTP $HTTP_CODE (${LATENCY}ms)"
    else
        echo -e "  ${RED}$site${NC}: unreachable"
    fi
done
