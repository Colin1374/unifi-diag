#!/usr/bin/env bash
# Collect filtered logs from the UniFi router via SSH
# Usage: ./collect-logs.sh [--filter PATTERN] [--log-source SOURCE] [--lines N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# Defaults
FILTER=""
LOG_SOURCE="all"
LINES=200
SINCE=""
DEDUPE=1
UDR_HOST="udr"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  --filter PATTERN   grep pattern to filter logs (required)"
    echo "  --log-source SRC   Log source: all, system, unifi, dhcp, ids, kernel (default: all)"
    echo "  --lines N          Max lines per source after filter+dedupe (default: 200)"
    echo "  --since DURATION   Restrict to recent lines (e.g. '1h', '30m', '2d')"
    echo "  --no-dedupe        Don't collapse repeated identical messages"
    echo ""
    echo "Examples:"
    echo "  $0 --filter 'deauth|disassoc' --log-source unifi --since 2h"
    echo "  $0 --filter '192.168.1.100' --since 1d"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)     FILTER="$2"; shift 2 ;;
        --log-source) LOG_SOURCE="$2"; shift 2 ;;
        --lines)      LINES="$2"; shift 2 ;;
        --since)      SINCE="$2"; shift 2 ;;
        --no-dedupe)  DEDUPE=0; shift ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$FILTER" ]]; then
    echo "ERROR: --filter required (refusing to dump unfiltered logs)"
    exit 1
fi

# Validate inputs that flow into the remote SSH command.
require_grep_pattern "$FILTER" "--filter"
require_int "$LINES" "--lines" 1 1000000
[[ -n "$SINCE" ]] && require_since "$SINCE" "--since"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$PROJECT_DIR/summaries/logs-${TIMESTAMP}.txt"

echo "=== unifi-diag: log collection ==="
echo "Filter:  $FILTER"
echo "Source:  $LOG_SOURCE"
echo "Lines:   $LINES per source"
echo "Output:  $OUTPUT"
echo ""

# Define log paths on the router
declare -A LOG_PATHS=(
    ["system"]="/var/log/messages"
    ["kernel"]="dmesg"
    ["unifi"]="/data/unifi/logs/server.log"
    ["unifi-core"]="/data/unifi-core/logs/system.log"
    ["dhcp"]="/var/log/daemon.log"
    ["ids"]="/data/unifi-core/logs/ids/suricata.log"
)

# Convert --since duration to a router-side awk timestamp threshold for syslog-format logs.
# Returns a remote shell pipeline that filters lines by recency.
since_filter() {
    if [[ -z "$SINCE" ]]; then echo "cat"; return; fi
    case "$SINCE" in
        *h) local secs=$(( ${SINCE%h} * 3600 )) ;;
        *m) local secs=$(( ${SINCE%m} * 60 )) ;;
        *d) local secs=$(( ${SINCE%d} * 86400 )) ;;
        *)  local secs="$SINCE" ;;
    esac
    # Use date arithmetic on the router side; works on any syslog line whose first 3 fields are date-parseable.
    echo "awk -v cutoff=\$(date -d '@'\$(( \$(date +%s) - $secs )) '+%s') '
        { ts=\"\";
          # Try ISO format first (UniFi server.log)
          if (match(\$1, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/)) { cmd=\"date -d \"\$1\" +%s 2>/dev/null\"; cmd|getline ts; close(cmd); }
          # Fall back: keep line; cheap pre-filter (most logs are append-order so tail covers it).
          else { ts=cutoff; }
          if (ts==\"\" || ts+0 >= cutoff) print
        }'"
}

collect_log() {
    local name="$1"
    local path="$2"
    local sf
    sf=$(since_filter)
    local dedupe_cmd="cat"
    if [[ "$DEDUPE" == "1" ]]; then
        # Collapse runs of identical messages (ignoring leading timestamp).
        dedupe_cmd="awk '{ msg=\$0; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +/, \"\", msg); if (msg!=prev) {print; prev=msg} }'"
    fi
    echo "--- $name ($path) ---"
    if [[ "$path" == "dmesg" ]]; then
        ssh "$UDR_HOST" "dmesg | grep -iE '$FILTER' | $dedupe_cmd | tail -n $LINES" 2>/dev/null || echo "(no matches)"
    else
        ssh "$UDR_HOST" "grep -iE '$FILTER' '$path' 2>/dev/null | $sf | $dedupe_cmd | tail -n $LINES" 2>/dev/null || echo "(no matches or file not found)"
    fi
    echo ""
}

{
    echo "=== UniFi Log Collection ==="
    echo "Date: $(date)"
    echo "Filter: $FILTER"
    echo "Source: $LOG_SOURCE"
    echo ""

    if [[ "$LOG_SOURCE" == "all" ]]; then
        for name in "${!LOG_PATHS[@]}"; do
            collect_log "$name" "${LOG_PATHS[$name]}"
        done
    elif [[ -n "${LOG_PATHS[$LOG_SOURCE]+x}" ]]; then
        collect_log "$LOG_SOURCE" "${LOG_PATHS[$LOG_SOURCE]}"
    else
        echo "ERROR: Unknown log source: $LOG_SOURCE"
        echo "Valid: ${!LOG_PATHS[*]}"
        exit 1
    fi
} > "$OUTPUT"

LINE_COUNT=$(wc -l < "$OUTPUT")
echo "Done. Collected $LINE_COUNT lines to $OUTPUT"
