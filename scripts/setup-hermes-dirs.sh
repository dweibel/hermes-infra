#!/bin/bash
set -euo pipefail

# Setup Hermes data directories on the block volume
# Run on the OCI instance or remotely via: ssh oci-agent 'bash -s' < scripts/setup-hermes-dirs.sh
#
# Prerequisites:
#   - Block volume mounted at /mnt/workspace (see oci-infra/scripts/setup-block-volume.sh)
#   - Run as opc user (or with sudo for ownership changes)

MOUNT_PATH="/mnt/workspace"
HERMES_DIR="$MOUNT_PATH/hermes"

echo "=== Hermes Directory Setup ==="

# Verify block volume is mounted
if ! mountpoint -q "$MOUNT_PATH"; then
    echo "ERROR: $MOUNT_PATH is not mounted. Run setup-block-volume.sh first."
    exit 1
fi

# Create Hermes directory structure
echo "Creating Hermes directories..."
mkdir -p "$HERMES_DIR"
mkdir -p "$HERMES_DIR/data"

# Set ownership to opc user (matches block volume convention)
sudo chown -R opc:opc "$HERMES_DIR"

echo ""
echo "=== Verification ==="
ls -la "$HERMES_DIR/"
echo ""
echo "=== Hermes directory setup complete ==="
echo "Next steps:"
echo "  1. Copy config.yaml to $HERMES_DIR/"
echo "  2. Create .env file in $HERMES_DIR/ (see config/.env.example)"
