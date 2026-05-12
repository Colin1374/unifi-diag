#!/usr/bin/env bash
# Analyze DNS response times from pcap
# Usage: ./analyze-dns.sh <pcap-file>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <pcap-file>"
    exit 1
fi

PCAP="$1"
if [[ ! -f "$PCAP" ]]; then
    echo "ERROR: File not found: $PCAP"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$PROJECT_DIR/summaries/dns-${TIMESTAMP}.txt"

{
    echo "=== DNS Analysis ==="
    echo "Source: $PCAP"
    echo "Date: $(date)"
    echo ""

    echo "--- DNS Response Times ---"
    tshark -r "$PCAP" -Y "dns.flags.response==1" \
        -T fields -e frame.time_relative -e dns.qry.name -e dns.time 2>/dev/null \
        | sort -t$'\t' -k3 -rn | head -30 || echo "(no DNS in capture)"
    echo ""

    echo "--- Slow DNS (>100ms) ---"
    tshark -r "$PCAP" -Y "dns.flags.response==1 && dns.time > 0.1" \
        -T fields -e dns.qry.name -e dns.time -e dns.a 2>/dev/null \
        | sort -t$'\t' -k2 -rn || echo "(none — good!)"
    echo ""

    echo "--- DNS Failure Responses (NXDOMAIN, SERVFAIL) ---"
    tshark -r "$PCAP" -Y "dns.flags.rcode != 0" \
        -T fields -e dns.qry.name -e dns.flags.rcode 2>/dev/null \
        | sort | uniq -c | sort -rn | head -20 || echo "(none)"
    echo ""

    echo "--- Top Queried Domains ---"
    tshark -r "$PCAP" -Y "dns.flags.response==0" \
        -T fields -e dns.qry.name 2>/dev/null \
        | sort | uniq -c | sort -rn | head -20 || echo "(none)"

} > "$OUTPUT" 2>&1

echo "Analysis written to: $OUTPUT"
echo "Lines: $(wc -l < "$OUTPUT")"
cat "$OUTPUT"
