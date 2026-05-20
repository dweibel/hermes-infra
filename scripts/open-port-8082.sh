#!/bin/bash
set -euo pipefail

# Open port 8082 in the instance firewall for inbound webhook traffic.
#
# Usage:
#   ssh oci-agent 'bash -s' < scripts/open-port-8082.sh
#   ./scripts/open-port-8082.sh   # run directly on instance
#
# This opens port 8082 via iptables (Oracle Linux 8 default).
# The VCN security list must also allow port 8082 (managed via Terraform).

PORT=8082

echo "=== Opening port ${PORT} for inbound TCP traffic ==="

# Check if rule already exists
if sudo iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    echo "Port ${PORT} is already open in iptables."
else
    sudo iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    echo "Added iptables rule for port ${PORT}."
fi

# Persist the rule across reboots
if command -v iptables-save &>/dev/null; then
    sudo sh -c 'iptables-save > /etc/sysconfig/iptables'
    echo "iptables rules saved to /etc/sysconfig/iptables."
fi

# Verify
echo ""
echo "=== Verification ==="
sudo iptables -L INPUT -n | grep "$PORT"
echo ""
echo "Port ${PORT} is open. Ensure the OCI VCN security list also allows TCP ${PORT} from 0.0.0.0/0."
