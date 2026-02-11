#!/bin/bash
# labs/lab-006-vwan-spoke-bgp-router-loopback/scripts/router/pull-config.sh
# Pulls router config blobs from Azure Storage using Managed Identity.
# Designed to be run on the router VM (via cloud-init, cron, or az vm run-command).
#
# Usage:
#   pull-config.sh <storage-account> <container> [dest-dir]
#
# Example:
#   pull-config.sh stlab006router router-config /opt/router-config
#
# Requires: az CLI installed on the VM, system-assigned managed identity
# with Storage Blob Data Reader on the storage account.

set -euo pipefail

STORAGE_ACCOUNT="${1:?Usage: pull-config.sh <storage-account> <container> [dest-dir]}"
CONTAINER="${2:?Usage: pull-config.sh <storage-account> <container> [dest-dir]}"
DEST_DIR="${3:-/opt/router-config}"

BLOBS="frr.conf apply.sh"

echo "[pull-config] Storage: $STORAGE_ACCOUNT / $CONTAINER"
echo "[pull-config] Destination: $DEST_DIR"

mkdir -p "$DEST_DIR"

# Login with managed identity (idempotent -- succeeds if already logged in)
az login --identity --allow-no-subscriptions --output none 2>/dev/null || true

for blob in $BLOBS; do
  echo "[pull-config] Downloading $blob..."
  az storage blob download \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$blob" \
    --file "$DEST_DIR/$blob" \
    --auth-mode login \
    --output none 2>/dev/null

  if [ $? -eq 0 ]; then
    echo "[pull-config] OK: $blob"
  else
    echo "[pull-config] WARN: Failed to download $blob (may not exist yet)"
  fi
done

# Make apply.sh executable
chmod +x "$DEST_DIR/apply.sh" 2>/dev/null || true

echo "[pull-config] Pull complete. Run: $DEST_DIR/apply.sh $DEST_DIR/frr.conf"
