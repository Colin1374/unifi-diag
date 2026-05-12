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
- Bufferbloat → enable SQM/Smart Queues on UDR
- WiFi contention → too many devices on same AP/channel
- UDR CPU overload → `ssh udr "top -bn1 | head -20"`

**DNS delays (>100ms)**
- Slow upstream DNS → switch to 1.1.1.1 or 8.8.8.8
- DNS rebinding protection blocking CDN → check UDR threat management

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
- Missing `hostapd .vlan` file on UDR → toggle a WLAN setting in the UI to
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
