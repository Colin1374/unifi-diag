# unifi-diag

AI-assisted network diagnostics for a UniFi Dream Router (UDR).

Instead of staring at packet captures and log dumps yourself, you point Claude
(or any LLM coding agent) at this repo. The scripts collect data from the UDR,
pre-process it into compact summaries, and the agent reads those summaries to
diagnose WiFi, latency, and connectivity issues.

The key idea: **never feed raw pcaps or syslog dumps to an LLM**. They blow out
the context window and burn tokens. This repo's scripts always produce short,
pipe-delimited or filtered summaries that an agent can read in a single tool call.

## What it does

- Pulls live data from the UDR over SSH (clients, conntrack, logs, packet captures).
- Queries the UDR's internal MongoDB (port 27117) directly for richer per-client
  WiFi stats — RSSI, retries, satisfaction scores, roam history — than the UniFi
  UI exposes.
- Runs `tshark` analyses locally on captured pcaps for retransmits, throughput,
  RTT, DNS response times, and bufferbloat.
- Writes everything to `summaries/` as small text files. That directory is the
  shared workspace between you and the agent.

## Why an agent helps here

UniFi's web UI is good at showing you a single number ("satisfaction: 87") but
bad at correlating across data sources. Diagnosing "my iPhone keeps dropping in
the bedroom" actually requires looking at:

- the client's roam events over the last hour,
- per-AP RSSI at each hop,
- which AP/channel/band it was on,
- whether the same client has retry spikes,
- whether the destination AP supports the band the client prefers,
- whether Min-RSSI / band steering / 802.11r are configured to kick it out.

An agent can chain those queries; you can just describe the symptom.

## Repo layout

```
scripts/                — Data collection and analysis (run these)
filters/                — BPF filters for tcpdump (streaming, gaming, DNS, retransmits)
docs/
  SETUP.md              — One-time setup (SSH key, UDR user, dependencies)
  network_map.example.md — Template — copy to network_map.md and fill in
  unifi_config.example.md — Template — sanitized example of a UDR config digest
  common-issues.md      — Diagnosis patterns (buffering, lag, drops)
captures/               — Raw pcaps land here (gitignored)
summaries/              — Pre-processed diagnostic output (gitignored)
CLAUDE.md               — Instructions the agent reads at session start
setup.sh                — Bootstraps SSH config, scripts, and local network_map.md
```

## Quick start

```bash
git clone <this-repo> ~/unifi-diag
cd ~/unifi-diag
./setup.sh              # interactive: asks for UDR IP, generates SSH key
# Follow the printed instructions to install the pubkey on your UDR.
ssh udr "echo ok"       # verify connection

# Then, in Claude Code (or any agent):
cd ~/unifi-diag
claude
> "The Apple TV in the den keeps buffering. What's going on?"
```

The agent will read `CLAUDE.md`, look up the device in `docs/network_map.md`,
run the relevant `collect-*.sh` scripts, and report.

See `docs/SETUP.md` for the manual version of `setup.sh` (useful if you want to
understand what it does or run pieces individually).

## What you have to fill in

Two things are private and not committed:

1. **`docs/network_map.md`** — your device inventory. `setup.sh` creates a stub.
   Copy `docs/network_map.example.md` as a starting point and fill in your
   actual devices. The richer this is, the better the agent can target queries.
2. **SSH access to your UDR.** `setup.sh` generates a dedicated key and prints
   the steps to authorize it. You can use root or a restricted service user;
   `docs/SETUP.md` covers both.

That's it. The scripts themselves don't have anything hardcoded about a
specific network.

## Available scripts

Collection:
- `collect-unifi-db.sh` — query UniFi MongoDB (clients, wifi-events, alarms, topology, health)
- `collect-clients.sh` — ARP + DHCP lease table
- `collect-logs.sh` — filtered UDR logs (`--filter REGEX --since 2h`)
- `collect-tcpdump.sh` — capture with BPF filter, pull pcap back locally

Analysis (run against pcaps in `captures/`):
- `analyze-retransmits.sh` — TCP retransmit % per conversation
- `analyze-throughput.sh` — per-flow throughput
- `analyze-latency.sh` — RTT distribution
- `analyze-dns.sh` — DNS response time
- `analyze-conntrack.sh` — conntrack state breakdown + top destinations
- `analyze-bufferbloat.sh` — latency-under-load test
- `quick-diag.sh` — runs the common analyses for a target IP

All scripts support `--help`.

## Requirements

Local machine:
- `bash`, `ssh`, `tshark` (Wireshark CLI), `jq`
- Tested on Linux. Should work on macOS with Homebrew tshark/jq.

UDR side:
- SSH access (UniFi OS 7+, tested on UDR; should work on UDM/UDM-Pro/UDM-SE).
- `tcpdump` (preinstalled). `conntrack` may need `apt-get install conntrack`.
- MongoDB on port 27117 is exposed locally on the UDR by default — the scripts
  SSH in and query via the local `mongo` shell.

## Security notes

- The agent has SSH access to your router. Use a dedicated key, ideally for a
  restricted user. See `docs/SETUP.md` for a service-user setup.
- The MongoDB on the UDR has **no authentication** but only listens on
  localhost. Scripts query it over the SSH tunnel — do not expose 27117 to your
  LAN.
- Don't commit `captures/`, `summaries/`, or `docs/network_map.md`. They have
  your IPs, MACs, and hostnames. `.gitignore` already excludes them.
- The committed `CLAUDE.md` is generic. If you add personal context to it,
  consider moving that into `CLAUDE.local.md` (also gitignored).

## Not in scope

- This is read-only diagnostics. Nothing here changes UDR config.
- No cloud APIs, no UniFi controller HTTPS API — everything goes through SSH +
  local Mongo. That means it keeps working when your internet is down (which is
  often when you need it).

## License

MIT. Use it, fork it, sanitize your own version before sharing.
