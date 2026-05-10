#!/bin/bash
set -euo pipefail

# Phase A validation smoke tests.
# Verifies that all Phase A components are operational:
#   - Cloudflare Tunnel routes resolve for Onyx Lite and Hermes API
#   - Hermes API authenticates correctly via tunnel
#   - Podman bridge connectivity from Onyx container to Hermes
#
# Usage:
#   ./scripts/test-phase-a.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/test-phase-a.sh  # run remotely
#
# Prerequisites:
#   - Hermes container running (port 8081)
#   - Onyx Lite running (port 3080)
#   - Cloudflare Tunnel routes configured
#   - /mnt/workspace/hermes/.env contains HERMES_API_KEY
#
# Environment variables (override defaults):
#   HERMES_DOMAIN   - Base domain (default: yourdomain.com)
#   HERMES_API_KEY  - API key (default: read from .env file)

DOMAIN="${HERMES_DOMAIN:-yourdomain.com}"
CHAT_URL="https://hermes.${DOMAIN}"
API_URL="https://hermes-api.${DOMAIN}"
ENV_FILE="/mnt/workspace/hermes/.env"
ONYX_CONTAINER="${ONYX_CONTAINER:-onyx-lite-web-server-1}"
PODMAN_BRIDGE_IP="10.88.0.1"
TIMEOUT=15

PASS=0
FAIL=0
SKIP=0

echo "=== Phase A Validation Smoke Tests ==="
echo "Chat URL: $CHAT_URL"
echo "API URL:  $API_URL"
echo ""

# --- Load API key ---

if [ -z "${HERMES_API_KEY:-}" ]; then
    if [ -f "$ENV_FILE" ]; then
        HERMES_API_KEY=$(grep -E '^HERMES_API_KEY=' "$ENV_FILE" | cut -d'=' -f2-) || true
    fi
fi

if [ -z "${HERMES_API_KEY:-}" ]; then
    echo "WARNING: HERMES_API_KEY not found. Set it or populate $ENV_FILE."
    echo "Tests requiring authentication will use a placeholder."
    HERMES_API_KEY="not-configured"
fi

# --- Helper ---

run_test() {
    local test_num="$1"
    local description="$2"
    local expected="$3"
    local actual="$4"

    echo -n "Test $test_num: $description... "
    if [ "$actual" = "$expected" ]; then
        echo "PASS (HTTP $actual)"
        PASS=$((PASS + 1))
    elif [ "$actual" = "000" ]; then
        echo "FAIL (connection failed — DNS not resolving or service down)"
        FAIL=$((FAIL + 1))
    else
        echo "FAIL (HTTP $actual, expected $expected)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Test 1: Tunnel route resolves for dashboard (hermes) ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    "$CHAT_URL" 2>/dev/null) || HTTP_CODE="000"

run_test 1 "Tunnel route resolves for Onyx Lite ($CHAT_URL)" "200" "$HTTP_CODE"

# --- Test 2: Hermes API responds via tunnel with valid key ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    "$API_URL/v1/models" \
    -H "Authorization: Bearer $HERMES_API_KEY" 2>/dev/null) || HTTP_CODE="000"

run_test 2 "Hermes API responds via tunnel with valid key" "200" "$HTTP_CODE"

# --- Test 3: Hermes API rejects invalid key via tunnel ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    "$API_URL/v1/models" \
    -H "Authorization: Bearer invalid-key-12345" 2>/dev/null) || HTTP_CODE="000"

run_test 3 "Hermes API rejects invalid key via tunnel" "401" "$HTTP_CODE"

# --- Test 4: Hermes API rejects missing key via tunnel ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    "$API_URL/v1/models" 2>/dev/null) || HTTP_CODE="000"

run_test 4 "Hermes API rejects missing key via tunnel" "401" "$HTTP_CODE"

# --- Test 5: Podman bridge connectivity from Onyx container to Hermes ---

echo -n "Test 5: Podman bridge connectivity (Onyx → Hermes via $PODMAN_BRIDGE_IP:8081)... "

if ! command -v podman &>/dev/null; then
    echo "SKIP (podman not available — run this test on the OCI instance)"
    SKIP=$((SKIP + 1))
elif ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q "$ONYX_CONTAINER"; then
    echo "SKIP (container '$ONYX_CONTAINER' not running)"
    SKIP=$((SKIP + 1))
else
    BRIDGE_CODE=$(podman exec "$ONYX_CONTAINER" \
        curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://${PODMAN_BRIDGE_IP}:8081/v1/models" \
        -H "Authorization: Bearer $HERMES_API_KEY" 2>/dev/null) || BRIDGE_CODE="000"

    if [ "$BRIDGE_CODE" = "200" ]; then
        echo "PASS (HTTP $BRIDGE_CODE)"
        PASS=$((PASS + 1))
    elif [ "$BRIDGE_CODE" = "000" ]; then
        echo "FAIL (connection refused — check Podman bridge network)"
        FAIL=$((FAIL + 1))
    else
        echo "FAIL (HTTP $BRIDGE_CODE, expected 200)"
        FAIL=$((FAIL + 1))
    fi
fi

# --- Test 6: Local Onyx Lite responds on port 3080 ---

echo -n "Test 6: Onyx Lite responds locally on port 3080... "

LOCAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "http://localhost:3080" 2>/dev/null) || LOCAL_CODE="000"

if [ "$LOCAL_CODE" = "200" ]; then
    echo "PASS (HTTP $LOCAL_CODE)"
    PASS=$((PASS + 1))
elif [ "$LOCAL_CODE" = "000" ]; then
    echo "SKIP (not running locally — run this test on the OCI instance)"
    SKIP=$((SKIP + 1))
else
    echo "FAIL (HTTP $LOCAL_CODE, expected 200)"
    FAIL=$((FAIL + 1))
fi

# --- Summary ---

echo ""
echo "=== Results ==="
echo "Passed:  $PASS"
echo "Failed:  $FAIL"
echo "Skipped: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "PHASE A VALIDATION FAILED"
    echo ""
    echo "Troubleshooting:"
    echo "  - DNS not resolving: wait for propagation or check CNAME records"
    echo "  - 502 Bad Gateway: verify containers are running (podman ps)"
    echo "  - Connection refused: check cloudflared status (systemctl status cloudflared)"
    echo "  - Auth errors: verify API key matches between .env files"
    echo "  - Bridge failure: verify Podman default bridge (ip addr show podman0)"
    exit 1
else
    echo "PHASE A VALIDATION PASSED"
    if [ "$SKIP" -gt 0 ]; then
        echo "(Some tests skipped — re-run on the OCI instance for full coverage)"
    fi
fi
