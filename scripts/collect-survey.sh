#!/usr/bin/env bash
# collect-survey.sh — per-room WiFi survey sampler for Min-RSSI tuning + RSSI fingerprint DB.
#
# RUN THIS ON A SURVEY LAPTOP (Linux with iw + python3), not on the UDR.
# Laptop needs: ssh access to the UDR (host alias or IP via UDR_HOST), python3,
# sudo rights for `iw scan`. No AP credentials are stored — they are fetched
# from the controller's Mongo (setting.mgmt) at runtime, inside the UDR session.
#
# Captures BOTH directions at each spot:
#   down — client-side scan RSSI of every visible home BSSID (sudo iw scan)
#   up   — AP-side RSSI of tracked client MACs (mca-dump on UDR + sshpass hop
#          to any other managed APs). "up" is what the Min-RSSI gate acts on.
#
# Config (env vars, or put them in scripts/survey.local.conf — gitignored):
#   UDR_HOST    ssh destination for the UDR            (default: udr)
#   AP_HOPS     space-separated Name:IP of other APs   (default: none; e.g. "AP1:192.168.1.20 AP2:192.168.1.21")
#   TRACK_MACS  extra client MACs to record AP-side    (default: none; surveying laptop is always tracked)
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

report() {
  python3 - "$SURVEY_OUT" <<'PYEOF'
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
[ $# -ge 1 ] || { grep '^# ' "$0" | head -31; exit 1; }

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

IFC="$(iw dev | awk '$1=="Interface"{print $2; exit}')"
[ -n "$IFC" ] || { echo "no wifi interface found" >&2; exit 1; }
MY_MAC="$(cat "/sys/class/net/$IFC/address")"
TRACK="$MY_MAC,$TRACK"
TS="$(date +%Y-%m-%dT%H:%M:%S)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo ">> [$LOCATION] client-side scan on $IFC ..." >&2
for attempt in 1 2 3; do
  if sudo iw dev "$IFC" scan > "$TMP/scan.txt" 2>"$TMP/scan.err"; then break; fi
  [ "$attempt" = 3 ] && { cat "$TMP/scan.err" >&2; exit 1; }
  sleep 2
done

echo ">> AP-side mca-dump (UDR + hops) ..." >&2
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

python3 - "$TMP" "$TS" "$LOCATION" "$TRACK" "$NOTE" "$(hostname -s)" <<'PYEOF' | tee -a "$SURVEY_OUT"
import json, re, sys
tmp, ts, loc, track, note, host = sys.argv[1:7]
track = {m.strip().lower() for m in track.split(",") if m.strip()}
BAND = {"ng": "2g", "na": "5g", "6e": "6g"}

def band_of(freq):
    f = int(freq)
    return "2g" if f < 3000 else ("5g" if f < 5945 else "6g")

# ---- AP-side dumps ----
dumps, name = {}, None
for line in open(f"{tmp}/aps.txt"):
    if line.startswith("___AP___"):
        name = line.strip().replace("___AP___", ""); dumps[name] = []
    elif name:
        dumps[name].append(line)

rows, bssid_map = [], {}   # bssid -> (ap, band, ssid)
for ap, buf in dumps.items():
    try:
        d = json.loads("".join(buf))
    except ValueError:
        print(f"!! {ap}: no/with bad mca-dump output, skipped", file=sys.stderr); continue
    for vt in d.get("vap_table", []):
        band = BAND.get(vt.get("radio", ""), vt.get("radio", "?"))
        ssid, bssid = vt.get("essid", "?"), vt.get("bssid", "").lower()
        if bssid:
            bssid_map[bssid] = (ap, band, ssid)
        for sta in vt.get("sta_table", []):
            mac = sta.get("mac", "").lower()
            if mac in track:
                dev = sta.get("hostname") or mac
                rows.append([ts, loc, dev, "up", ap, band, ssid, bssid, str(sta.get("signal", "")), note])

# ---- client-side scan ----
bss, freq, sig, ssid = None, None, None, None
def flush():
    if not bss or sig is None:
        return
    ap, band, sname = bssid_map.get(bss, (None, band_of(freq or 0), ssid or "?"))
    if ap is None:
        if not ssid or ssid not in {s for _, _, s in bssid_map.values()}:
            return                      # not one of our networks
        ap = "?"
        sname = ssid
    rows.append([ts, loc, host, "down", ap, band, sname, bss, str(round(float(sig))), note])

for line in open(f"{tmp}/scan.txt"):
    m = re.match(r"^BSS ([0-9a-f:]{17})", line)
    if m:
        flush(); bss, freq, sig, ssid = m.group(1).lower(), None, None, None
    elif "freq:" in line:
        freq = float(line.split("freq:")[1].strip().split()[0])
    elif "signal:" in line:
        sig = float(line.split("signal:")[1].strip().split()[0])
    elif re.match(r"^\s+SSID:", line):
        ssid = line.split("SSID:", 1)[1].strip()
flush()

for r in rows:
    print("|".join(r))
PYEOF

echo ">> appended to $SURVEY_OUT" >&2
