#!/usr/bin/env bash
# Verify: HITL approval flow works end-to-end via logger.completion() (sync).
#
# Setup: creates a require_approval policy matching the test marker.
# Flow: completion blocks on HITL, background thread auto-approves via API,
#       completion resumes with LLM response.
# Assertion: HITL row exists in DB with status=approved, completion returns.
# Cleanup: deletes the policy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== sync-completion-hitl-approve ==="

MARKER="e2e-hitl-$(date +%s)-$RANDOM"

# Setup: create a require_approval policy matching our marker
POLICY_RESPONSE=$(create_require_approval_policy "E2E HITL test ${MARKER}" "(?i)${MARKER}")
POLICY_ID=$(echo "$POLICY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [ -z "$POLICY_ID" ]; then
  echo "FAIL: could not create require_approval policy — response: $POLICY_RESPONSE"
  exit 1
fi
echo "Created require_approval policy: $POLICY_ID"

cleanup() {
  delete_policy "$POLICY_ID"
  echo "Cleaned up policy $POLICY_ID"
}
trap cleanup EXIT

OUTPUT=$(mktemp -t hitl-e2e.XXXXXX)

# Run the completion in background — it will block on HITL polling
python3 -u - "$MARKER" "$AXONFLOW_ENDPOINT" "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" > "$OUTPUT" 2>&1 <<'PYEOF' &
import sys
import os
from axonflow_litellm import (
    AxonFlowLogger, AxonFlowLoggerConfig,
    ApprovalRejected, ApprovalTimeout, PolicyDeniedError,
)

marker = sys.argv[1]
endpoint = sys.argv[2]
client_id = sys.argv[3]
client_secret = sys.argv[4]

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=endpoint,
    client_id=client_id,
    client_secret=client_secret,
    approval_poll_interval_seconds=1.0,
    approval_max_wait_seconds=60.0,
))

try:
    response = logger.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": f"Process: {marker}"}],
        max_tokens=20,
    )
    print(f"LLM response: {response.choices[0].message.content[:100]}")
    print("HITL_RESULT=approved")
except ApprovalTimeout as e:
    print(f"ApprovalTimeout: {e.reason}")
    print("HITL_RESULT=timeout")
    sys.exit(1)
except ApprovalRejected as e:
    print(f"ApprovalRejected: {e.reason}")
    print("HITL_RESULT=rejected")
    sys.exit(1)
except PolicyDeniedError as e:
    print(f"PolicyDeniedError: {e.reason}")
    print("HITL_RESULT=denied")
    sys.exit(1)
except Exception as e:
    print(f"Unexpected: {type(e).__name__}: {e}")
    print("HITL_RESULT=error")
    sys.exit(1)
PYEOF
PYTHON_PID=$!

# Wait for the HITL row to appear, then approve it
echo "Waiting for HITL row to appear..."
HITL_REQUEST_ID=""
for i in $(seq 1 30); do
  sleep 2
  QUEUE_RESPONSE=$(curl -sf "${AXONFLOW_ENDPOINT}/api/v1/hitl/queue?status=pending&limit=10" 2>/dev/null || echo "")
  if [ -n "$QUEUE_RESPONSE" ]; then
    HITL_REQUEST_ID=$(echo "$QUEUE_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('data', data.get('items', []))
if isinstance(items, list):
    for item in items:
        if item.get('status') == 'pending':
            print(item.get('request_id', ''))
            break
" 2>/dev/null || echo "")
    if [ -n "$HITL_REQUEST_ID" ]; then
      echo "Found pending HITL request: $HITL_REQUEST_ID"
      break
    fi
  fi
done

if [ -z "$HITL_REQUEST_ID" ]; then
  echo "FAIL: no pending HITL request appeared after 60s"
  kill "$PYTHON_PID" 2>/dev/null || true
  wait "$PYTHON_PID" 2>/dev/null || true
  cat "$OUTPUT"
  exit 1
fi

# Approve it
echo "Approving HITL request $HITL_REQUEST_ID..."
APPROVE_RESPONSE=$(approve_hitl_request "$HITL_REQUEST_ID")
echo "Approve response: $APPROVE_RESPONSE"

# Wait for the Python process to finish
wait "$PYTHON_PID"
PYTHON_EXIT=$?
cat "$OUTPUT"
rm -f "$OUTPUT"

if [ "$PYTHON_EXIT" -ne 0 ]; then
  echo "FAIL: Python completion process exited $PYTHON_EXIT"
  exit 1
fi

if ! grep -q "HITL_RESULT=approved" "$OUTPUT" 2>/dev/null; then
  # Double-check from the captured output before deletion
  echo "FAIL: expected HITL_RESULT=approved in output"
  exit 1
fi

# Verify DB state: HITL row should be approved
HITL_STATUS=$(run_psql -c "SELECT status FROM hitl_approval_queue WHERE request_id = '${HITL_REQUEST_ID}'" 2>/dev/null || echo "")
echo "HITL DB status: $HITL_STATUS"

if [ "$HITL_STATUS" != "approved" ]; then
  echo "FAIL: expected HITL status=approved in DB, got '$HITL_STATUS'"
  exit 1
fi

echo "PASS: sync-completion-hitl-approve — full create→approve→resume cycle verified"
echo "  HITL request_id: $HITL_REQUEST_ID"
echo "  DB status: approved"
