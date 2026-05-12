#!/usr/bin/env bash
# Analyze conntrack table from UDR for a target device
# Usage: ./analyze-conntrack.sh --target IP
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET=""
UDR_HOST="udr"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        *)        echo "Usage: $0 --target <device-ip>"; exit 1 ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "ERROR: --target required"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$PROJECT_DIR/summaries/conntrack-${TIMESTAMP}.txt"

# Pull conntrack ONCE; do all analysis locally.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
ssh "$UDR_HOST" "conntrack -L 2>/dev/null | grep -F '$TARGET'" > "$TMP" 2>/dev/null || true

CONN_TOTAL=$(wc -l < "$TMP")

{
    echo "=== Connection Tracking Analysis ==="
    echo "Target: $TARGET"
    echo "Date: $(date)"
    echo "Total connections: $CONN_TOTAL"
    echo ""

    if [[ "$CONN_TOTAL" -eq 0 ]]; then
        echo "(no conntrack entries for $TARGET)"
        exit 0
    fi

    echo "--- Connection Count by State ---"
    grep -oE '(ESTABLISHED|TIME_WAIT|CLOSE_WAIT|SYN_SENT|FIN_WAIT|UNREPLIED|ASSURED)' "$TMP" \
        | sort | uniq -c | sort -rn
    echo ""

    echo "--- Connection Count by Protocol ---"
    awk '{print $1}' "$TMP" | sort | uniq -c | sort -rn
    echo ""

    echo "--- Top 15 Destinations (by connection count) ---"
    # Conntrack format: dst=X.X.X.X dport=NNNN — group by dst:dport
    awk '{
      dst=""; dport="";
      for(i=1;i<=NF;i++){
        if($i ~ /^dst=/ && dst==""){split($i,a,"="); dst=a[2]}
        if($i ~ /^dport=/ && dport==""){split($i,a,"="); dport=a[2]}
      }
      if(dst!="" && dst!="'"$TARGET"'") print dst":"dport
    }' "$TMP" | sort | uniq -c | sort -rn | head -15
    echo ""

    echo "--- Sample raw entries (first 20) ---"
    head -20 "$TMP"
} > "$OUTPUT"

echo "Analysis written to: $OUTPUT ($(wc -l < "$OUTPUT") lines, $CONN_TOTAL conns)"
cat "$OUTPUT"
