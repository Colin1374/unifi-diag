#!/usr/bin/env bash
# Test for bufferbloat: measure latency while generating load
# Usage: ./analyze-bufferbloat.sh [--target-host HOSTNAME] [--duration SECS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default ping target (reliable, low latency baseline)
PING_TARGET="1.1.1.1"
DURATION=15
UDR_HOST="udr"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-host) PING_TARGET="$2"; shift 2 ;;
        --duration)    DURATION="$2"; shift 2 ;;
        -h|--help)     echo "Usage: $0 [--target-host HOST] [--duration SECS]"; exit 0 ;;
        *)             echo "Unknown: $1"; exit 1 ;;
    esac
done

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$PROJECT_DIR/summaries/bufferbloat-${TIMESTAMP}.txt"

{
    echo "=== Bufferbloat Test ==="
    echo "Ping target: $PING_TARGET"
    echo "Duration: ${DURATION}s"
    echo "Date: $(date)"
    echo ""

    echo "--- Phase 1: Baseline Latency (no load, 10 pings) ---"
    ping -c 10 -i 0.5 "$PING_TARGET" 2>&1 | tail -5
    echo ""

    echo "--- Phase 2: Latency Under Download Load ---"
    echo "(Starting background download + concurrent pings)"
    echo "(If you have 'iperf3' available, use that instead for better results)"
    echo ""

    # Simple download load generator — wget to /dev/null
    # Using Cloudflare speed test file as load source
    wget -O /dev/null "https://speed.cloudflare.com/__down?bytes=100000000" 2>/dev/null &
    LOAD_PID=$!

    # Ping during load
    ping -c "$DURATION" -i 1 "$PING_TARGET" 2>&1 | tail -$((DURATION + 3))

    # Kill load generator
    kill $LOAD_PID 2>/dev/null || true
    wait $LOAD_PID 2>/dev/null || true
    echo ""

    echo "--- Phase 3: Recovery (5 pings after load) ---"
    sleep 2
    ping -c 5 -i 0.5 "$PING_TARGET" 2>&1 | tail -5
    echo ""

    echo "--- Interpretation ---"
    echo "Compare Phase 1 (baseline) vs Phase 2 (under load):"
    echo "  <5ms increase:  No bufferbloat (good)"
    echo "  5-30ms increase: Mild bufferbloat"
    echo "  30-100ms increase: Moderate bufferbloat (SQM recommended)"
    echo "  >100ms increase: Severe bufferbloat (SQM strongly recommended)"

} > "$OUTPUT" 2>&1

echo "Analysis written to: $OUTPUT"
echo "Lines: $(wc -l < "$OUTPUT")"
cat "$OUTPUT"
