#!/usr/bin/env bash
# Analyze throughput per conversation from pcap
# Usage: ./analyze-throughput.sh <pcap-file>
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
OUTPUT="$PROJECT_DIR/summaries/throughput-${TIMESTAMP}.txt"

{
    echo "=== Throughput Analysis ==="
    echo "Source: $PCAP"
    echo "Date: $(date)"
    echo ""

    echo "--- TCP Conversation Summary ---"
    tshark -r "$PCAP" -q -z conv,tcp 2>/dev/null | head -40 || echo "(failed)"
    echo ""

    echo "--- Bandwidth Over Time (1s intervals) ---"
    tshark -r "$PCAP" -q -z io,stat,1 2>/dev/null || echo "(failed)"
    echo ""

    echo "--- Top Talkers by Bytes ---"
    tshark -r "$PCAP" -q -z endpoints,ip 2>/dev/null | head -20 || echo "(failed)"
    echo ""

    echo "--- Protocol Distribution ---"
    tshark -r "$PCAP" -q -z ptype,tree 2>/dev/null | head -30 || echo "(failed)"

} > "$OUTPUT" 2>&1

echo "Analysis written to: $OUTPUT"
echo "Lines: $(wc -l < "$OUTPUT")"
cat "$OUTPUT"
