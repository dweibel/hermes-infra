#!/bin/bash
set -euo pipefail

# Restart the Hermes container with the dashboard enabled on port 9119.

CONTAINER_NAME="hermes-agent"
IMAGE="nousresearch/hermes-agent:sha-474d1e812bf3fe1a1f75b2ab06f477c631bf62c3"
HERMES_DIR="/mnt/workspace/hermes"

# Read API key
API_KEY=$(sudo grep "^HERMES_API_KEY=" "$HERMES_DIR/.env" | cut -d'=' -f2-)
if [ -z "$API_KEY" ]; then
    echo "ERROR: Could not read HERMES_API_KEY"
    exit 1
fi

# Ensure gateway can find .env at ~/.hermes/.env (HOME=/opt/data inside container)
if [ ! -d "$HERMES_DIR/.hermes" ]; then
    echo "Creating $HERMES_DIR/.hermes/ for gateway .env discovery..."
    sudo mkdir -p "$HERMES_DIR/.hermes"
fi

# Copy .env (not symlink) to avoid SELinux relabeling issues with Podman :Z volumes
echo "Copying .env into .hermes/ (gateway reads ~/.hermes/.env)..."
sudo cp "$HERMES_DIR/.env" "$HERMES_DIR/.hermes/.env"

echo "Stopping existing container..."
podman stop "$CONTAINER_NAME" 2>/dev/null || true
podman rm "$CONTAINER_NAME" 2>/dev/null || true

echo "Starting Hermes with dashboard enabled..."
podman run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --env-file "$HERMES_DIR/.env" \
    -e API_SERVER_ENABLED=true \
    -e API_SERVER_HOST=0.0.0.0 \
    -e API_SERVER_PORT=8081 \
    -e API_SERVER_KEY="$API_KEY" \
    -e HERMES_DASHBOARD=1 \
    -e HERMES_DASHBOARD_TUI=1 \
    -e GATEWAY_ALLOW_ALL_USERS=true \
    -p 8081:8081 \
    -p 8082:8082 \
    -p 9119:9119 \
    -v /mnt/workspace/hermes:/opt/data:Z \
    "$IMAGE" gateway run

sleep 5

# --- Pre-build TUI to avoid blocking the event loop on first WebSocket ---
echo ""
echo "=== Pre-building TUI ==="
podman exec "$CONTAINER_NAME" bash -c "cd /opt/hermes/ui-tui && npm run build --prefix packages/hermes-ink 2>&1 | tail -1 && npm run build 2>&1 | tail -1"
podman exec "$CONTAINER_NAME" touch /opt/hermes/ui-tui/packages/hermes-ink/dist/ink-bundle.js /opt/hermes/ui-tui/dist/entry.js
echo "TUI pre-built successfully."

# --- Fix auth.json permissions ---
if [ -f "$HERMES_DIR/auth.json" ]; then
    echo ""
    echo "=== Fixing auth.json permissions ==="
    sudo chmod 666 "$HERMES_DIR/auth.json"
fi

# --- Patch CORS to allow external domain via Cloudflare Tunnel ---
echo ""
echo "=== Patching CORS for hermes.dirkweibel.dev ==="
podman exec "$CONTAINER_NAME" sed -i \
    's|allow_origin_regex=r"^https?://(localhost\|127\\.0\\.0\\.1)(:\\d+)?$"|allow_origin_regex=r"^https?://(localhost\|127\\.0\\.0\\.1\|hermes\\.dirkweibel\\.dev)(:\\d+)?$"|' \
    /opt/hermes/hermes_cli/web_server.py
echo "CORS patched."

# --- Restart to pick up CORS patch ---
echo ""
echo "=== Restarting to apply CORS patch ==="
podman restart "$CONTAINER_NAME"
sleep 5

echo ""
echo "=== Container Status ==="
podman ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "=== Dashboard check ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:9119 2>/dev/null) || HTTP_CODE="000"
echo "Dashboard on port 9119: HTTP $HTTP_CODE"

echo ""
echo "=== API check ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8081/v1/models -H "Authorization: Bearer $API_KEY" 2>/dev/null) || HTTP_CODE="000"
echo "API on port 8081: HTTP $HTTP_CODE"

echo ""
echo "=== TUI Chat check ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:9119/chat 2>/dev/null) || HTTP_CODE="000"
if [ "$HTTP_CODE" = "200" ]; then
    echo "Chat on port 9119/chat: HTTP $HTTP_CODE (OK)"
else
    echo "Chat on port 9119/chat: HTTP $HTTP_CODE (expected 200 — TUI may not be enabled)"
fi
