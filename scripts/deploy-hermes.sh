#!/bin/bash
set -euo pipefail

# Deploy the Hermes agent container in Podman.
# Stops and removes any existing hermes-agent container before starting fresh.
#
# Usage:
#   ./scripts/deploy-hermes.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/deploy-hermes.sh  # run remotely
#
# Prerequisites:
#   - Podman installed
#   - /mnt/workspace/hermes/ directory created (see scripts/setup-hermes-dirs.sh)
#   - /mnt/workspace/hermes/.env populated with secrets (see config/.env.example)
#   - config.yaml deployed to /mnt/workspace/hermes/

CONTAINER_NAME="hermes-agent"
# Pinned to v0.13.0 (v2026.5.7) — same manifest as :latest at time of deployment
IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:sha-474d1e812bf3fe1a1f75b2ab06f477c631bf62c3}"
HERMES_DIR="/mnt/workspace/hermes"

echo "=== Hermes Agent Deployment ==="

# --- Pre-flight checks ---

echo "Running pre-flight checks..."

if [ ! -d "$HERMES_DIR" ]; then
    echo "ERROR: $HERMES_DIR does not exist."
    echo "Run scripts/setup-hermes-dirs.sh first."
    exit 1
fi

if [ ! -f "$HERMES_DIR/.env" ]; then
    echo "ERROR: $HERMES_DIR/.env not found."
    echo "Copy config/.env.example to $HERMES_DIR/.env and fill in the values."
    exit 1
fi

if [ ! -f "$HERMES_DIR/config.yaml" ]; then
    echo "ERROR: $HERMES_DIR/config.yaml not found."
    echo "Copy config/config.yaml to $HERMES_DIR/config.yaml."
    exit 1
fi

echo "Pre-flight checks passed."

# --- Ensure gateway can find .env at ~/.hermes/.env (HOME=/opt/data inside container) ---

if [ ! -d "$HERMES_DIR/.hermes" ]; then
    echo "Creating $HERMES_DIR/.hermes/ for gateway .env discovery..."
    mkdir -p "$HERMES_DIR/.hermes"
fi

if [ ! -L "$HERMES_DIR/.hermes/.env" ]; then
    echo "Symlinking .env into .hermes/ (gateway reads ~/.hermes/.env)..."
    ln -sf /opt/data/.env "$HERMES_DIR/.hermes/.env"
fi

# --- Stop and remove existing container ---

if podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Stopping existing container '${CONTAINER_NAME}'..."
    podman stop "$CONTAINER_NAME" 2>/dev/null || true
    echo "Removing existing container '${CONTAINER_NAME}'..."
    podman rm "$CONTAINER_NAME" 2>/dev/null || true
fi

# --- Pull latest image ---

echo "Pulling image: $IMAGE"
podman pull "$IMAGE"

# --- Start container ---

# Load API key from .env for API server configuration
API_KEY=$(grep -E '^HERMES_API_KEY=' "$HERMES_DIR/.env" | cut -d'=' -f2-)

echo "Starting container '${CONTAINER_NAME}'..."
podman run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --env-file "$HERMES_DIR/.env" \
    -e API_SERVER_ENABLED=true \
    -e API_SERVER_HOST=0.0.0.0 \
    -e API_SERVER_PORT=8081 \
    -e API_SERVER_KEY="$API_KEY" \
    -p 8081:8081 \
    -p 8082:8082 \
    -p 9119:9119 \
    -v /mnt/workspace/hermes:/opt/data:Z \
    "$IMAGE" gateway run

# --- Verify container is running ---

sleep 3

if podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo ""
    echo "=== Container Status ==="
    podman ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    # Pre-build TUI so the first WebSocket connection doesn't block the event loop
    echo ""
    echo "=== Pre-building TUI ==="
    podman exec "$CONTAINER_NAME" bash -c "cd /opt/hermes/ui-tui && npm run build --prefix packages/hermes-ink 2>&1 | tail -1 && npm run build 2>&1 | tail -1"
    podman exec "$CONTAINER_NAME" touch /opt/hermes/ui-tui/packages/hermes-ink/dist/ink-bundle.js /opt/hermes/ui-tui/dist/entry.js
    echo "TUI pre-built successfully."

    # Fix auth.json permissions (may be root-owned from prior runs)
    if [ -f "$HERMES_DIR/auth.json" ]; then
        echo ""
        echo "=== Fixing auth.json permissions ==="
        chmod 666 "$HERMES_DIR/auth.json" 2>/dev/null || sudo chmod 666 "$HERMES_DIR/auth.json"
    fi

    # Patch CORS to allow external domain via Cloudflare Tunnel
    echo ""
    echo "=== Patching CORS for hermes.dirkweibel.dev ==="
    podman exec "$CONTAINER_NAME" sed -i \
        's|allow_origin_regex=r"^https?://(localhost\|127\\.0\\.0\\.1)(:\\d+)?$"|allow_origin_regex=r"^https?://(localhost\|127\\.0\\.0\\.1\|hermes\\.dirkweibel\\.dev)(:\\d+)?$"|' \
        /opt/hermes/hermes_cli/web_server.py
    echo "CORS patched."

    # Restart to pick up CORS patch
    echo ""
    echo "=== Restarting to apply CORS patch ==="
    podman restart "$CONTAINER_NAME"
    sleep 5

    echo ""
    echo "SUCCESS: Hermes agent container is running."
    echo "Dashboard auto-starts via HERMES_DASHBOARD=1 in .env."
    echo ""
    echo "Next steps:"
    echo "  - Test API: curl -H 'Authorization: Bearer <key>' http://localhost:8081/v1/models"
    echo "  - View logs: podman logs -f ${CONTAINER_NAME}"
else
    echo ""
    echo "ERROR: Container failed to start."
    echo "Check logs: podman logs ${CONTAINER_NAME}"
    exit 1
fi
