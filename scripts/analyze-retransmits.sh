#!/usr/bin/env bash
# Analyze TCP retransmissions from pcap
# Usage: ./analyze-retransmits.sh <pcap-file>
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
OUTPUT="$PROJECT_DIR/summaries/retransmits-${TIMESTAMP}.txt"

{
    echo "=== TCP Retransmission Analysis ==="
    echo "Source: $PCAP"
    echo "Date: $(date)"
    echo ""

    echo "--- Overall Stats ---"
    TOTAL=$(tshark -r "$PCAP" -q -z io,stat,0 2>/dev/null | tail -3 | head -1 || echo "N/A")
    RETRANS=$(tshark -r "$PCAP" -Y "tcp.analysis.retransmission" -q -z io,stat,0 2>/dev/null | tail -3 | head -1 || echo "N/A")
    echo "Total traffic:   $TOTAL"
    echo "Retransmissions: $RETRANS"
    echo ""

    echo "--- Retransmissions Over Time (1s intervals) ---"
    tshark -r "$PCAP" -q -z io,stat,1,"tcp.analysis.retransmission" 2>/dev/null || echo "(tshark analysis failed)"
    echo ""

    echo "--- Top Retransmitting Conversations ---"
    tshark -r "$PCAP" -Y "tcp.analysis.retransmission" -T fields -e ip.src -e ip.dst -e tcp.srcport -e tcp.dstport 2>/dev/null \
        | sort | uniq -c | sort -rn | head -20 || echo "(no retransmissions found)"
    echo ""

    echo "--- Duplicate ACKs (congestion indicator) ---"
    tshark -r "$PCAP" -q -z io,stat,1,"tcp.analysis.duplicate_ack" 2>/dev/null || echo "(none)"
    echo ""

    echo "--- Fast Retransmissions vs Timeout Retransmissions ---"
    echo "Fast retransmits:"
    tshark -r "$PCAP" -Y "tcp.analysis.fast_retransmission" -T fields -e frame.number 2>/dev/null | wc -l || echo "0"
    echo "RTO retransmits:"
    tshark -r "$PCAP" -Y "tcp.analysis.retransmission and not tcp.analysis.fast_retransmission" -T fields -e frame.number 2>/dev/null | wc -l || echo "0"
    echo ""

    echo "--- Window Size Analysis (zero windows = buffer exhaustion) ---"
    tshark -r "$PCAP" -Y "tcp.analysis.zero_window" -T fields -e ip.src -e ip.dst 2>/dev/null \
        | sort | uniq -c | sort -rn | head -10 || echo "(no zero windows)"

} > "$OUTPUT" 2>&1

echo "Analysis written to: $OUTPUT"
echo "Lines: $(wc -l < "$OUTPUT")"
cat "$OUTPUT"
