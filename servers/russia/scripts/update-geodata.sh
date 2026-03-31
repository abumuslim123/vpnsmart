#!/bin/bash
set -euo pipefail

# VPNSmart — Update Xray geodata (geosite_RU, geoip_RU)
# Runs via cron every 6 hours

GEODATA_DIR="/opt/vpnsmart/xray/geodata"
BASE_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
CONTAINER="vpnsmart-xray-russia"
MIN_FILE_SIZE=100000  # 100KB minimum — valid geodata files are 20MB+

mkdir -p "$GEODATA_DIR"

UPDATED=false

declare -A FILES=(["geosite_RU.dat"]="geosite.dat" ["geoip_RU.dat"]="geoip.dat")

for local_name in "${!FILES[@]}"; do
    remote_name="${FILES[$local_name]}"
    TMP=$(mktemp)
    if curl -sSL -o "$TMP" "$BASE_URL/$remote_name"; then
        # Verify downloaded file is not empty/corrupt
        FILE_SIZE=$(stat -c%s "$TMP" 2>/dev/null || stat -f%z "$TMP" 2>/dev/null || echo "0")
        if [ "$FILE_SIZE" -lt "$MIN_FILE_SIZE" ]; then
            echo "Downloaded $remote_name is too small (${FILE_SIZE} bytes), skipping" >&2
            rm -f "$TMP"
            continue
        fi
        if ! cmp -s "$TMP" "$GEODATA_DIR/$local_name" 2>/dev/null; then
            mv "$TMP" "$GEODATA_DIR/$local_name"
            UPDATED=true
        else
            rm -f "$TMP"
        fi
    else
        rm -f "$TMP"
        echo "Failed to download $remote_name" >&2
    fi
done

if [ "$UPDATED" = true ]; then
    docker restart "$CONTAINER" 2>/dev/null || true
    echo "Geodata updated, Xray restarted"
fi
