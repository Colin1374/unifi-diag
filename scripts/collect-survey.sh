#!/usr/bin/env bash
# collect-survey.sh — per-room WiFi survey sampler for Min-RSSI / roaming tuning + RSSI fingerprinting.
#
# RUN THIS ON A SURVEY LAPTOP, not on the gateway. Supported platforms:
#   Linux    — scans via `sudo iw` (needs sudo)
#   macOS    — scans via `system_profiler` (no sudo; BSSIDs are hidden by the OS,
#              networks are matched to APs by SSID+channel instead)
#   Windows  — run from Git Bash or WSL; scans via `netsh.exe` (signal % converted to ~dBm)
# All platforms need: bash, python3 (or python), ssh access to the gateway.
# No AP credentials are stored — they are fetched from the controller's Mongo
# (setting.mgmt) at runtime, inside the gateway ssh session.
#
# Captures BOTH directions at each spot:
#   down — client-side scan RSSI of every home BSSID
#   up   — AP-side RSSI of tracked client MACs (mca-dump on the gateway + sshpass hop
#          to other managed APs). "up" is what Min-RSSI gates and Roaming Assistant
#          act on, and it typically runs 6-12 dB WORSE than the client-side reading.
#          Never tune kick thresholds from client-side numbers.
#
# Config (env vars, or put them in scripts/survey.local.conf — gitignored):
#   UDR_HOST    ssh destination for the gateway        (default: udr)
#   AP_HOPS     space-separated Name:IP of other APs   (default: none; e.g. "AP1:192.168.1.20 AP2:192.168.1.21")
#   TRACK_MACS  extra client MACs to record AP-side    (default: none; the surveying laptop is always tracked)
#   SURVEY_OUT  output file                            (default: summaries/survey.psv)
#
# Usage:
#   ./collect-survey.sh <location> [--note "free text"] [--track mac,mac,...]
#   ./collect-survey.sh --report          # pivot survey.psv into room x AP/band matrix
#
# Examples:
#   ./collect-survey.sh living-room
#   ./collect-survey.sh guest-room --note "no LOS to AP1" --track aa:bb:cc:dd:ee:ff
#
# Output: appends pipe rows to $SURVEY_OUT:
#   ts|location|device|dir|ap|band|ssid|bssid|rssi_dbm|note
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/survey.local.conf" ] && . "$SCRIPT_DIR/survey.local.conf"
UDR_HOST="${UDR_HOST:-udr}"
AP_HOPS="${AP_HOPS:-}"
SURVEY_OUT="${SURVEY_OUT:-$SCRIPT_DIR/../summaries/survey.psv}"
HEADER="ts|location|device|dir|ap|band|ssid|bssid|rssi_dbm|note"
DEFAULT_TRACK="${TRACK_MACS:-}"
PY="$(command -v python3 || command -v python)"
[ -n "$PY" ] || { echo "python3 not found" >&2; exit 1; }

case "$(uname -s)" in
  Linux*)  grep -qi microsoft /proc/version 2>/dev/null && OS=windows || OS=linux ;;
  Darwin*) OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

report() {
  "$PY" - "$SURVEY_OUT" <<'PYEOF'
import sys, statistics, collections
rows = [l.rstrip("\n").split("|") for l in open(sys.argv[1]) if "|" in l]
rows = [r for r in rows[1:] if len(r) >= 9]
for direction in ("up", "down"):
    data = collections.defaultdict(list)  # (loc, ap/band) -> [rssi]
    cols = set()
    for ts, loc, dev, d, ap, band, ssid, bssid, rssi, *note in rows:
        if d != direction or not rssi.lstrip("-").isdigit():
            continue
        key = f"{ap}/{band}"
        data[(loc, key)].append(int(rssi))
        cols.add(key)
    if not data:
        continue
    cols = sorted(cols)
    locs = sorted({loc for loc, _ in data})
    print(f"\n== {direction} (median dBm, {'AP view of client' if direction=='up' else 'client view of AP'}) ==")
    print(f"{'location':<18}" + "".join(f"{c:>14}" for c in cols))
    for loc in locs:
        cells = []
        for c in cols:
            v = data.get((loc, c))
            cells.append(f"{round(statistics.median(v)):>14}" if v else f"{'.':>14}")
        print(f"{loc:<18}" + "".join(cells))
PYEOF
}

[ "${1:-}" = "--report" ] && { report; exit 0; }
[ $# -ge 1 ] || { grep '^# ' "$0" | head -34; exit 1; }

LOCATION="$1"; shift
NOTE=""
TRACK="$DEFAULT_TRACK"
while [ $# -gt 0 ]; do
  case "$1" in
    --note)  NOTE="$2"; shift 2 ;;
    --track) TRACK="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

TS="$(date +%Y-%m-%dT%H:%M:%S)"
HOST="${HOSTNAME:-$(hostname)}"; HOST="${HOST%%.*}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- detect own WiFi MAC (the in-use, possibly randomized, address) ----
case "$OS" in
  linux)
    IFC="$(iw dev | awk '$1=="Interface"{print $2; exit}')"
    [ -n "$IFC" ] || { echo "no wifi interface found" >&2; exit 1; }
    MY_MAC="$(cat "/sys/class/net/$IFC/address")"
    ;;
  macos)
    IFC="$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')"
    [ -n "$IFC" ] || { echo "no wifi interface found" >&2; exit 1; }
    MY_MAC="$(ifconfig "$IFC" | awk '/ether/{print $2; exit}')"
    ;;
  windows)
    MY_MAC="$(netsh.exe wlan show interfaces 2>/dev/null | tr -d '\r' \
      | awk -F': ' 'tolower($0) ~ /physical address/{gsub(/-/,":",$2); print tolower($2); exit}')"
    [ -n "$MY_MAC" ] || { echo "no wifi interface found (is WiFi on?)" >&2; exit 1; }
    ;;
esac
TRACK="$MY_MAC,$TRACK"

# ---- client-side scan, normalized to: bssid|ssid|channel|band|rssi  ("?" where unknown) ----
echo ">> [$LOCATION] client-side scan ($OS) ..." >&2
case "$OS" in
  linux)
    for attempt in 1 2 3; do
      if sudo iw dev "$IFC" scan > "$TMP/scan.raw" 2>"$TMP/scan.err"; then break; fi
      [ "$attempt" = 3 ] && { cat "$TMP/scan.err" >&2; exit 1; }
      sleep 2
    done
    "$PY" - < "$TMP/scan.raw" > "$TMP/scan.psv" <<'PYEOF'
import re, sys
def chan_band(freq):
    f = int(freq)
    if f < 3000:  return (14 if f == 2484 else (f - 2407) // 5, "2g")
    if f < 5945:  return ((f - 5000) // 5, "5g")
    return ((f - 5950) // 5, "6g")
bss = freq = sig = None; ssid = ""
def flush():
    if bss and sig is not None and freq:
        ch, band = chan_band(freq)
        print(f"{bss}|{ssid}|{ch}|{band}|{round(float(sig))}")
for line in sys.stdin:
    m = re.match(r"^BSS ([0-9a-f:]{17})", line)
    if m:
        flush(); bss, freq, sig, ssid = m.group(1).lower(), None, None, ""
    elif "freq:" in line:
        freq = float(line.split("freq:")[1].strip().split()[0])
    elif "signal:" in line:
        sig = float(line.split("signal:")[1].strip().split()[0])
    elif re.match(r"^\s+SSID:", line):
        ssid = line.split("SSID:", 1)[1].strip()
flush()
PYEOF
    ;;
  macos)
    system_profiler SPAirPortDataType 2>/dev/null > "$TMP/scan.raw"
    "$PY" - < "$TMP/scan.raw" > "$TMP/scan.psv" <<'PYEOF'
import re, sys
# system_profiler lists networks as "<indent><SSID>:" blocks containing
# "Channel: 64 (5GHz, 80MHz)" and "Signal / Noise: -65 dBm / -92 dBm".
# macOS hides BSSIDs from unprivileged tools; emit "?" and let the parser
# match by SSID+channel against the AP dump.
ssid = ch = band = sig = None
def flush():
    if ssid and ch and sig is not None:
        print(f"?|{ssid}|{ch}|{band or '?'}|{sig}")
for line in sys.stdin:
    m = re.match(r"^(\s+)(\S[^:]{0,31}):\s*$", line)
    if m and len(m.group(1)) >= 10:
        flush(); ssid, ch, band, sig = m.group(2).strip(), None, None, None
        continue
    m = re.search(r"Channel:\s*(\d+)\s*\((2\.4|5|6)GHz", line)
    if m:
        ch = int(m.group(1)); band = {"2.4": "2g", "5": "5g", "6": "6g"}[m.group(2)]
    m = re.search(r"Signal / Noise:\s*(-\d+)\s*dBm", line)
    if m:
        sig = int(m.group(1))
flush()
PYEOF
    ;;
  windows)
    netsh.exe wlan show networks mode=bssid 2>/dev/null | tr -d '\r' > "$TMP/scan.raw"
    "$PY" - < "$TMP/scan.raw" > "$TMP/scan.psv" <<'PYEOF'
import re, sys
# netsh reports signal as a quality percentage; dBm ~= pct/2 - 100.
# The "Band" line exists on Win11 only; otherwise band comes from the
# channel number or the SSID+channel match against the AP dump.
ssid = ""; bss = ch = band = sig = None
def flush():
    if bss and sig is not None:
        b = band or ("2g" if ch and ch <= 14 else "?")
        print(f"{bss}|{ssid}|{ch or '?'}|{b}|{sig}")
for line in sys.stdin:
    m = re.match(r"^SSID \d+ : (.*)$", line)
    if m:
        flush(); ssid = m.group(1).strip(); bss = ch = band = sig = None
        continue
    m = re.match(r"^\s+BSSID \d+\s+: ([0-9a-fA-F:]{17})", line)
    if m:
        flush(); bss = m.group(1).lower(); ch = band = sig = None
        continue
    m = re.search(r"Signal\s+:\s*(\d+)%", line)
    if m:
        sig = int(m.group(1)) // 2 - 100
    m = re.search(r"Channel\s+:\s*(\d+)", line)
    if m:
        ch = int(m.group(1))
    m = re.search(r"Band\s+:\s*([\d.]+)\s*GHz", line)
    if m:
        band = {"2.4": "2g", "5": "5g", "6": "6g"}.get(m.group(1))
flush()
PYEOF
    ;;
esac

# ---- AP-side station dumps (gateway + sshpass hops using controller-managed creds) ----
echo ">> AP-side mca-dump (gateway + hops) ..." >&2
# Note: ssh flattens its argument list into one command line which the remote
# shell re-splits, so each hop arrives as its own positional parameter.
ssh "$UDR_HOST" bash -s -- $AP_HOPS > "$TMP/aps.txt" <<'RMTEOF'
set -u
CRED=$(mongo --quiet --port 27117 ace --eval 'var s=db.setting.findOne({key:"mgmt"}); print(s.x_ssh_username+":"+s.x_ssh_password)')
U=${CRED%%:*}; P=${CRED#*:}
echo "___AP___UDR"
mca-dump 2>/dev/null
for hop in "$@"; do
  echo "___AP___${hop%%:*}"
  sshpass -p "$P" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 "$U@${hop#*:}" mca-dump 2>/dev/null || true
done
RMTEOF

mkdir -p "$(dirname "$SURVEY_OUT")"
[ -s "$SURVEY_OUT" ] || echo "$HEADER" > "$SURVEY_OUT"

"$PY" - "$TMP" "$TS" "$LOCATION" "$TRACK" "$NOTE" "$HOST" <<'PYEOF' | tee -a "$SURVEY_OUT"
import json, sys
tmp, ts, loc, track, note, host = sys.argv[1:7]
track = {m.strip().lower() for m in track.split(",") if m.strip()}
BAND = {"ng": "2g", "na": "5g", "6e": "6g"}

# ---- AP-side dumps ----
dumps, name = {}, None
for line in open(f"{tmp}/aps.txt"):
    if line.startswith("___AP___"):
        name = line.strip().replace("___AP___", ""); dumps[name] = []
    elif name:
        dumps[name].append(line)

rows, bssid_map, sidch_map = [], {}, {}   # bssid -> (ap,band,ssid); (ssid,ch) -> same
for ap, buf in dumps.items():
    try:
        d = json.loads("".join(buf))
    except ValueError:
        print(f"!! {ap}: no/bad mca-dump output, skipped", file=sys.stderr); continue
    for vt in d.get("vap_table", []):
        band = BAND.get(vt.get("radio", ""), vt.get("radio", "?"))
        ssid, bssid = vt.get("essid", "?"), vt.get("bssid", "").lower()
        ch = str(vt.get("channel", "?"))
        info = (ap, band, ssid)
        if bssid:
            bssid_map[bssid] = info
        sidch_map[(ssid, ch)] = info
        for sta in vt.get("sta_table", []):
            mac = sta.get("mac", "").lower()
            if mac in track:
                dev = sta.get("hostname") or mac
                rows.append([ts, loc, dev, "up", ap, band, ssid, bssid, str(sta.get("signal", "")), note])

# ---- client-side scan (normalized: bssid|ssid|channel|band|rssi) ----
our_ssids = {s for _, _, s in sidch_map.values()}
for line in open(f"{tmp}/scan.psv"):
    parts = line.rstrip("\n").split("|")
    if len(parts) != 5:
        continue
    bss, ssid, ch, band, rssi = parts
    info = bssid_map.get(bss) or sidch_map.get((ssid, ch))
    if info:
        ap, band, ssid = info
    elif ssid in our_ssids:
        ap = "?"                       # ours, but AP not identifiable from this scan
    else:
        continue                       # not one of our networks
    rows.append([ts, loc, host, "down", ap, band, ssid, bss, rssi, note])

for r in rows:
    print("|".join(r))
PYEOF

echo ">> appended to $SURVEY_OUT" >&2
