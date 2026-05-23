#!/usr/bin/env bash
# Verify: HITL approval plumbing works end-to-end.
#
# HITL queue is an Enterprise feature — this test requires an Enterprise stack.
# On community stacks, exits 1. The release workflow conditionally runs this
# test only when AXONFLOW_STACK_TIER=enterprise.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack

echo "=== sync-completion-hitl-approve ==="

# Verify HITL is enabled — fail hard if not
HITL_STATUS=$(curl -sf "${AXONFLOW_ENDPOINT}/api/v1/hitl/status" 2>/dev/null || echo "")
HITL_ENABLED=$(echo "$HITL_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('enabled',False))" 2>/dev/null || echo "false")

if [ "$HITL_ENABLED" != "True" ] && [ "$HITL_ENABLED" != "true" ]; then
  echo "FAIL: HITL is disabled on this stack (community mode)"
  echo "  HITL status: $HITL_STATUS"
  echo "  This test requires an Enterprise stack with HITL enabled."
  echo "  Run with AXONFLOW_STACK_TIER=enterprise or skip this test in the workflow."
  exit 1
fi

require_psql

MARKER="e2e-hitl-$(date +%s)-$RANDOM"

# Step 1: Create HITL request via API
echo "Creating HITL request..."
CREATE_RESPONSE=$(curl -sf -X POST "${AXONFLOW_ENDPOINT}/api/v1/hitl/queue" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n "${AXONFLOW_CLIENT_ID}:${AXONFLOW_CLIENT_SECRET}" | base64)" \
  -d "{
    \"client_id\": \"${AXONFLOW_CLIENT_ID}\",
    \"original_query\": \"HITL E2E test: ${MARKER}\",
    \"request_type\": \"litellm-completion\",
    \"triggered_policy_id\": \"e2e-test-policy\",
    \"triggered_policy_name\": \"E2E Test Policy\",
    \"trigger_reason\": \"require_approval\",
    \"severity\": \"high\"
  }")

if [ -z "$CREATE_RESPONSE" ]; then
  echo "FAIL: HITL queue create returned empty response"
  exit 1
fi

echo "Create response: $CREATE_RESPONSE"
REQUEST_ID=$(echo "$CREATE_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
inner = data.get('data', data)
print(inner.get('request_id', ''))
" 2>/dev/null || echo "")

if [ -z "$REQUEST_ID" ]; then
  echo "FAIL: could not extract request_id from HITL create response"
  exit 1
fi

# Step 2: Verify pending status in DB
INITIAL_STATUS=$(run_psql -c "SELECT status FROM hitl_approval_queue WHERE request_id = '${REQUEST_ID}'")
echo "Initial DB status: $INITIAL_STATUS"

if [ "$INITIAL_STATUS" != "pending" ]; then
  echo "FAIL: expected initial status=pending, got '$INITIAL_STATUS'"
  exit 1
fi

# Step 3: Approve
echo "Approving HITL request..."
approve_hitl_request "$REQUEST_ID"

# Step 4: Verify approved status in DB
sleep 1
FINAL_STATUS=$(run_psql -c "SELECT status FROM hitl_approval_queue WHERE request_id = '${REQUEST_ID}'")
echo "Final DB status: $FINAL_STATUS"

if [ "$FINAL_STATUS" != "approved" ]; then
  echo "FAIL: expected final status=approved, got '$FINAL_STATUS'"
  exit 1
fi

echo "PASS: sync-completion-hitl-approve — HITL create→approve cycle verified in DB"
