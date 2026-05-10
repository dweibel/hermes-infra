#!/bin/bash
set -euo pipefail

# Deploy Onyx Lite chat UI using plain podman commands (no compose required).
# Creates a pod with PostgreSQL, API server, and web server containers.
#
# Usage:
#   ssh oci-agent 'bash -s' < scripts/deploy-onyx-lite-manual.sh
#
# Prerequisites:
#   - Podman installed
#   - Hermes agent running on port 8081
#   - API key available in /mnt/workspace/hermes/.env

POD_NAME="onyx-lite"
HERMES_API_HOST="10.88.0.1"
HERMES_API_PORT="8081"
ONYX_PORT="3080"

# Read API key from Hermes .env
API_KEY=$(sudo grep "^HERMES_API_KEY=" /mnt/workspace/hermes/.env | cut -d'=' -f2-)
if [ -z "$API_KEY" ]; then
    echo "ERROR: Could not read HERMES_API_KEY from /mnt/workspace/hermes/.env"
    exit 1
fi

echo "=== Onyx Lite Deployment (Manual) ==="

# --- Pre-flight: check Hermes is reachable ---
echo "Checking Hermes API reachability..."
if ! curl -sf --connect-timeout 5 "http://${HERMES_API_HOST}:${HERMES_API_PORT}/v1/models" \
    -H "Authorization: Bearer $API_KEY" > /dev/null 2>&1; then
    echo "WARNING: Hermes API not reachable on bridge at ${HERMES_API_HOST}:${HERMES_API_PORT}"
    echo "Onyx containers may not be able to connect. Continuing anyway..."
fi

# --- Tear down existing pod ---
if podman pod exists "$POD_NAME" 2>/dev/null; then
    echo "Removing existing pod '$POD_NAME'..."
    podman pod rm -f "$POD_NAME" 2>/dev/null || true
fi

# --- Create pod with port mapping ---
echo "Creating pod '$POD_NAME' with port $ONYX_PORT..."
podman pod create --name "$POD_NAME" -p "${ONYX_PORT}:3000"

# --- PostgreSQL ---
echo "Starting PostgreSQL..."
podman run -d \
    --pod "$POD_NAME" \
    --name onyx-postgres \
    --restart unless-stopped \
    -e POSTGRES_USER=onyx \
    -e POSTGRES_PASSWORD=onyx \
    -e POSTGRES_DB=onyx \
    -v onyx-postgres-data:/var/lib/postgresql/data \
    docker.io/postgres:15-alpine

# Wait for postgres to be ready
echo "Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if podman exec onyx-postgres pg_isready -U onyx -d onyx > /dev/null 2>&1; then
        echo "PostgreSQL is ready."
        break
    fi
    sleep 1
done

# --- Onyx API Server ---
echo "Starting Onyx API server..."
podman run -d \
    --pod "$POD_NAME" \
    --name onyx-api-server \
    --restart unless-stopped \
    -e POSTGRES_HOST=localhost \
    -e POSTGRES_USER=onyx \
    -e POSTGRES_PASSWORD=onyx \
    -e POSTGRES_DB=onyx \
    -e GEN_AI_API_ENDPOINT="http://${HERMES_API_HOST}:${HERMES_API_PORT}/v1" \
    -e GEN_AI_API_KEY="$API_KEY" \
    -e GEN_AI_MODEL_VERSION=gpt-4o \
    -e DISABLE_VECTOR_DB=true \
    -e DISABLE_REDIS=true \
    -e CACHE_BACKEND=postgres \
    -e AUTH_BACKEND=postgres \
    -e FILE_STORE_BACKEND=postgres \
    -e LOG_LEVEL=info \
    docker.io/onyxdotapp/onyx-backend:latest

# --- Onyx Web Server ---
echo "Starting Onyx web server..."
podman run -d \
    --pod "$POD_NAME" \
    --name onyx-web-server \
    --restart unless-stopped \
    -e INTERNAL_URL=http://localhost:8080 \
    docker.io/onyxdotapp/onyx-web-server:latest

# --- Verify ---
echo "Waiting for services to start..."
sleep 10

echo ""
echo "=== Pod Status ==="
podman pod ps --filter "name=$POD_NAME"
echo ""
echo "=== Container Status ==="
podman ps --pod --filter "pod=$POD_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

# Check if web server responds
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:${ONYX_PORT}" 2>/dev/null) || HTTP_CODE="000"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "SUCCESS: Onyx Lite is running on port $ONYX_PORT (HTTP $HTTP_CODE)."
else
    echo "WARNING: Onyx Lite returned HTTP $HTTP_CODE on port $ONYX_PORT."
    echo "It may still be starting up. Check logs:"
    echo "  podman logs onyx-web-server"
    echo "  podman logs onyx-api-server"
fi
