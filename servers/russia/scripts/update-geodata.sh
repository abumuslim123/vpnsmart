#!/bin/bash
set -euo pipefail

# VPNSmart — Update Xray geodata (geosite_RU, geoip_RU)
# Runs via cron every 6 hours

GEODATA_DIR="/opt/vpnsmart/xray/geodata"
BASE_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
CONTAINER="vpnsmart-xray-russia"

mkdir -p "$GEODATA_DIR"

UPDATED=false

declare -A FILES=(["geosite_RU.dat"]="geosite.dat" ["geoip_RU.dat"]="geoip.dat")

for local_name in "${!FILES[@]}"; do
    remote_name="${FILES[$local_name]}"
    TMP=$(mktemp)
    if curl -sSL -o "$TMP" "$BASE_URL/$remote_name"; then
        file="$local_name"
        if ! cmp -s "$TMP" "$GEODATA_DIR/$file" 2>/dev/null; then
            mv "$TMP" "$GEODATA_DIR/$file"
            UPDATED=true
        else
            rm -f "$TMP"
        fi
    else
        rm -f "$TMP"
        echo "Failed to download $file" >&2
    fi
done

if [ "$UPDATED" = true ]; then
    docker restart "$CONTAINER" 2>/dev/null || true
    echo "Geodata updated, Xray restarted"
fi
