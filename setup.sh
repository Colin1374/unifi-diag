#!/usr/bin/env bash
# unifi-diag setup — local side bootstrap.
# Does what it can automatically and tells you what to do manually on the UDR.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_PATH="${HOME}/.ssh/udr_diag_key"
SSH_CONFIG="${HOME}/.ssh/config"
SSH_ALIAS="udr"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

bold "==> unifi-diag setup"
echo "Repo: $REPO_DIR"
echo

# --- 1. Local dependency check ----------------------------------------------
bold "==> Checking local dependencies"
missing=()
for tool in bash ssh ssh-keygen jq tshark; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ok    $tool"
  else
    echo "  MISS  $tool"
    missing+=("$tool")
  fi
done
if (( ${#missing[@]} )); then
  red "Missing tools: ${missing[*]}"
  cat <<EOF

Install hints:
  Debian/Ubuntu: sudo apt install ${missing[*]/tshark/tshark}
  macOS:         brew install ${missing[*]/tshark/wireshark} jq
  Arch:          sudo pacman -S ${missing[*]/tshark/wireshark-cli}

Re-run this script when they're installed.
EOF
  exit 1
fi
echo

# --- 2. SSH key --------------------------------------------------------------
bold "==> SSH key"
if [[ -f "$KEY_PATH" ]]; then
  green "  key already exists at $KEY_PATH"
else
  ssh-keygen -t ed25519 -f "$KEY_PATH" -C "unifi-diag" -N ""
  green "  generated $KEY_PATH"
fi
echo

# --- 3. UDR host + SSH config -----------------------------------------------
bold "==> SSH config"
if grep -qE "^Host[[:space:]]+${SSH_ALIAS}\b" "$SSH_CONFIG" 2>/dev/null; then
  green "  Host alias '${SSH_ALIAS}' already configured in $SSH_CONFIG"
  echo "  (skipping; edit it by hand if the IP or user is wrong)"
else
  read -rp "UDR LAN IP (e.g. 192.168.1.1): " udr_ip
  read -rp "SSH user on UDR [root]: " udr_user
  udr_user="${udr_user:-root}"
  mkdir -p "$(dirname "$SSH_CONFIG")"
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  cat >> "$SSH_CONFIG" <<EOF

Host ${SSH_ALIAS}
    HostName ${udr_ip}
    User ${udr_user}
    IdentityFile ${KEY_PATH}
    StrictHostKeyChecking accept-new
    ConnectTimeout 5
EOF
  green "  appended Host '${SSH_ALIAS}' to $SSH_CONFIG"
fi
echo

# --- 4. Make scripts executable ---------------------------------------------
bold "==> Making scripts executable"
chmod +x "$REPO_DIR"/scripts/*.sh
green "  done"
echo

# --- 5. Network map template ------------------------------------------------
bold "==> Network map"
nm="$REPO_DIR/docs/network_map.md"
nm_example="$REPO_DIR/docs/network_map.example.md"
if [[ -f "$nm" ]]; then
  green "  $nm already exists; leaving it alone"
elif [[ -f "$nm_example" ]]; then
  cp "$nm_example" "$nm"
  green "  copied $nm_example -> $nm"
  echo "  Edit $nm to describe your devices (it's gitignored)."
else
  yellow "  $nm_example not found; skipping"
fi
echo

# --- 6. Manual steps remaining ----------------------------------------------
bold "==> Manual steps left for you"
cat <<EOF
1. Install your pubkey on the UDR. Pick one:

   Simple (root):
     ssh-copy-id -i ${KEY_PATH}.pub root@<UDR-IP>

   Service user (see docs/SETUP.md "Option B" for the full snippet).

2. Verify the connection works without a password:
     ssh ${SSH_ALIAS} "echo ok && whoami"

3. Verify UDR tools are present:
     ssh ${SSH_ALIAS} "which tcpdump mongo conntrack"
   If 'conntrack' is missing:
     ssh ${SSH_ALIAS} "apt-get update && apt-get install -y conntrack"

4. End-to-end smoke test:
     ./scripts/collect-unifi-db.sh clients-lean
   You should see a pipe-delimited client table written under summaries/.

5. Fill in docs/network_map.md with your devices as you identify them.
EOF
echo
green "Setup script done."
