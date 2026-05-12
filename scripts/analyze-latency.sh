#!/usr/bin/env bash
# Analyze TCP RTT / latency from pcap
# Usage: ./analyze-latency.sh <pcap-file>
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
OUTPUT="$PROJECT_DIR/summaries/latency-${TIMESTAMP}.txt"

{
    echo "=== Latency / RTT Analysis ==="
    echo "Source: $PCAP"
    echo "Date: $(date)"
    echo ""

    echo "--- TCP Handshake RTT (SYN → SYN-ACK) ---"
    tshark -r "$PCAP" -Y "tcp.flags.syn==1 && tcp.flags.ack==1" \
        -T fields -e ip.src -e ip.dst -e tcp.analysis.initial_rtt 2>/dev/null \
        | sort -t$'\t' -k3 -rn | head -20 || echo "(none)"
    echo ""

    echo "--- RTT Stats per Conversation ---"
    tshark -r "$PCAP" -q -z rtt,tree 2>/dev/null || echo "(rtt tree not available, using fallback)"
    echo ""

    echo "--- TCP ACK RTT samples (first 50) ---"
    tshark -r "$PCAP" -T fields -e frame.time_relative -e ip.src -e ip.dst -e tcp.analysis.ack_rtt \
        -Y "tcp.analysis.ack_rtt" 2>/dev/null | head -50 || echo "(none)"
    echo ""

    echo "--- High Latency Events (RTT > 100ms) ---"
    tshark -r "$PCAP" -T fields -e frame.time_relative -e ip.src -e ip.dst -e tcp.analysis.ack_rtt \
        -Y "tcp.analysis.ack_rtt > 0.1" 2>/dev/null | head -30 || echo "(none — good!)"

} > "$OUTPUT" 2>&1

echo "Analysis written to: $OUTPUT"
echo "Lines: $(wc -l < "$OUTPUT")"
cat "$OUTPUT"
