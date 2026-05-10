#!/bin/bash
set -euo pipefail

# Post-deployment fixups for the Hermes container.
# Run after deploy-hermes.sh or enable-dashboard.sh to apply fixes that
# cannot be baked into the container image.
#
# Usage:
#   ./scripts/post-deploy-fixups.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/post-deploy-fixups.sh  # run remotely
#
# What this fixes:
#   1. auth.json permissions — file may be root-owned from prior runs
#   2. CORS origin — allows hermes.dirkweibel.dev (image only allows localhost)
#   3. TUI pre-build — prevents 15s blocking build on first WebSocket connection

CONTAINER_NAME="${1:-hermes-agent}"
HERMES_DIR="/mnt/workspace/hermes"
DOMAIN="hermes.dirkweibel.dev"

echo "=== Post-Deploy Fixups for ${CONTAINER_NAME} ==="

# --- 1. Fix auth.json permissions ---
# The hermes user (UID 10000) inside the container needs read/write access.
# If auth.json was created by a prior root-owned process, it becomes inaccessible.

if [ -f "$HERMES_DIR/auth.json" ]; then
    echo "[1/3] Fixing auth.json permissions..."
    sudo chmod 666 "$HERMES_DIR/auth.json"
    echo "      Done."
else
    echo "[1/3] auth.json does not exist yet — skipping."
fi

# --- 2. Patch CORS to allow the external domain ---
# The dashboard's CORS middleware only allows localhost origins by default.
# When accessed via Cloudflare Tunnel (hermes.dirkweibel.dev), browser API
# calls are blocked. This patches the regex to include our domain.
#
# This patch lives in the container's writable layer and is lost on
# `podman rm`. It must be re-applied after every container recreation.

echo "[2/3] Patching CORS allow_origin_regex to include ${DOMAIN}..."
podman exec "$CONTAINER_NAME" sed -i \
    "s|allow_origin_regex=r\"^https?://(localhost\|127\\\\\.0\\\\\.0\\\\\.1)(:\\\\d+)?\$\"|allow_origin_regex=r\"^https?://(localhost\|127\\\\.0\\\\.0\\\\.1\|hermes\\\\.dirkweibel\\\\.dev)(:\\\\d+)?\$\"|" \
    /opt/hermes/hermes_cli/web_server.py

# Verify the patch took effect
if podman exec "$CONTAINER_NAME" grep -q "hermes\\\\.dirkweibel\\\\.dev" /opt/hermes/hermes_cli/web_server.py; then
    echo "      Done."
else
    echo "      WARNING: CORS patch may not have applied correctly."
    echo "      Check: podman exec $CONTAINER_NAME sed -n '92p' /opt/hermes/hermes_cli/web_server.py"
fi

# --- 3. Pre-build TUI (hermes-ink bundle + entry.js) ---
# The TUI staleness check compares source timestamps against dist/entry.js.
# If packages/hermes-ink/dist/ink-bundle.js is missing, every WebSocket
# connection triggers a 15-second npm build that blocks the event loop,
# causing cloudflared to time out with EOF (502 to the browser).

echo "[3/3] Pre-building TUI (hermes-ink + entry.js)..."
podman exec "$CONTAINER_NAME" bash -c \
    "cd /opt/hermes/ui-tui && npm run build --prefix packages/hermes-ink 2>&1 | tail -1 && npm run build 2>&1 | tail -1"
podman exec "$CONTAINER_NAME" touch \
    /opt/hermes/ui-tui/packages/hermes-ink/dist/ink-bundle.js \
    /opt/hermes/ui-tui/dist/entry.js
echo "      Done."

# --- Restart to pick up CORS patch ---
echo ""
echo "Restarting ${CONTAINER_NAME} to apply CORS patch..."
podman restart "$CONTAINER_NAME"
sleep 5

# --- Verify ---
echo ""
echo "=== Verification ==="
HTTP_DASH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:9119/chat 2>/dev/null) || HTTP_DASH="000"
HTTP_API=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8081/v1/models -H "Authorization: Bearer $(grep '^HERMES_API_KEY=' "$HERMES_DIR/.env" | cut -d'=' -f2-)" 2>/dev/null) || HTTP_API="000"

echo "Dashboard /chat: HTTP $HTTP_DASH (expect 200)"
echo "API /v1/models:  HTTP $HTTP_API (expect 200)"

if [ "$HTTP_DASH" = "200" ] && [ "$HTTP_API" = "200" ]; then
    echo ""
    echo "SUCCESS: All fixups applied. Chat should work at https://${DOMAIN}/chat"
else
    echo ""
    echo "WARNING: One or more checks failed. Review logs:"
    echo "  podman logs --tail 20 $CONTAINER_NAME"
    echo "  journalctl -u cloudflared -n 10"
fi
