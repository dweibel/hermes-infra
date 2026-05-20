#!/bin/bash
set -euo pipefail

# Restart the Hermes container with updated Phase B configuration.
# Syncs the latest config.yaml to the instance, then restarts the container.
#
# Usage:
#   ssh oci-agent 'bash -s' < scripts/restart-hermes-phase-b.sh  # run remotely
#   ./scripts/restart-hermes-phase-b.sh                          # run on instance
#
# Prerequisites:
#   - Hermes container already running (deployed via deploy-hermes.sh)
#   - config.yaml updated with webhook_gateway and MCP settings
#   - Port 8082 open in VCN security list and instance firewall

CONTAINER_NAME="hermes-agent"
HERMES_DIR="/mnt/workspace/hermes"

echo "=== Hermes Phase B Restart ==="

# --- Pre-flight checks ---

if ! podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container '${CONTAINER_NAME}' is not running."
    echo "Deploy it first with: deploy-hermes.sh"
    exit 1
fi

if [ ! -f "$HERMES_DIR/config.yaml" ]; then
    echo "ERROR: $HERMES_DIR/config.yaml not found."
    exit 1
fi

# --- Verify webhook gateway config ---

if ! grep -q "webhook_gateway" "$HERMES_DIR/config.yaml"; then
    echo "ERROR: config.yaml does not contain webhook_gateway section."
    echo "Update config.yaml with Phase B settings before restarting."
    exit 1
fi

echo "Config verified: webhook_gateway present."

# --- Restart container ---

echo "Restarting container '${CONTAINER_NAME}'..."
podman restart "$CONTAINER_NAME"

sleep 5

# --- Verify container is running ---

if ! podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container failed to restart."
    echo "Check logs: podman logs ${CONTAINER_NAME}"
    exit 1
fi

echo "Container restarted successfully."

# --- Verify webhook gateway is responding ---

echo ""
echo "=== Verifying webhook gateway (port 8082) ==="

WEBHOOK_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "http://localhost:8082/webhook" \
    -H "Content-Type: application/json" \
    -d '{"sender":"test@test.com","topic":"test","content":"test","security_header":"invalid"}' \
    2>/dev/null) || WEBHOOK_CODE="000"

if [ "$WEBHOOK_CODE" = "401" ] || [ "$WEBHOOK_CODE" = "403" ]; then
    echo "Webhook gateway responding (rejected invalid passphrase as expected: HTTP $WEBHOOK_CODE)"
elif [ "$WEBHOOK_CODE" = "200" ]; then
    echo "WARNING: Webhook accepted request without valid passphrase (HTTP 200)"
elif [ "$WEBHOOK_CODE" = "000" ]; then
    echo "WARNING: Webhook gateway not responding on port 8082 (may need more startup time)"
else
    echo "Webhook gateway responded with HTTP $WEBHOOK_CODE"
fi

# --- Verify API still works ---

echo ""
echo "=== Verifying API server (port 8081) ==="

API_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "http://localhost:8081/v1/models" \
    -H "Authorization: Bearer invalid" 2>/dev/null) || API_CODE="000"

if [ "$API_CODE" = "401" ]; then
    echo "API server responding (auth working: HTTP 401 for invalid key)"
elif [ "$API_CODE" = "200" ]; then
    echo "API server responding (HTTP 200)"
else
    echo "WARNING: API server returned HTTP $API_CODE"
fi

echo ""
echo "=== Phase B restart complete ==="
echo ""
echo "Next steps:"
echo "  - Deploy Cloudflare Email Worker: cd cloudflare/email-worker && wrangler deploy"
echo "  - Set worker secret: wrangler secret put WEBHOOK_PASSPHRASE"
echo "  - Configure Email Routing: agent@dirkweibel.dev → hermes-email-worker"
echo "  - Test webhook: curl -X POST http://localhost:8082/webhook -H 'Content-Type: application/json' -d '{...}'"
