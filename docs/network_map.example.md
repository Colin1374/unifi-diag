# Network Map (Example / Template)

Copy this file to `docs/network_map.md` (gitignored) and fill in your real
devices. The richer this is, the better the agent can target queries.

Last scanned: YYYY-MM-DD

## VLANs / Interfaces
- **br0** — 10.0.1.0/24 — Main LAN
- **br3** — 10.0.3.0/24 — IoT VLAN
- (add as needed)

---

## Network Infrastructure
| Device       | IP         | MAC               | Notes                       |
|--------------|------------|-------------------|-----------------------------|
| UDR          | 10.0.1.1   | aa:bb:cc:00:00:01 | Gateway/router              |
| Switch-1     | 10.0.1.19  | aa:bb:cc:00:00:02 | UniFi 8-port PoE            |
| AP-Main      | 10.0.1.20  | aa:bb:cc:00:00:03 | UniFi U7-Pro-Wall, wired    |
| AP-Secondary | 10.0.1.244 | aa:bb:cc:00:00:04 | UniFi UAP-AC-Lite           |

## Computers / Servers
| Device       | IP         | MAC               | Notes                          |
|--------------|------------|-------------------|--------------------------------|
| media-server | 10.0.1.69  |                   | Plex / media host              |
| desktop      | 10.0.1.21  |                   | Daily driver                   |

## Mobile Devices
| Device       | IP         | MAC               | Notes                          |
|--------------|------------|-------------------|--------------------------------|
| phone-1      | 10.0.1.32  |                   | private MAC (iOS randomized)   |
| tablet-1     | 10.0.1.76  |                   | private MAC                    |

## Entertainment
| Device     | IP        | MAC | Notes |
|------------|-----------|-----|-------|
| game-console | 10.0.1.36 |   | Xbox / PS5 / etc. |
| speaker-1    | 10.0.1.61 |   | Sonos / HomePod   |

## Smart Home
| Device      | IP         | MAC | Notes                |
|-------------|------------|-----|----------------------|
| hub         | 10.0.1.79  |     | Hue / Homebridge etc. |
| thermostat  | 10.0.3.16  |     | On IoT VLAN          |

## IoT VLAN (10.0.3.x)
| Device       | IP         | MAC | Notes                |
|--------------|------------|-----|----------------------|
| camera-1     | 10.0.3.135 |     | IP camera, web UI    |
| esp-device-1 | 10.0.3.66  |     | ESP-based sensor     |

## Unidentified
| IP         | MAC | Notes              |
|------------|-----|--------------------|
| 10.0.1.99  |     | new device YYYY-MM |

## Notes
- Devices with private (randomized) MACs may reappear under new addresses;
  the agent can match by IP via DHCP leases.
- Add per-device quirks here (e.g. "smart bulb drops every few hours; known
  firmware bug").
