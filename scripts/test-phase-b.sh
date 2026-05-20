#!/bin/bash
set -euo pipefail

# Phase B validation smoke tests.
# Verifies that all Phase B components are operational:
#   - Port 8082 is reachable externally
#   - Webhook gateway authenticates correctly
#   - Forge is reachable from Hermes (localhost:3100)
#
# Usage:
#   ./scripts/test-phase-b.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/test-phase-b.sh  # run remotely
#
# Prerequisites:
#   - Hermes container running with webhook gateway enabled (port 8082)
#   - Port 8082 open in VCN security list and instance firewall
#   - /mnt/workspace/hermes/.env contains WEBHOOK_PASSPHRASE
#   - Forge container running on localhost:3100
#
# Environment variables (override defaults):
#   OCI_SERVER_IP       - Instance public IP (for external port test)
#   WEBHOOK_PASSPHRASE  - Passphrase for webhook auth

HERMES_DIR="/mnt/workspace/hermes"
TIMEOUT=15

PASS=0
FAIL=0
SKIP=0

echo "=== Phase B Validation Smoke Tests ==="
echo ""

# --- Load secrets ---

if [ -z "${WEBHOOK_PASSPHRASE:-}" ]; then
    if [ -f "$HERMES_DIR/.env" ]; then
        WEBHOOK_PASSPHRASE=$(grep -E '^WEBHOOK_PASSPHRASE=' "$HERMES_DIR/.env" | cut -d'=' -f2-) || true
    fi
fi

if [ -z "${WEBHOOK_PASSPHRASE:-}" ]; then
    echo "WARNING: WEBHOOK_PASSPHRASE not found. Webhook auth tests will use a placeholder."
    WEBHOOK_PASSPHRASE="not-configured"
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
        echo "FAIL (connection failed — port closed or service down)"
        FAIL=$((FAIL + 1))
    else
        echo "FAIL (HTTP $actual, expected $expected)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Test 1: Webhook rejects invalid passphrase ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    -X POST "http://localhost:8082/webhooks/email" \
    -H "Content-Type: application/json" \
    -H "X-Webhook-Signature: invalid-signature" \
    -d '{"sender":"test@example.com","topic":"test","content":"hello","event_type":"email"}' \
    2>/dev/null) || HTTP_CODE="000"

run_test 1 "Webhook rejects invalid signature" "401" "$HTTP_CODE"

# --- Test 2: Webhook accepts valid HMAC signature ---

BODY='{"sender":"test@example.com","topic":"Phase B test","content":"This is a validation test.","event_type":"email"}'
SIGNATURE=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$WEBHOOK_PASSPHRASE" | awk '{print $NF}')

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    -X POST "http://localhost:8082/webhooks/email" \
    -H "Content-Type: application/json" \
    -H "X-Webhook-Signature: $SIGNATURE" \
    -d "$BODY" \
    2>/dev/null) || HTTP_CODE="000"

run_test 2 "Webhook accepts valid HMAC signature" "202" "$HTTP_CODE"

# --- Test 3: Webhook rejects missing signature ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    -X POST "http://localhost:8082/webhooks/email" \
    -H "Content-Type: application/json" \
    -d '{"sender":"test@example.com","topic":"test","content":"hello","event_type":"email"}' \
    2>/dev/null) || HTTP_CODE="000"

run_test 3 "Webhook rejects missing signature" "401" "$HTTP_CODE"

# --- Test 4: Forge health check (localhost:3100) ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
    "http://localhost:3100/health" 2>/dev/null) || HTTP_CODE="000"

run_test 4 "Forge reachable on localhost:3100" "200" "$HTTP_CODE"

# --- Test 5: Port 8082 reachable externally ---

echo -n "Test 5: Port 8082 reachable from external IP... "

OCI_IP="${OCI_SERVER_IP:-}"
if [ -z "$OCI_IP" ]; then
    # Try to get our own public IP to test externally
    OCI_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null) || true
fi

if [ -z "$OCI_IP" ]; then
    echo "SKIP (OCI_SERVER_IP not set and couldn't determine public IP)"
    SKIP=$((SKIP + 1))
else
    EXT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
        -X POST "http://${OCI_IP}:8082/webhooks/email" \
        -H "Content-Type: application/json" \
        -H "X-Webhook-Signature: invalid" \
        -d '{"sender":"test@example.com","topic":"test","content":"external test","event_type":"email"}' \
        2>/dev/null) || EXT_CODE="000"

    if [ "$EXT_CODE" = "401" ] || [ "$EXT_CODE" = "403" ]; then
        echo "PASS (port reachable, auth rejected as expected: HTTP $EXT_CODE)"
        PASS=$((PASS + 1))
    elif [ "$EXT_CODE" = "000" ]; then
        echo "FAIL (port not reachable — check VCN security list and firewall)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS (port reachable: HTTP $EXT_CODE)"
        PASS=$((PASS + 1))
    fi
fi

# --- Summary ---

echo ""
echo "=== Results ==="
echo "Passed:  $PASS"
echo "Failed:  $FAIL"
echo "Skipped: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "PHASE B VALIDATION FAILED"
    echo ""
    echo "Troubleshooting:"
    echo "  - Webhook 000: container not listening on 8082 (check config.yaml webhook_gateway)"
    echo "  - Webhook unexpected code: check WEBHOOK_PASSPHRASE matches .env"
    echo "  - Forge 000: Forge container not running (podman ps | grep forge)"
    echo "  - External port fail: check VCN security list + iptables rules"
    exit 1
else
    echo "PHASE B VALIDATION PASSED"
    if [ "$SKIP" -gt 0 ]; then
        echo "(Some tests skipped — set OCI_SERVER_IP for full external coverage)"
    fi
fi
