#!/bin/bash
set -euo pipefail

# VPNSmart Client Config Generator
# Generates a ready-to-import sing-box config for a client device

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 --server-ip <IP> --uuid <UUID> --public-key <KEY> --short-id <ID> [--output <file>]"
    echo ""
    echo "Options:"
    echo "  --server-ip    Russia server public IP"
    echo "  --uuid         Client VLESS UUID"
    echo "  --public-key   Reality public key"
    echo "  --short-id     Reality short ID"
    echo "  --output       Output file (default: stdout)"
    echo ""
    echo "Example:"
    echo "  $0 --server-ip 203.0.113.1 --uuid abc-123 --public-key XYZ --short-id 0123456789abcdef"
    exit 1
}

SERVER_IP=""
UUID=""
PUBLIC_KEY=""
SHORT_ID=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --server-ip) SERVER_IP="$2"; shift 2 ;;
        --uuid) UUID="$2"; shift 2 ;;
        --public-key) PUBLIC_KEY="$2"; shift 2 ;;
        --short-id) SHORT_ID="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$SERVER_IP" ] || [ -z "$UUID" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ]; then
    echo -e "${RED}Error: All parameters are required${NC}"
    usage
fi

CONFIG=$(cat << EOF
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
          "public_key": "$PUBLIC_KEY",
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
)

if [ -n "$OUTPUT" ]; then
    echo "$CONFIG" > "$OUTPUT"
    echo -e "${GREEN}Config saved to $OUTPUT${NC}"
else
    echo "$CONFIG"
fi
