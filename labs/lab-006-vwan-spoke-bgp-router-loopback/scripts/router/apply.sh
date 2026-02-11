#!/bin/bash
# labs/lab-006-vwan-spoke-bgp-router-loopback/scripts/router/apply.sh
# Blob-driven router config apply script.
# Pulled from Azure Storage by the router VM via Managed Identity.
#
# This script:
# 1. Ensures bgpd=yes in /etc/frr/daemons (idempotent)
# 2. Copies frr.conf from the same blob container
# 3. Restarts FRR
#
# Usage (on the router VM):
#   /opt/router-config/apply.sh /opt/router-config/frr.conf
#
# Or via az vm run-command from your workstation:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript \
#     --scripts "/opt/router-config/apply.sh /opt/router-config/frr.conf"

set -euo pipefail

FRR_CONF_SRC="${1:-/opt/router-config/frr.conf}"
FRR_CONF_DEST="/etc/frr/frr.conf"
FRR_DAEMONS="/etc/frr/daemons"

echo "[apply.sh] Starting router config apply..."

# --- Ensure bgpd=yes in daemons (idempotent) ---
if grep -q '^bgpd=no' "$FRR_DAEMONS" 2>/dev/null; then
  echo "[apply.sh] Enabling bgpd in $FRR_DAEMONS"
  sed -i 's/^bgpd=no/bgpd=yes/' "$FRR_DAEMONS"
fi

# --- Apply frr.conf ---
if [ ! -f "$FRR_CONF_SRC" ]; then
  echo "[apply.sh] ERROR: FRR config not found at $FRR_CONF_SRC"
  exit 1
fi

echo "[apply.sh] Copying $FRR_CONF_SRC -> $FRR_CONF_DEST"
cp "$FRR_CONF_SRC" "$FRR_CONF_DEST"
chown frr:frr "$FRR_CONF_DEST"
chmod 640 "$FRR_CONF_DEST"

# --- Restart FRR ---
echo "[apply.sh] Restarting FRR..."
systemctl restart frr

# --- Brief validation ---
sleep 3
echo "[apply.sh] === FRR daemons ==="
grep '^bgpd=' "$FRR_DAEMONS"
echo "[apply.sh] === BGP Summary ==="
sudo vtysh -c "show bgp summary" 2>/dev/null || echo "(BGP not yet converged)"

echo "[apply.sh] Config apply complete."
