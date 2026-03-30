#!/bin/bash
set -euo pipefail

# VPNSmart — Add New Client
# Usage: ./add-client.sh <client-name> <server-ip> <reality-public-key> <reality-short-id>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_FILE="../sing-box/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/$CONFIG_FILE"

if [ $# -lt 4 ]; then
    echo "Usage: $0 <client-name> <server-ip> <reality-public-key> <reality-short-id>"
    echo ""
    echo "Example:"
    echo "  $0 my-phone 203.0.113.1 ABCdef123... 0123456789abcdef"
    exit 1
fi

CLIENT_NAME="$1"
SERVER_IP="$2"
REALITY_PUBLIC_KEY="$3"
SHORT_ID="$4"

# Check sing-box is installed (for UUID generation)
if ! command -v sing-box &> /dev/null; then
    # Try docker
    if command -v docker &> /dev/null; then
        UUID=$(docker run --rm ghcr.io/sagernet/sing-box generate uuid)
    else
        # Fallback: use uuidgen
        UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    fi
else
    UUID=$(sing-box generate uuid)
fi

echo -e "${GREEN}=== New Client: $CLIENT_NAME ===${NC}"
echo "UUID: $UUID"
echo ""

# Add user to sing-box config
if [ -f "$CONFIG_PATH" ]; then
    echo -e "${YELLOW}Adding user to sing-box config...${NC}"
    TEMP_FILE=$(mktemp)
    jq --arg name "$CLIENT_NAME" --arg uuid "$UUID" \
        '.inbounds[0].users += [{"name": $name, "uuid": $uuid, "flow": "xtls-rprx-vision"}]' \
        "$CONFIG_PATH" > "$TEMP_FILE" && mv "$TEMP_FILE" "$CONFIG_PATH"
    echo -e "${GREEN}User added to config.json${NC}"
    echo ""
    echo -e "${YELLOW}Restart sing-box to apply:${NC}"
    echo "  docker compose restart sing-box"
else
    echo -e "${YELLOW}Config file not found at $CONFIG_PATH${NC}"
    echo "Add this user manually to config.json inbounds[0].users:"
    echo "  {\"name\": \"$CLIENT_NAME\", \"uuid\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"}"
fi

echo ""
echo -e "${GREEN}=== Client Config ===${NC}"
echo "Import the following JSON into the sing-box app (SFI/SFA/SFM):"
echo ""

cat << EOF
{
  "log": {"level": "info"},
  "dns": {
    "servers": [
      {
        "tag": "proxy-dns",
        "address": "tls://8.8.8.8",
        "detour": "proxy"
      },
      {
        "tag": "direct-dns",
        "address": "local",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "direct-dns"
      }
    ],
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
      "server": "$SERVER_IP",
      "server_port": 443,
      "uuid": "$UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "$REALITY_PUBLIC_KEY",
          "short_id": "$SHORT_ID"
        }
      }
    },
    {"type": "direct", "tag": "direct"},
    {"type": "dns", "tag": "dns-out"}
  ],
  "route": {
    "rules": [
      {"protocol": "dns", "outbound": "dns-out"}
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF
