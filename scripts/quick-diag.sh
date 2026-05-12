#!/usr/bin/env bash
# Quick diagnostic: capture + analyze in one shot
# Usage: ./quick-diag.sh --target IP [--duration SECS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET=""
DURATION=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   TARGET="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        -h|--help)  echo "Usage: $0 --target <device-ip> [--duration SECS]"; exit 0 ;;
        *)          echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "ERROR: --target required"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SUMMARY="$PROJECT_DIR/summaries/quick-diag-${TIMESTAMP}.txt"

echo "=== Quick Diagnostic for $TARGET ==="
echo "Duration: ${DURATION}s"
echo ""

# Step 1: Capture
echo "[1/5] Capturing traffic..."
"$SCRIPT_DIR/collect-tcpdump.sh" --target "$TARGET" --duration "$DURATION"

# Find the most recent capture
PCAP=$(ls -t "$PROJECT_DIR/captures/"*.pcap 2>/dev/null | head -1)
if [[ -z "$PCAP" ]]; then
    echo "ERROR: No capture file found"
    exit 1
fi

echo ""

# Step 2-5: Run analyses
{
    echo "=== Quick Diagnostic Report ==="
    echo "Target: $TARGET"
    echo "Capture: $PCAP"
    echo "Date: $(date)"
    echo ""

    echo "==============================="
    echo "  RETRANSMISSION ANALYSIS"
    echo "==============================="
    "$SCRIPT_DIR/analyze-retransmits.sh" "$PCAP" 2>&1 | grep -v "^Analysis written"
    echo ""

    echo "==============================="
    echo "  THROUGHPUT ANALYSIS"
    echo "==============================="
    "$SCRIPT_DIR/analyze-throughput.sh" "$PCAP" 2>&1 | grep -v "^Analysis written"
    echo ""

    echo "==============================="
    echo "  LATENCY ANALYSIS"
    echo "==============================="
    "$SCRIPT_DIR/analyze-latency.sh" "$PCAP" 2>&1 | grep -v "^Analysis written"
    echo ""

    echo "==============================="
    echo "  DNS ANALYSIS"
    echo "==============================="
    "$SCRIPT_DIR/analyze-dns.sh" "$PCAP" 2>&1 | grep -v "^Analysis written"

} > "$SUMMARY" 2>&1

LINE_COUNT=$(wc -l < "$SUMMARY")
echo ""
echo "=== Complete ==="
echo "Full report: $SUMMARY ($LINE_COUNT lines)"
echo ""
echo "Ask Claude to read $SUMMARY for diagnosis."
