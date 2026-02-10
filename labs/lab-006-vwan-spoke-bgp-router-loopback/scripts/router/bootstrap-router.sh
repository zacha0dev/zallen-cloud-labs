#!/bin/bash
# labs/lab-006-vwan-spoke-bgp-router-loopback/scripts/router/bootstrap-router.sh
# Manual bootstrap script for router VM (alternative to cloud-init)
# Run via: az vm run-command invoke --scripts @bootstrap-router.sh
#
# This script:
# 1. Installs FRR
# 2. Enables IP forwarding at OS level
# 3. Creates dummy loopback interface with test prefixes
# 4. Enables BGP daemon
#
# NOTE: FRR peer IPs must be configured after deployment.
#       See cloud-init-router.yaml for the full FRR config.

set -euo pipefail

echo "[lab-006] Starting router bootstrap..."

# --- Install FRR ---
echo "[lab-006] Installing FRR..."
apt-get update -qq
apt-get install -y -qq frr frr-pythontools tcpdump traceroute net-tools jq

# --- Enable IP forwarding ---
echo "[lab-006] Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf

# --- Create loopback interface ---
echo "[lab-006] Creating loopback interface (lo0)..."
if ! ip link show lo0 > /dev/null 2>&1; then
  ip link add lo0 type dummy
fi
ip link set lo0 up
ip addr add 10.61.250.1/32 dev lo0 2>/dev/null || true
ip addr add 10.200.200.1/32 dev lo0 2>/dev/null || true

# Make persistent
cat > /etc/networkd-dispatcher/routable.d/50-loopback <<'SCRIPT'
#!/bin/bash
ip link show lo0 > /dev/null 2>&1 || {
  ip link add lo0 type dummy
  ip link set lo0 up
  ip addr add 10.61.250.1/32 dev lo0
  ip addr add 10.200.200.1/32 dev lo0
}
SCRIPT
chmod +x /etc/networkd-dispatcher/routable.d/50-loopback

# --- Enable BGP in FRR daemons ---
echo "[lab-006] Enabling BGP daemon in FRR..."
sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons

# --- Restart FRR ---
echo "[lab-006] Restarting FRR..."
systemctl enable frr
systemctl restart frr

echo "[lab-006] Router bootstrap complete."
echo "[lab-006] Next: configure BGP peers in /etc/frr/frr.conf"
echo "[lab-006]   Get vHub router IPs:"
echo "[lab-006]   az network vhub show -g rg-lab-006-vwan-bgp-router -n vhub-lab-006 --query virtualRouterIps -o json"
