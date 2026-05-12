#!/usr/bin/env bash
# Collect tcpdump from the UniFi router via SSH with BPF filter
# Usage: ./collect-tcpdump.sh [--target IP] [--port PORT] [--duration SECS] [--filter-file FILE] [--interface IFACE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# Defaults
TARGET=""
PORT=""
DURATION=30
FILTER_FILE=""
INTERFACE="br0"
MAX_PACKETS=10000
UDR_HOST="udr"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  --target IP        Target device IP to filter on"
    echo "  --port PORT        Port to filter on"
    echo "  --duration SECS    Capture duration (default: 30)"
    echo "  --filter-file FILE BPF filter file from filters/"
    echo "  --interface IFACE  Router interface (default: br0)"
    echo "  --max-packets N    Max packets (default: 10000)"
    echo ""
    echo "Examples:"
    echo "  $0 --target 192.168.1.100 --duration 60"
    echo "  $0 --filter-file streaming.bpf --target 192.168.1.100"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)     TARGET="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --duration)   DURATION="$2"; shift 2 ;;
        --filter-file) FILTER_FILE="$2"; shift 2 ;;
        --interface)  INTERFACE="$2"; shift 2 ;;
        --max-packets) MAX_PACKETS="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

# Validate inputs (reject anything that could escape the remote SSH command).
[[ -n "$TARGET" ]]   && require_ipv4 "$TARGET" "--target"
[[ -n "$PORT" ]]     && require_int  "$PORT" "--port" 1 65535
require_int   "$DURATION"    "--duration"    1 86400
require_int   "$MAX_PACKETS" "--max-packets" 1 10000000
require_iface "$INTERFACE"   "--interface"

# Build BPF filter
BPF=""
if [[ -n "$FILTER_FILE" ]]; then
    require_filter_basename "$FILTER_FILE" "--filter-file"
    FILTER_PATH="$PROJECT_DIR/filters/$FILTER_FILE"
    if [[ ! -f "$FILTER_PATH" ]]; then
        echo "ERROR: Filter file not found: $FILTER_PATH"
        exit 1
    fi
    BPF=$(grep -v '^#' "$FILTER_PATH" | grep -v '^$' | tr '\n' ' ')
    require_no_squote "$BPF" "filter file content"
fi

if [[ -n "$TARGET" ]]; then
    if [[ -n "$BPF" ]]; then
        BPF="host $TARGET and ($BPF)"
    else
        BPF="host $TARGET"
    fi
fi

if [[ -n "$PORT" ]]; then
    if [[ -n "$BPF" ]]; then
        BPF="$BPF and port $PORT"
    else
        BPF="port $PORT"
    fi
fi

if [[ -z "$BPF" ]]; then
    echo "ERROR: Must specify at least --target, --port, or --filter-file"
    echo "       (refusing to capture unfiltered — too much data)"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOCAL_PCAP="$PROJECT_DIR/captures/capture-${TIMESTAMP}.pcap"

echo "=== unifi-diag: tcpdump collection ==="
echo "Router host: $UDR_HOST"
echo "Interface:   $INTERFACE"
echo "Duration:    ${DURATION}s"
echo "Max packets: $MAX_PACKETS"
echo "BPF filter:  $BPF"
echo "Output:      $LOCAL_PCAP"
echo ""

# Allocate a unique remote tmpfile (avoids collisions and symlink races).
REMOTE_PCAP=$(ssh "$UDR_HOST" "mktemp /tmp/unifi-diag-capture.XXXXXX.pcap")
[[ "$REMOTE_PCAP" =~ ^/tmp/unifi-diag-capture\.[A-Za-z0-9]+\.pcap$ ]] \
    || { echo "ERROR: unexpected remote tmp path: $REMOTE_PCAP"; exit 1; }
trap 'ssh "$UDR_HOST" "rm -f $REMOTE_PCAP" >/dev/null 2>&1 || true' EXIT

# Run tcpdump on the router. All interpolated values are validated above.
echo "[1/3] Starting capture on router..."
ssh "$UDR_HOST" "timeout $DURATION tcpdump -i $INTERFACE -c $MAX_PACKETS -w $REMOTE_PCAP '$BPF'" 2>&1 || true

# Pull pcap back
echo "[2/3] Pulling capture file..."
scp "$UDR_HOST:$REMOTE_PCAP" "$LOCAL_PCAP"

# Cleanup happens via trap.
echo "[3/3] Cleaning up remote..."

FILESIZE=$(stat -f%z "$LOCAL_PCAP" 2>/dev/null || stat -c%s "$LOCAL_PCAP" 2>/dev/null)
echo ""
echo "Done. Captured $(echo "$FILESIZE" | numfmt --to=iec 2>/dev/null || echo "$FILESIZE bytes")"
echo "File: $LOCAL_PCAP"
echo ""
echo "Next: run analysis scripts on this capture, e.g.:"
echo "  ./scripts/analyze-retransmits.sh $LOCAL_PCAP"
echo "  ./scripts/analyze-throughput.sh $LOCAL_PCAP"
echo "  ./scripts/analyze-latency.sh $LOCAL_PCAP"
