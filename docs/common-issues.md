# Common Issue Patterns

## Buffering on Streaming Devices

### Symptoms
- Video pauses/rebuffers periodically
- Quality drops then recovers

### Diagnosis steps
1. `collect-unifi-db.sh client-stats <device-ip>` — check retry %, RSSI, satisfaction
2. If retry >10% or satisfaction <90 → WiFi problem; jump to WiFi causes below
3. Otherwise: `quick-diag.sh --target <device-ip> --duration 60` during buffering
4. Check retransmit report

### Common causes

**High retransmit rate (>2%)**
- WiFi interference → change channel, check utilization
- Weak signal → move AP or device, lower Min-RSSI
- Driver issue → check firmware updates

**Latency spikes (>50ms to gateway)**
- Bufferbloat → enable SQM/Smart Queues on the router
- WiFi contention → too many devices on same AP/channel
- Router CPU overload → `ssh udr "top -bn1 | head -20"`

**DNS delays (>100ms)**
- Slow upstream DNS → switch to 1.1.1.1 or 8.8.8.8
- DNS rebinding protection blocking CDN → check router threat management

**Zero windows in capture**
- Device buffer exhaustion → device hardware limitation
- TCP window scaling issue → check MSS/MTU

**Good throughput but still buffering**
- Application-layer issue (not network)
- CDN routing problem → traceroute to content server
- Device software bug → restart app/device

## High Latency in Games

### Quick check
```bash
ping -c 20 <game-server>
./scripts/analyze-bufferbloat.sh
```

### Common causes
- Bufferbloat (most common) → SQM
- WiFi (switch to ethernet if possible)
- ISP routing → traceroute, compare paths

## Devices Dropping Off WiFi

### Log check
```bash
./scripts/collect-logs.sh --filter "deauth|disassoc|disconnect|<device-mac>" --since 2h
./scripts/collect-unifi-db.sh wifi-events <device-mac> --since 1
```

### Common causes
- Roaming between APs → check RSSI thresholds, enable 802.11r/k
- DHCP lease issues → check lease table
- AP overloaded → check client count per AP
- Aggressive power save on device → device WiFi settings
- Missing `hostapd .vlan` file on the router → toggle a WLAN setting in the UI to
  regenerate; symptom is one specific SSID refusing associations while others
  work fine on the same radio

## Sticky Clients (won't roam off a weak AP)

### Symptoms
- Phone in far room shows strong RSSI on the wrong AP
- Client stays at -80 dBm instead of jumping to closer AP at -55

### Diagnosis
1. `collect-unifi-db.sh wifi-events <mac> --since 1` — confirm it's not roaming
2. Note which AP/radio it's stuck on
3. Tighten that radio's Min-RSSI (-75 → -70 → -67 in steps) until it gets kicked

### Notes
- Min-RSSI causes a brief disconnect on eviction. Enable 802.11r/k on the SSID
  for smoother handoff.
- 6GHz radios often need tighter Min-RSSI than 5GHz because range is shorter
  but clients still see the BSS at low signal.

## Aggressive Disconnects When Moving Between Rooms (Roam-Kick Lockout)

### Symptoms
- Walking from one AP's zone to another causes a 10-30s drop, sometimes a fallback to cellular
- Device clings to a band (especially 6GHz) and then disconnects hard instead of roaming
- Devices in one specific room disconnect periodically even when on the nearest AP

### Root-cause model
UniFi has THREE separate kick/steering mechanisms; any of them can deny or kick, and they compound:
1. **Per-radio Min-RSSI** (device → radio settings): kicks existing clients below the threshold AND
   denies (re)association below it
2. **WLAN-level Roaming Assistant** (per band, under "Roaming Assistance" next to 802.11r/v): applies
   to EVERY AP broadcasting the SSID — easy to forget, easy to over-tighten
3. **Band steering** (device-level)

Client behavior makes denial much worse than a kick: Apple clients treat "AP still beaconing but
refusing my auth" as transient and retry the same BSSID over and over (look for `auth_flood`),
instead of trying another AP. Only "AP vanished" triggers a clean re-pick. A client whose uplink is
below every threshold in a room is locked out of every radio at once and flails to cellular.

Two invariants worth checking on any roaming complaint:
- **A gated 6GHz radio needs an ungated same-AP 5GHz escape hatch.** Apple clients join 6GHz whenever
  they can hear it; no TX power level makes 6GHz attractive up close yet ignorable through walls. The
  graceful exit from a 6GHz kick is a same-AP 5GHz reassociation — in logs:
  `UBNT ROAM` + `ignored kick-sta ... (reason:On other VAP)`.
- **All thresholds act on AP-side (uplink) RSSI, which runs ~6-12 dB worse than what the client or
  WiFiman shows.** Never tune kick thresholds from client-side readings; measure uplink with
  `collect-survey.sh` (the `up` rows) or `mca-dump` on the AP.

### Diagnosis steps
1. Dump ALL kick mechanisms before tuning anything (one is always forgotten):
   - per-radio: `mongo ace` → `db.device.find({},{name:1,"radio_table.radio":1,"radio_table.min_rssi_enabled":1,"radio_table.min_rssi":1})`
   - WLAN-wide: `db.wlanconf.findOne({name:"<SSID>"})` → `roaming_assistant_*_enabled/_rssi`,
     `fast_roaming_enabled`, `bss_transition`; device-level: `bandsteering_mode`
2. Survey the problem room: `collect-survey.sh <room>` with the affected device carried along and in
   `--track`. Compare the room's **up** numbers against EVERY threshold from step 1.
3. If the best AP's uplink in that room is below all thresholds → the room is mathematically locked
   out. That is the bug; no client-side fix exists.
4. Reproduce with a walk test while watching the gateway log. Signatures in /var/log/daemon.log:
   - `kick-sta-on ... (reason:Low RSSI)` repeating for many seconds — client refusing a Min-RSSI kick
   - STA_ASSOC_TRACKER `failure` with `rssia` flag — association DENIED for low RSSI
   - `auth_flood` — client retry-storming a radio that keeps refusing it (lockout in progress)
   - `auth_algo: ft` with `auth_failures` — broken 802.11r; plain SAE completes in ~50ms when accepted,
     so disabling fast roaming can be FASTER than broken fast roaming
   - `UBNT ROAM` / `ignored kick ... On other VAP` — healthy graceful roam (what success looks like)

### Fix pattern
- Roaming Assistant: off, or set below the worst legit room's uplink (remember: it hits all APs at once)
- Every AP with a gated 6GHz radio must also broadcast ungated 5GHz (the escape hatch)
- Per-radio Min-RSSI: worst uplink among rooms where that AP is the correct choice, minus 3-5 dB margin
- Keep 802.11v Handoff Suggestions ON (advisory, clients may ignore — it is the gentle mechanism);
  treat 802.11r as guilty until a walk test proves it works on your firmware
