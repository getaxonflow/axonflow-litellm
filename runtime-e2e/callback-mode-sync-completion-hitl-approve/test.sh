#!/usr/bin/env bash
# Verify: HITL create→approve→resume cycle via logger.completion().
# Requires eval-tier stack with HITL enabled.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql
require_hitl

echo "=== callback-mode-sync-completion-hitl-approve ==="

MARKER="e2e-hitl-approve-$(date +%s)-$RANDOM"

POLICY_RESPONSE=$(create_require_approval_policy "HITL approve test ${MARKER}" "(?i)${MARKER}")
POLICY_ID=$(echo "$POLICY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [ -z "$POLICY_ID" ]; then
  echo "FAIL: could not create require_approval policy — response: $POLICY_RESPONSE"
  exit 1
fi
echo "Created policy: $POLICY_ID"

SENTINEL_BR=$(wait_for_policy_active "$MARKER" "require_approval")
if [ "$SENTINEL_BR" != "require_approval" ]; then
  echo "FAIL: pre_check did not return sentinel after 10s. Got: '$SENTINEL_BR'"
  delete_policy "$POLICY_ID"
  exit 1
fi
echo "Sentinel verified: block_reason=$SENTINEL_BR"

cleanup() { delete_policy "$POLICY_ID"; echo "Cleaned up policy $POLICY_ID"; }
trap cleanup EXIT

echo "DEBUG: starting background approver"
# Start background approver (separate Python file, not heredoc)
python3 "$SCRIPT_DIR/../_lib/hitl_approver.py" approve &
APPROVER_PID=$!
echo "DEBUG: approver PID=$APPROVER_PID"

# Run the governed completion — should block on HITL then resume after approval
OUTPUT=$(mktemp -t hitl-approve-e2e.XXXXXX)
echo "DEBUG: OUTPUT=$OUTPUT, python3=$(which python3)"
python3 -u -c "
import sys, os
from axonflow_litellm import (
    AxonFlowLogger, AxonFlowLoggerConfig,
    ApprovalRejected, ApprovalTimeout, PolicyDeniedError,
)

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ['AXONFLOW_ENDPOINT'],
    client_id=os.environ['AXONFLOW_CLIENT_ID'],
    client_secret=os.environ.get('AXONFLOW_CLIENT_SECRET', ''),
    default_user_token=os.environ.get('AXONFLOW_USER_TOKEN', 'anonymous'),
    approval_poll_interval_seconds=1.0,
    approval_max_wait_seconds=60.0,
))

try:
    response = logger.completion(
        model=os.environ.get('LLM_MODEL', 'ollama/llama3.2:1b'),
        messages=[{'role': 'user', 'content': 'Process: $MARKER'}],
        max_tokens=10,
    )
    print(f'LLM response: {response.choices[0].message.content[:50]}')
    print('HITL_RESULT=approved')
except ApprovalTimeout as e:
    print(f'ApprovalTimeout: {e.reason}')
    print('HITL_RESULT=timeout')
    sys.exit(1)
except ApprovalRejected as e:
    print(f'ApprovalRejected: {e.reason}')
    print('HITL_RESULT=rejected')
    sys.exit(1)
except PolicyDeniedError as e:
    print(f'PolicyDeniedError: {e.reason}')
    print('HITL_RESULT=denied')
    sys.exit(1)
except Exception as e:
    print(f'Unexpected: {type(e).__name__}: {e}')
    print('HITL_RESULT=error')
    sys.exit(1)
" > "$OUTPUT" 2>&1

wait "$APPROVER_PID" 2>/dev/null || true
cat "$OUTPUT"

if ! grep -q "HITL_RESULT=approved" "$OUTPUT"; then
  echo "FAIL: HITL flow did not complete with approval"
  rm -f "$OUTPUT"
  exit 1
fi

# Verify HITL row in DB
HITL_ROWS=$(run_psql -c "SELECT request_id, status FROM hitl_approval_queue WHERE status = 'approved' AND created_at > NOW() - INTERVAL '5 minutes' LIMIT 1")
echo "Recent approved HITL row: $HITL_ROWS"

if [ -z "$HITL_ROWS" ]; then
  echo "FAIL: no approved HITL row found in DB"
  rm -f "$OUTPUT"
  exit 1
fi

rm -f "$OUTPUT"
echo "PASS: callback-mode-sync-completion-hitl-approve — create→approve→resume verified"
echo "  HITL row: $HITL_ROWS"
