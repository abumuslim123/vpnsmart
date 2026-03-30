#!/bin/bash
# VPNSmart — Health monitor
# Checks tunnel, Xray, disk and sends Telegram alerts on failure.
# Add to cron: */5 * * * * /opt/vpnsmart/scripts/monitor.sh

set -euo pipefail

# Load bot credentials for alerts
ENV_FILE="/opt/vpnsmart/.env.bot"
if [ ! -f "$ENV_FILE" ]; then
    exit 0
fi
source "$ENV_FILE"

if [ "$BOT_TOKEN" = "CHANGE_ME" ] || [ -z "${ADMIN_ID:-}" ]; then
    exit 0
fi

STATE_FILE="/tmp/vpnsmart-monitor-state"
ERRORS=()

# --- Checks ---

# 1. AmneziaWG tunnel
if ! ping -c 1 -W 3 10.10.0.2 &> /dev/null; then
    ERRORS+=("AmneziaWG tunnel DOWN (10.10.0.2 unreachable)")
fi

# 2. Xray container
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q vpnsmart-xray-russia; then
    ERRORS+=("Xray container not running")
fi

# 3. Port 443
if ! ss -tlnp 2>/dev/null | grep -q ':443 '; then
    ERRORS+=("Port 443 not listening")
fi

# 4. Bot container
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q vpnsmart-bot; then
    ERRORS+=("Bot container not running")
fi

# 5. Disk space (warn at 90%)
DISK_USAGE=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
if [ "${DISK_USAGE:-0}" -gt 90 ]; then
    ERRORS+=("Disk usage: ${DISK_USAGE}%")
fi

# 6. AWG handshake freshness (warn if >3 min)
LAST_HANDSHAKE=$(awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2}')
if [ -n "$LAST_HANDSHAKE" ] && [ "$LAST_HANDSHAKE" != "0" ]; then
    NOW=$(date +%s)
    AGE=$(( NOW - LAST_HANDSHAKE ))
    if [ "$AGE" -gt 180 ]; then
        ERRORS+=("AWG handshake stale (${AGE}s ago)")
    fi
fi

# --- Alert logic ---

if [ ${#ERRORS[@]} -eq 0 ]; then
    # All clear — remove state file if it exists (recovery)
    if [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE"
        MSG="✅ VPNSmart recovered. All checks passing."
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="$ADMIN_ID" -d text="$MSG" > /dev/null 2>&1
    fi
    exit 0
fi

# Build alert message
ALERT="⚠️ VPNSmart Alert\n\n"
for err in "${ERRORS[@]}"; do
    ALERT+="• ${err}\n"
done
ALERT+="\nServer: $(hostname) ($(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo 'unknown'))"

# Only alert if state changed (avoid spam)
CURRENT_STATE=$(printf '%s\n' "${ERRORS[@]}" | sort | md5sum | awk '{print $1}')
PREV_STATE=""
if [ -f "$STATE_FILE" ]; then
    PREV_STATE=$(cat "$STATE_FILE")
fi

if [ "$CURRENT_STATE" != "$PREV_STATE" ]; then
    echo "$CURRENT_STATE" > "$STATE_FILE"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$ADMIN_ID" -d text="$ALERT" -d parse_mode="HTML" > /dev/null 2>&1
fi
