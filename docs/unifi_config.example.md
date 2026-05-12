# UniFi Configuration Digest (Example)

This is a *sanitized example* of what `collect-unifi-db.sh topology` plus a
bit of manual annotation might produce after you study your own UDR config.
It's here to show the agent what to look for when diagnosing — not as
documentation of any particular network.

Pulled from UDR MongoDB on YYYY-MM-DD.

## WAN
- **Internet 1** — DHCP, primary
- **Internet 2** — DHCP, failover (optional)
- Smart Queues (SQM): enabled / disabled
- Hardware offloading: enabled

## DNS
- DoH enabled: e.g. Cloudflare, Quad9
- Fallback resolvers: 1.1.1.1, 8.8.8.8

## VLANs / Networks

| Name    | Subnet         | VLAN | DHCP Range | Isolation | Notes      |
|---------|----------------|------|------------|-----------|------------|
| Default | 10.0.1.1/24    | none | .6-.254    | no        | Main LAN   |
| IoT     | 10.0.3.1/24    | 3    | .6-.254    | optional  | IoT VLAN   |
| Legacy  | 192.168.2.1/24 | 2    | .6-.254    | no        | 2.4-only   |

## WLANs

| Name      | Bands     | Security  | Hidden | Fast Roam | PMF       | Network |
|-----------|-----------|-----------|--------|-----------|-----------|---------|
| Main      | 2g/5g/6g  | WPA2-PSK  | no     | yes (11r) | optional  | Default |
| Legacy    | 2g only   | WPA2-PSK  | yes    | no        | disabled  | Legacy  |
| IoT       | 2g/5g/6g  | WPA2-PSK  | yes    | no        | optional  | IoT     |

## Per-Radio Min RSSI (eviction threshold)

These get tuned when you see clients sticking to a weak AP instead of roaming.
Tighter (less negative) Min-RSSI kicks them off sooner.

| AP       | 2.4GHz | 5GHz | 6GHz |
|----------|--------|------|------|
| AP-Main  | -75    | -72  | -70  |
| AP-Sec   | -75    | -72  | n/a  |

## WiFi Settings to inspect

- DTIM intervals (ng/na/6e)
- Proxy ARP (often on for main SSID)
- BSS Transition Management (802.11v)
- 802.11k neighbor reports
- UAPSD
- Multicast enhancement

## Security / IDS

- IDS mode (detect-only) vs IPS (block)
- Enabled signature categories
- DNS filtering / ad blocking

## Firewall Rules

Document any custom rules — they're easy to forget you wrote.

## Port Forwards

| Name           | WAN Port | Forward To | Port | Proto    |
|----------------|----------|------------|------|----------|
| (example)      | 47222    | 10.0.1.69  | 32400| tcp+udp  |

## Common Diagnostic Observations

### No SQM
If WAN is asymmetric (e.g. 1Gbps down / 100Mbps up), upload saturation is the
usual buffering culprit. SQM on the upload side helps, but check the UDR
doesn't tax its CPU at gigabit speeds.

### IoT VLAN not isolated
Many home setups disable network isolation so HomeKit/mDNS works. That means
IoT devices can reach main LAN. Worth knowing when reasoning about traffic.

### Fast Roaming on only one SSID
If 802.11r is enabled on the main SSID but not on hidden/IoT SSIDs, roams on
those will be slower (full re-auth).

### High retry rate on an AP
Channel congestion, too many clients on one AP, or interference from
neighbors. Cross-reference with `health` output (per-AP satisfaction score).
