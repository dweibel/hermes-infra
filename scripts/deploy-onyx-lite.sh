#!/bin/bash
set -euo pipefail

# Deploy Onyx Lite chat UI connected to the Hermes agent.
# Uses Podman Compose with the Lite override to exclude Vespa and Redis.
#
# Usage:
#   ./scripts/deploy-onyx-lite.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/deploy-onyx-lite.sh  # run remotely
#
# Prerequisites:
#   - Podman and podman-compose installed
#   - Hermes agent running on port 8081
#   - onyx/.env populated (see onyx/env.prod.template)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ONYX_DIR="$REPO_DIR/onyx"

COMPOSE_BASE="docker-compose.yml"
COMPOSE_LITE="docker-compose.onyx-lite.yml"
HERMES_API_HOST="10.88.0.1"
HERMES_API_PORT="8081"

echo "=== Onyx Lite Deployment ==="

# --- Pre-flight checks ---

echo "Running pre-flight checks..."

if [ ! -f "$ONYX_DIR/$COMPOSE_BASE" ]; then
    echo "ERROR: $ONYX_DIR/$COMPOSE_BASE not found."
    exit 1
fi

if [ ! -f "$ONYX_DIR/$COMPOSE_LITE" ]; then
    echo "ERROR: $ONYX_DIR/$COMPOSE_LITE not found."
    exit 1
fi

if [ ! -f "$ONYX_DIR/.env" ]; then
    echo "ERROR: $ONYX_DIR/.env not found."
    echo "Copy onyx/env.prod.template to onyx/.env and fill in the values."
    exit 1
fi

# Check that Hermes API is reachable on the Podman bridge
echo "Checking Hermes API reachability on ${HERMES_API_HOST}:${HERMES_API_PORT}..."
if ! curl -sf --connect-timeout 5 "http://${HERMES_API_HOST}:${HERMES_API_PORT}/v1/models" > /dev/null 2>&1; then
    echo "ERROR: Hermes API is not reachable at http://${HERMES_API_HOST}:${HERMES_API_PORT}/v1/models"
    echo "Ensure the Hermes agent container is running (see scripts/deploy-hermes.sh)."
    exit 1
fi

echo "Pre-flight checks passed."

# --- Tear down existing containers ---

echo "Stopping existing Onyx Lite containers (if any)..."
cd "$ONYX_DIR"
podman compose -f "$COMPOSE_BASE" -f "$COMPOSE_LITE" down --remove-orphans 2>/dev/null || true

# --- Deploy Onyx Lite stack ---

echo "Starting Onyx Lite stack..."
podman compose -f "$COMPOSE_BASE" -f "$COMPOSE_LITE" up -d

# --- Verify deployment ---

echo "Waiting for services to start..."
sleep 10

if podman ps --format '{{.Names}}' | grep -q "onyx-web-server"; then
    echo ""
    echo "=== Onyx Lite Status ==="
    podman compose -f "$COMPOSE_BASE" -f "$COMPOSE_LITE" ps
    echo ""
    echo "SUCCESS: Onyx Lite is running on port 3080."
    echo ""
    echo "Next steps:"
    echo "  - Access locally: http://localhost:3080"
    echo "  - Access via tunnel: https://hermes-chat.yourdomain.com"
    echo "  - View logs: podman compose -f $COMPOSE_BASE -f $COMPOSE_LITE logs -f"
else
    echo ""
    echo "ERROR: Onyx Lite containers failed to start."
    echo "Check logs: cd $ONYX_DIR && podman compose -f $COMPOSE_BASE -f $COMPOSE_LITE logs"
    exit 1
fi
