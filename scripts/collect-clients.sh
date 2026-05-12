#!/usr/bin/env bash
# Pull full client list from UDR and build/update network map
# Usage: ./collect-clients.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
UDR_HOST="udr"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RAW_OUTPUT="$PROJECT_DIR/summaries/clients-raw-${TIMESTAMP}.txt"
OUTPUT="$PROJECT_DIR/summaries/clients-${TIMESTAMP}.txt"

echo "=== Collecting client list from UDR ==="

# Try multiple methods — UDR firmware varies on what's available

# Method 1: UniFi OS API (most reliable on UDR 7+)
echo "[1] Trying UniFi OS API..."
API_RESULT=$(ssh "$UDR_HOST" "curl -s --unix-socket /run/unifi-core/api.sock http://localhost/proxy/network/api/s/default/stat/sta" 2>/dev/null) || API_RESULT=""

if [[ -n "$API_RESULT" && "$API_RESULT" != *"error"* && "$API_RESULT" != *"unauthorized"* ]]; then
    echo "$API_RESULT" > "$RAW_OUTPUT"
    echo "    API method worked"

    # Parse JSON into readable table
    {
        echo "=== UDR Client List ==="
        echo "Collected: $(date)"
        echo "Method: UniFi OS local API"
        echo ""
        printf "%-30s %-15s %-19s %-10s %-8s %-6s %s\n" "NAME" "IP" "MAC" "CONN" "RSSI" "VLAN" "NOTES"
        printf "%-30s %-15s %-19s %-10s %-8s %-6s %s\n" "----" "--" "---" "----" "----" "----" "-----"

        # Parse with python if available, else jq
        if command -v python3 &>/dev/null; then
            python3 -c "
import json, sys
data = json.load(sys.stdin)
clients = data.get('data', [])
for c in sorted(clients, key=lambda x: [int(p) for p in x.get('ip','0.0.0.0').split('.')]):
    name = c.get('name', c.get('hostname', '(unknown)'))[:30]
    ip = c.get('ip', 'N/A')
    mac = c.get('mac', 'N/A')
    is_wired = c.get('is_wired', False)
    conn = 'wired' if is_wired else 'wifi'
    rssi = str(c.get('rssi', '-')) if not is_wired else '-'
    vlan = str(c.get('vlan', c.get('network_id', '-')))[:6]
    notes = ''
    if c.get('is_guest', False):
        notes += 'guest '
    if not is_wired:
        radio = c.get('radio', '')
        channel = c.get('channel', '')
        if radio or channel:
            notes += f'{radio} ch{channel} '
    print(f'{name:<30} {ip:<15} {mac:<19} {conn:<10} {rssi:<8} {vlan:<6} {notes}')
" < "$RAW_OUTPUT"
        elif command -v jq &>/dev/null; then
            jq -r '.data[] | [
                (.name // .hostname // "(unknown)")[:30],
                (.ip // "N/A"),
                (.mac // "N/A"),
                (if .is_wired then "wired" else "wifi" end),
                (if .is_wired then "-" else (.rssi // "-" | tostring) end)
            ] | @tsv' < "$RAW_OUTPUT" | sort -t$'\t' -k2 -V
        else
            echo "(need python3 or jq to parse — raw JSON in $RAW_OUTPUT)"
        fi
    } > "$OUTPUT"

    echo ""
    echo "Client list written to: $OUTPUT"
    echo "Raw JSON: $RAW_OUTPUT"
    echo "Lines: $(wc -l < "$OUTPUT")"
    echo ""
    cat "$OUTPUT"
    exit 0
fi

# Method 2: ubnt-device-info (older UDR firmware)
echo "[2] Trying ubnt-device-info..."
UBNT_RESULT=$(ssh "$UDR_HOST" "ubnt-device-info clients 2>/dev/null" 2>/dev/null) || UBNT_RESULT=""

if [[ -n "$UBNT_RESULT" ]]; then
    {
        echo "=== UDR Client List ==="
        echo "Collected: $(date)"
        echo "Method: ubnt-device-info"
        echo ""
        echo "$UBNT_RESULT"
    } > "$OUTPUT"

    echo "Client list written to: $OUTPUT"
    cat "$OUTPUT"
    exit 0
fi

# Method 3: Fallback — ARP + DHCP leases
echo "[3] Falling back to ARP table + DHCP leases..."
{
    echo "=== UDR Client List (fallback) ==="
    echo "Collected: $(date)"
    echo "Method: ARP + DHCP leases (API/ubnt-device-info not available)"
    echo ""

    echo "--- ARP Table ---"
    ssh "$UDR_HOST" "arp -a 2>/dev/null || ip neigh show" 2>/dev/null | sort -t. -k4 -n || echo "(failed)"
    echo ""

    echo "--- DHCP Leases ---"
    ssh "$UDR_HOST" "cat /run/dnsmasq.leases 2>/dev/null || cat /var/run/dnsmasq.leases 2>/dev/null || cat /data/udapi-config/dnsmasq.lease 2>/dev/null" 2>/dev/null || echo "(lease file not found)"
} > "$OUTPUT"

echo "Client list written to: $OUTPUT"
cat "$OUTPUT"
