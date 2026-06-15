# unifi-diag — AI-Assisted Network Diagnostics

## What This Is
Network diagnostic toolkit for UniFi routers running UniFi OS 7+ (UDR, UDM,
UDM-Pro, UDM-SE, UCG-Ultra/Max, etc.; developed against the UDR).
The agent reads pre-processed summaries (NOT raw pcaps/logs) to diagnose issues.

## Critical Rules
- NEVER ask to read raw .pcap files — too large, will destroy tokens.
- NEVER ask to read raw syslog dumps — same problem.
- ALWAYS use the scripts in `scripts/` to collect and pre-process data.
- ALL analysis should be done on summaries in `summaries/`.
- Summaries should be <500 lines. If bigger, filter harder (smaller `--since`).
- When diagnosing, state confidence level and what additional data would help.

## Machine-vs-Network Isolation (READ BEFORE diagnosing throughput/lag)
A single endpoint's symptom (one PC lagging, one slow speedtest) is NOT proof of
a network problem. Before recommending ANY network change:
1. Test from a SECOND device or from the router itself
   (`ssh udr ping -c20 8.8.8.8`). If the router's WAN test is clean (low RTT,
   0% loss), the network core is fine — look at the endpoint.
2. Compare throughput against the PLAN's rated speed before claiming
   congestion/bufferbloat. Ask the user their up/down plan if unknown.
   (A download that is a small fraction of link capacity cannot saturate it.)
3. Do NOT trust UniFi's `wan-latency` stat (ace_stat gateway docs) as ground
   truth — it is a controller probe and can read hundreds of ms while a real
   ICMP ping from the router is fine. Always corroborate with a live ping.
4. Wired endpoint slow + router WAN clean => suspect the ENDPOINT (NIC driver,
   cable, duplex, CPU pegged during test, AV/DPI software, local background
   traffic), not the network.
5. State machine-vs-network confidence explicitly and name the single test that
   would settle it. Don't fit a network story to ambiguous stats.

## Router Connection
- SSH alias `udr` is configured in `~/.ssh/config` (see `docs/SETUP.md`).
- Connect: `ssh udr`.
- The router has MongoDB on port 27117 (no auth, localhost-only) with all UniFi data.

## Project Layout
```
scripts/
  collect-tcpdump.sh      — SSH to router, capture with BPF filter, pull pcap back
  collect-logs.sh         — SSH to router, grab filtered logs
  collect-clients.sh      — Pull client list from router (ARP + DHCP leases)
  collect-unifi-db.sh     — Query UniFi MongoDB for rich diagnostic data
  collect-survey.sh       — RUN ON SURVEY LAPTOP: per-room dual-direction RSSI sample (client iw scan + AP-side mca-dump); --report pivots summaries/survey.psv
  analyze-retransmits.sh  — tshark: retransmit stats from pcap
  analyze-throughput.sh   — tshark: per-conversation throughput
  analyze-latency.sh      — tshark: RTT analysis
  analyze-dns.sh          — tshark: DNS response time analysis
  analyze-conntrack.sh    — SSH to router, dump filtered conntrack table
  analyze-bufferbloat.sh  — latency-under-load test
  quick-diag.sh           — runs common analyses, outputs combined summary
filters/
  streaming.bpf, gaming.bpf, dns.bpf, retransmits.bpf
captures/                 — raw pcaps land here (gitignored)
summaries/                — processed output goes here (gitignored, small)
docs/
  SETUP.md                — setup instructions (read this first)
  network_map.md          — your device inventory (gitignored; copy from .example)
  network_map.example.md  — template for network_map.md
  unifi_config.example.md — example of an annotated router config digest
  common-issues.md        — known issue patterns and diagnostic steps
```

## MongoDB Data Source (collect-unifi-db.sh)
UniFi OS runs MongoDB 3.6 on port 27117. Two key databases:
- **ace** — config: clients (user), devices, networks, WLANs, firewall, alarms/IDS
- **ace_stat** — stats: 5min/hourly/daily metrics per client + AP, WiFi events, downtime

### Available Commands
```bash
./scripts/collect-unifi-db.sh clients [--since N]      # Client DB; default --since 7 days. Use --since 0 for all.
./scripts/collect-unifi-db.sh clients-lean [--since N] # Compact: name|ip|mac6|ap|band (default --since 2)
./scripts/collect-unifi-db.sh client-stats IP          # Per-client 5min stats: signal, retries, satisfaction, bytes
./scripts/collect-unifi-db.sh wifi-events MAC [--since N]  # Connection/roam events (default --since 7, drops null-AP rows)
./scripts/collect-unifi-db.sh alarms                   # Recent IDS/IPS alerts
./scripts/collect-unifi-db.sh topology                 # Devices, VLANs, WLANs with firmware versions
./scripts/collect-unifi-db.sh health                   # AP satisfaction scores, retry rates, WAN downtime
./scripts/collect-unifi-db.sh all                      # Everything above
```

### Token-saving tips
- Default to `clients-lean` for "what's on the network now" — ~25 lines vs ~110 for `clients --since 0`.
- Use `--since` aggressively. Most diagnostic questions only care about the last few hours/days.
- Output is pipe-delimited with a header row (`name|ip|mac|...`); don't restate column meanings.
- Mongo queries use `$project` to ship only needed fields over SSH; if you add new commands, do the same.

### Key Stats Fields (ace_stat.stat_5minutes)
Per-client WiFi stats every 5 minutes:
- `ng-signal` / `na-signal` — RSSI in dBm (ng=2.4GHz, na=5GHz)
- `ng-tx_retries` / `na-tx_retries` — WiFi TX retry count
- `ng-wifi_tx_attempts` / `na-wifi_tx_attempts` — total TX attempts (retries/attempts = retry %)
- `ng-satisfaction` / `na-satisfaction` — UniFi's WiFi experience score (0-100)
- `rx_rate_most_common` — most common RX rate in bps
- `*-bytes` — bandwidth consumed

### WiFi Event Types (ace_stat.wifi_connectivity_event)
- `WIFI_CONNECTION` — client connected to AP (has RSSI, channel, WPA/DHCP timing)
- `WIFI_ROAMING` — client roamed between APs (has from/to endpoint with RSSI)

## Network Overview
The specifics of this user's network live in `docs/network_map.md` (not
committed). If it doesn't exist yet, prompt the user to copy
`docs/network_map.example.md` to `docs/network_map.md` and fill it in — or run
`./scripts/collect-unifi-db.sh clients-lean` to bootstrap from the live router.

## Diagnostic Workflow
1. User describes symptom (e.g., "buffering on the Apple TV in the den").
2. Look up device IP in `docs/network_map.md`. If not found, list current
   clients with `clients-lean` and ask the user to identify.
3. Start with `collect-unifi-db.sh client-stats <IP>` for a WiFi health snapshot.
4. If WiFi stats look bad → check `wifi-events`, check AP `health`.
5. If WiFi looks fine → run `quick-diag.sh --target <IP>` for packet-level analysis.
6. Read summaries, diagnose, suggest fix or request more targeted data.

## Common Diagnosis Patterns

### Buffering / Streaming Issues
1. `collect-unifi-db.sh client-stats <IP>` — check retry %, signal, satisfaction.
2. If retry >10% or satisfaction <90 → WiFi problem.
3. `quick-diag.sh --target <IP> --duration 60` — packet-level analysis.
4. Check retransmit rate (>2% = problem), RTT variance, DNS times.

### High Latency / Lag
1. `collect-unifi-db.sh health` — check AP retry rates.
2. `analyze-bufferbloat.sh` — latency under load test.
3. `analyze-latency.sh <pcap>` — RTT breakdown.

### Connection Drops
1. `collect-unifi-db.sh wifi-events <MAC> --since 1` — failed roams/disconnects?
2. `collect-logs.sh --filter "deauth|disassoc|disconnect" --since 2h`.
3. `analyze-conntrack.sh --target <IP>` — top destinations + state breakdown.

### WiFi Roaming Issues / Move-Between-Rooms Disconnects
1. `collect-unifi-db.sh wifi-events <MAC>` — roaming history with RSSI at each hop.
2. BEFORE tuning anything, dump ALL THREE kick mechanisms — per-radio Min-RSSI
   (device radio_table), WLAN-level Roaming Assistant per band (wlanconf
   roaming_assistant_*), and band steering. They compound, and the WLAN-level one
   applies to every AP at once. See docs/common-issues.md "Roam-Kick Lockout".
3. Survey the problem room with `collect-survey.sh` carrying the affected device
   (--track its MAC). Thresholds act on AP-side **up** RSSI, which runs ~6-12 dB
   worse than client-side readings — never tune from WiFiman numbers.
4. If the best AP's uplink in a room is below every threshold, the room is locked
   out — loosen/disable a gate; tightening makes it worse.
5. Invariants: a gated 6GHz radio needs an ungated same-AP 5GHz escape hatch
   (Apple clients join 6GHz whenever audible and won't leave voluntarily).
   Keep 802.11v on; treat 802.11r as guilty until a walk test proves it works.
6. Walk-test log signatures (daemon.log): repeated `kick-sta-on` + `rssia` denials
   + `auth_flood` = lockout; `UBNT ROAM` + `ignored kick ... On other VAP` = healthy.

## Router Log Locations
- System: `/var/log/messages`
- Kernel: `dmesg`
- UniFi Core: `/data/unifi-core/logs/`
- UniFi Network: `/data/unifi/logs/server.log`
- DHCP: `/var/log/daemon.log` (filter for dnsmasq)
- IDS/IPS: `/data/unifi-core/logs/ids/`
- MongoDB: port 27117, databases: `ace`, `ace_stat`
