# Setup Guide

Everything you need to do to go from a fresh clone to a working diagnostic setup.
There are two sides: **your local machine** (where the agent runs) and **the
UDR** (where the data lives).

If you just want it to work, run `./setup.sh` in the repo root — it does most
of this interactively and prints what you still need to do manually on the UDR.
This document is the long form: read it if you want to understand the pieces,
or if you prefer to do things by hand.

---

## Local side

### 1. Dependencies

You need these on your local machine:

| Tool      | Used for                                    | Install (Debian/Ubuntu)    | Install (macOS)         | Install (Arch)             |
|-----------|---------------------------------------------|----------------------------|-------------------------|----------------------------|
| `bash`    | running the scripts                          | preinstalled               | preinstalled            | preinstalled               |
| `ssh`     | talking to the UDR                           | preinstalled               | preinstalled            | preinstalled               |
| `jq`      | parsing JSON from Mongo queries              | `apt install jq`           | `brew install jq`       | `pacman -S jq`             |
| `tshark`  | pcap analysis (retransmits, RTT, DNS, etc.)  | `apt install tshark`       | `brew install wireshark`| `pacman -S wireshark-cli`  |

Verify:

```bash
which bash ssh jq tshark && tshark --version | head -1
```

You also need an LLM agent that can run shell commands and read files in this
directory. The repo is built around [Claude Code](https://claude.com/claude-code)
(the `CLAUDE.md` file is read automatically at session start), but any
tool-calling agent works — point it at `CLAUDE.md` manually.

### 2. SSH key for the UDR

Generate a dedicated key, no passphrase (the agent needs unattended access):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/udr_diag_key -C "unifi-diag" -N ""
```

### 3. SSH config

Add a host alias so the scripts can just call `ssh udr`. Edit `~/.ssh/config`:

```
Host udr
    HostName 192.168.1.1        # ← your UDR's LAN IP
    User root                   # or "unifi-diag" if you set up a service user (below)
    IdentityFile ~/.ssh/udr_diag_key
    StrictHostKeyChecking accept-new
    ConnectTimeout 5
```

### 4. Local network map

Copy the template and fill in your devices:

```bash
cp docs/network_map.example.md docs/network_map.md
$EDITOR docs/network_map.md
```

You don't have to fill in everything up front. The agent can run
`./scripts/collect-unifi-db.sh clients-lean` to see the current client list,
and you can copy rows over as you identify devices. The richer this gets, the
better the agent can target queries (e.g. "the Apple TV in the den" → IP
lookup → `client-stats` query).

`docs/network_map.md` is gitignored — your real inventory stays private.

### 5. Make scripts executable

```bash
chmod +x scripts/*.sh setup.sh
```

---

## UDR side

> Works on any UniFi OS console with SSH (UDR, UDM, UDM-Pro, UDM-SE,
> UCG-Ultra/Max, Dream Machine, etc.). "UDR" below = your router.

### 0. Enable SSH in the UniFi UI (one-time)

SSH is **off by default** on UniFi OS. Turn it on before anything else:

1. Open the UniFi web UI (e.g. `https://192.168.1.1`).
2. Go to **Settings → System → Advanced → Device SSH Authentication**
   (older firmware: **Console Settings → SSH**).
3. Enable SSH. Set a username and password — this is the local OS login on
   the router, distinct from your UniFi cloud account.
4. Save. Confirm from your local machine:
   ```bash
   ssh <ssh-user>@<router-ip>     # should prompt for the password you just set
   ```

You'll replace the password with key auth in the next steps.

You need SSH access from your local machine to the UDR with the key from
step 2. Pick one of the two approaches below.

### Option A — Root access (simpler)

This is what most home users do. The UDR's `root` account already exists.

```bash
# From your local machine, copy your pubkey over once:
ssh-copy-id -i ~/.ssh/udr_diag_key.pub root@<UDR-IP>
# (You'll be prompted for the UDR root password, which is the same as your
#  UniFi admin password unless you've changed it via `passwd`.)
```

Then in `~/.ssh/config` set `User root`.

**Caveat:** UniFi OS firmware updates sometimes wipe `/root/.ssh/authorized_keys`.
If `ssh udr` stops working after an update, re-run `ssh-copy-id`.

### Option B — Dedicated service user (more careful)

```bash
ssh root@<UDR-IP>

# On the UDR:
adduser --disabled-password --gecos "unifi-diag service" unifi-diag
usermod -aG adm unifi-diag                                   # log access
setcap cap_net_raw,cap_net_admin=eip /usr/sbin/tcpdump        # tcpdump without root

mkdir -p /home/unifi-diag/.ssh
# Paste the contents of ~/.ssh/udr_diag_key.pub from your local machine:
cat >> /home/unifi-diag/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAA... unifi-diag
EOF
chown -R unifi-diag:unifi-diag /home/unifi-diag/.ssh
chmod 700 /home/unifi-diag/.ssh
chmod 600 /home/unifi-diag/.ssh/authorized_keys
```

Then in `~/.ssh/config` set `User unifi-diag`.

**Caveat:** Same as above — firmware updates may remove the user entirely. If
you go this route, keep the `adduser`/`setcap`/`cat >> authorized_keys` block
in a script you can re-run after updates.

The MongoDB queries do not require root — Mongo listens on localhost with no
auth, and any user can `mongo --port 27117`. But `conntrack -L` and reading
some files in `/data/unifi-core/logs/` do require root, so the simpler path is
just to use root.

### UDR tools

These should already be present on UniFi OS:

| Tool       | Used for                            | Install if missing               |
|------------|-------------------------------------|----------------------------------|
| `tcpdump`  | packet capture                       | preinstalled                     |
| `mongo`    | Mongo shell (port 27117, no auth)    | preinstalled with UniFi Network  |
| `conntrack`| conntrack table dumps                | `apt-get install -y conntrack`   |
| standard `grep`/`awk`/`tail` etc.    | log filtering | preinstalled |

Verify:

```bash
ssh udr "which tcpdump mongo conntrack"
```

If `conntrack` is missing, install it:

```bash
ssh udr "apt-get update && apt-get install -y conntrack"
```

### MongoDB on the UDR

The UDR runs MongoDB 3.6 on port 27117 with no authentication, bound to
localhost only. Two databases matter:

- `ace` — configuration: clients, devices, networks, WLANs, firewall, alarms
- `ace_stat` — stats: per-client 5min/hourly/daily metrics, WiFi events, downtime

The scripts query this via the local `mongo` shell over SSH. You don't have to
configure anything — it's already running. Just don't expose port 27117 to your
LAN (it has no auth).

---

## Verify the full stack

```bash
# Local-side tools
which jq tshark

# SSH alias works and key is accepted
ssh udr "echo ok && whoami"

# UDR tools
ssh udr "which tcpdump conntrack mongo"

# Mongo is reachable on the UDR
ssh udr "mongo --port 27117 --quiet --eval 'db.adminCommand({listDatabases:1}).databases.map(d => d.name)'"
# Expected: a JSON array containing "ace" and "ace_stat"

# End-to-end: pull current client list
./scripts/collect-unifi-db.sh clients-lean
# Expected: a pipe-delimited table written to summaries/
```

If all four pass, you're done. Open Claude Code (or your agent of choice) in
this directory and describe a symptom.

---

## Optional: post-firmware-update recovery

Save this script somewhere outside the UDR's transient storage and re-run it
after firmware updates if SSH access breaks:

```bash
#!/usr/bin/env bash
# reauthorize-udr.sh — re-install the diag key on the UDR after a firmware update.
UDR_IP=192.168.1.1
ssh-copy-id -i ~/.ssh/udr_diag_key.pub root@"$UDR_IP"
# If you use Option B, also re-create the user and re-setcap tcpdump here.
```

## Troubleshooting

- `Permission denied (publickey)` — key not installed on UDR. Re-run
  `ssh-copy-id` or re-paste the pubkey into `authorized_keys`.
- `mongo: command not found` on the UDR — the UDR's UniFi Network application
  is not installed or is in a degraded state. Reboot from the UI.
- `tshark: command not found` locally — install Wireshark CLI (see table above).
- Scripts produce huge summaries — pass `--since 1` (or smaller) to narrow the
  time window. The agent's `CLAUDE.md` already biases toward small windows.
- Captures land in `captures/` but analysis fails — check the BPF filter
  matched any traffic with `tshark -r captures/<file>.pcap | head`.
