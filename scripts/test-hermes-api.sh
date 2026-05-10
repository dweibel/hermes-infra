#!/bin/bash
set -euo pipefail

# Smoke test for the Hermes API server.
# Verifies the API responds on port 8081, authenticates correctly,
# and rejects invalid credentials.
#
# Usage:
#   ./scripts/test-hermes-api.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/test-hermes-api.sh  # run remotely
#
# Prerequisites:
#   - Hermes container running (see scripts/deploy-hermes.sh)
#   - /mnt/workspace/hermes/.env contains HERMES_API_KEY

HERMES_HOST="${HERMES_HOST:-localhost}"
HERMES_PORT="${HERMES_PORT:-8081}"
BASE_URL="http://${HERMES_HOST}:${HERMES_PORT}"
ENV_FILE="/mnt/workspace/hermes/.env"

PASS=0
FAIL=0

echo "=== Hermes API Smoke Tests ==="
echo "Target: $BASE_URL"
echo ""

# Load API key from .env
if [ -f "$ENV_FILE" ]; then
    API_KEY=$(grep -E '^HERMES_API_KEY=' "$ENV_FILE" | cut -d'=' -f2-)
fi

if [ -z "${API_KEY:-}" ]; then
    echo "ERROR: HERMES_API_KEY not found in $ENV_FILE"
    exit 1
fi

# --- Test 1: API responds on port 8081 ---

echo -n "Test 1: API responds on port $HERMES_PORT... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/models" \
    -H "Authorization: Bearer $API_KEY" 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ]; then
    echo "PASS (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
else
    echo "FAIL (HTTP $HTTP_CODE, expected 200)"
    FAIL=$((FAIL + 1))
fi

# --- Test 2: Valid API key returns 200 ---

echo -n "Test 2: Valid API key returns 200... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/models" \
    -H "Authorization: Bearer $API_KEY" 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ]; then
    echo "PASS (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
else
    echo "FAIL (HTTP $HTTP_CODE, expected 200)"
    FAIL=$((FAIL + 1))
fi

# --- Test 3: Invalid API key returns 401 ---

echo -n "Test 3: Invalid API key returns 401... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/models" \
    -H "Authorization: Bearer invalid-key-12345" 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "401" ]; then
    echo "PASS (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
else
    echo "FAIL (HTTP $HTTP_CODE, expected 401)"
    FAIL=$((FAIL + 1))
fi

# --- Test 4: Missing API key returns 401 ---

echo -n "Test 4: Missing API key returns 401... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/models" \
    2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "401" ]; then
    echo "PASS (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
else
    echo "FAIL (HTTP $HTTP_CODE, expected 401)"
    FAIL=$((FAIL + 1))
fi

# --- Summary ---

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "SMOKE TESTS FAILED"
    echo "Check container status: podman ps --filter name=hermes-agent"
    echo "Check container logs:   podman logs hermes-agent"
    exit 1
else
    echo "ALL SMOKE TESTS PASSED"
fi
