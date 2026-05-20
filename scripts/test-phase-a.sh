#!/bin/bash
set -euo pipefail

# Phase A validation smoke tests.
# Verifies that all Phase A components are operational:
#   - Cloudflare Tunnel routes resolve for Hermes dashboard and API
#   - Hermes API authenticates correctly via tunnel
#
# Usage:
#   ./scripts/test-phase-a.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/test-phase-a.sh  # run remotely
#
# Prerequisites:
#   - Hermes container running (port 8081)
#   - Cloudflare Tunnel routes configured
#   - /mnt/workspace/hermes/.env contains HERMES_API_KEY
#
# Environment variables (override defaults):
#   HERMES_DOMAIN   - Base domain (default: dirkweibel.dev)
#   HERMES_API_KEY  - API key (default: read from .env file)

DOMAIN="${HERMES_DOMAIN:-dirkweibel.dev}"
DASHBOARD_URL="https://hermes.${DOMAIN}"
API_URL="https://hermes-api.${DOMAIN}"
ENV_FILE="/mnt/workspace/hermes/.env"
TIMEOUT=15

PASS=0
FAIL=0

echo "=== Phase A Validation Smoke Tests ==="
echo "Dashboard URL: $DASHBOARD_URL"
echo "API URL:       $API_URL"
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

# --- Test 1: Tunnel route resolves for Hermes dashboard ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    "$DASHBOARD_URL" 2>/dev/null) || HTTP_CODE="000"

run_test 1 "Tunnel route resolves for Hermes dashboard ($DASHBOARD_URL)" "200" "$HTTP_CODE"

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

# --- Summary ---

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "PHASE A VALIDATION FAILED"
    echo ""
    echo "Troubleshooting:"
    echo "  - DNS not resolving: wait for propagation or check CNAME records"
    echo "  - 502 Bad Gateway: verify containers are running (podman ps)"
    echo "  - Connection refused: check cloudflared status (systemctl status cloudflared)"
    echo "  - Auth errors: verify API key matches between .env files"
    exit 1
else
    echo "PHASE A VALIDATION PASSED"
fi
