# UniFi Network Diagnostics

AI-assisted diagnostics for UniFi routers (UDR, UDM, UDM-Pro, UDM-SE, UCG-Ultra/Max, UniFi OS 7+).
Scripts live at `~/tmux-agents/tools/unifi-diag/scripts/`. Run all commands from `~/tmux-agents/tools/unifi-diag/`.

## Critical Rules

- NEVER read raw .pcap files - too large, destroys tokens.
- NEVER read raw syslog dumps - same problem.
- ALWAYS use scripts in `scripts/` to collect and pre-process data.
- ALL analysis on summaries in `summaries/` (gitignored, small).
- Summaries must be <500 lines. If bigger, use `--since` to filter harder.
- State confidence level and what additional data would help.

## Router Connection

SSH alias `udr` is in `~/.ssh/config`. MongoDB on port 27117 (no auth, localhost-only).
Test: `ssh udr 'echo ok'`

## Scripts

```bash
# Run from ~/tmux-agents/tools/unifi-diag/

# --- Data collection ---
./scripts/collect-unifi-db.sh clients-lean [--since N]     # Active clients (compact, ~25 lines)
./scripts/collect-unifi-db.sh clients [--since N]          # Full client DB (default 7 days)
./scripts/collect-unifi-db.sh client-stats IP              # Per-client 5-min WiFi stats
./scripts/collect-unifi-db.sh wifi-events MAC [--since N]  # Connection/roam history
./scripts/collect-unifi-db.sh health                       # AP satisfaction + WAN downtime
./scripts/collect-unifi-db.sh topology                     # Devices, VLANs, WLANs, firmware
./scripts/collect-unifi-db.sh alarms                       # Recent IDS/IPS alerts
./scripts/collect-unifi-db.sh all                          # Everything above

./scripts/collect-tcpdump.sh --target IP [--duration 60]   # Remote pcap capture (pulls to captures/)
./scripts/collect-logs.sh --filter "pattern" [--since 2h]  # Filtered router logs
./scripts/collect-clients.sh                               # Live client list from router API

# --- Packet analysis (run on captures/*.pcap) ---
./scripts/analyze-retransmits.sh captures/<pcap>           # TCP retransmit stats
./scripts/analyze-latency.sh captures/<pcap>               # RTT analysis
./scripts/analyze-throughput.sh captures/<pcap>            # Per-flow throughput
./scripts/analyze-dns.sh captures/<pcap>                   # DNS response times
./scripts/analyze-conntrack.sh --target IP                 # Connection state from router
./scripts/analyze-bufferbloat.sh                           # Latency-under-load test

# --- One-shot ---
./scripts/quick-diag.sh --target IP [--duration 30]        # Capture + all analysis combined
```

## Key WiFi Stats (in client-stats output)

- `ng-signal` / `na-signal` - RSSI dBm (ng=2.4GHz, na=5GHz; good: >-65, bad: <-75)
- `ng-tx_retries` / `na-tx_retries` - TX retry count
- `ng-wifi_tx_attempts` / `na-wifi_tx_attempts` - total TX; retries/attempts = retry %
- `ng-satisfaction` / `na-satisfaction` - UniFi score 0-100 (good: >90, bad: <80)

## Diagnostic Workflow

1. User describes symptom (e.g., "Apple TV in den keeps buffering").
2. Look up device IP in `docs/network_map.md`. If missing, run `clients-lean` and ask user.
3. Start: `collect-unifi-db.sh client-stats <IP>` for WiFi snapshot.
4. WiFi bad (retry >10% or satisfaction <90) → check `wifi-events`, check `health`.
5. WiFi fine → `quick-diag.sh --target <IP> --duration 60` for packet-level analysis.
6. Read summaries, diagnose, suggest fix or request more targeted data.

## Common Patterns

### Buffering / Streaming Issues
1. `client-stats <IP>` - check retry %, signal, satisfaction
2. retry >10% or satisfaction <90 → WiFi problem, not ISP
3. `quick-diag.sh --target <IP> --duration 60`
4. retransmit >2% = problem; check RTT variance and DNS times

### High Latency / Lag
1. `health` - AP retry rates, WAN downtime history
2. `analyze-bufferbloat.sh` - latency under load (>30ms delta = moderate bufferbloat)
3. `analyze-latency.sh <pcap>` - RTT distribution per flow

### Connection Drops / Deauths
1. `wifi-events <MAC> --since 1` - failed roams, unexpected disconnects
2. `collect-logs.sh --filter "deauth|disassoc|disconnect" --since 2h`
3. `analyze-conntrack.sh --target <IP>` - connection state breakdown

### WiFi Roaming Issues
1. `wifi-events <MAC>` - roaming history with per-hop RSSI
2. Frequent roams + low RSSI → tighten Min-RSSI on weak AP (e.g., -75 → -70)
3. Pair with 802.11r/k enabled on the SSID for smooth handoff

### Security / IDS Events
1. `collect-unifi-db.sh alarms` - recent IDS/IPS alerts
2. `collect-logs.sh --filter "ET |SURICATA" --log-source ids --since 24h`
3. Cross-reference alarm timestamps with `wifi-events` for the flagged client

## Setup Check

Before diagnosing, verify setup is complete:
```bash
ssh udr 'echo ok'                         # Router SSH works
command -v tshark && echo "tshark ok"     # Local packet analysis tool
ls docs/network_map.md 2>/dev/null || echo "network_map.md missing - copy from docs/network_map.example.md"
```

---

Symptom or task: {{Input}}
