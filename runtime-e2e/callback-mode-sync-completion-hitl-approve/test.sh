#!/usr/bin/env bash
# Verify: HITL create→approve→resume cycle via logger.completion().
#
# Setup: create require_approval policy via API; start background approver.
# Call: logger.completion() triggers require_approval → HITL flow → approved.
# Assert: completion returns with LLM response; HITL row status=approved in DB.
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
echo "Created require_approval policy: $POLICY_ID"
cleanup() { delete_policy "$POLICY_ID"; echo "Cleaned up policy $POLICY_ID"; }
trap cleanup EXIT

OUTPUT=$(mktemp -t hitl-approve-e2e.XXXXXX)

# Background approver: polls HITL queue and approves any pending request
python3 -u - > /dev/null 2>&1 <<PYEOF &
import time
import os
import requests

endpoint = os.environ["AXONFLOW_ENDPOINT"]
auth = os.environ["AXONFLOW_AUTH"]

for _ in range(60):
    time.sleep(1)
    try:
        resp = requests.get(
            f"{endpoint}/api/v1/hitl/queue?status=pending&limit=10",
            headers={"Authorization": f"Basic {auth}"},
            timeout=5,
        )
        if resp.status_code == 200:
            data = resp.json()
            items = data.get("data", data.get("items", []))
            if isinstance(items, list):
                for item in items:
                    if item.get("status") == "pending":
                        req_id = item["request_id"]
                        requests.post(
                            f"{endpoint}/api/v1/hitl/queue/{req_id}/approve",
                            headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"},
                            json={"reviewer_id": "e2e-approver", "comments": "auto-approved"},
                            timeout=5,
                        )
                        print(f"Approved {req_id}")
                        exit(0)
    except Exception:
        pass
PYEOF
APPROVER_PID=$!

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<PYEOF
import sys
import os
from axonflow_litellm import (
    AxonFlowLogger, AxonFlowLoggerConfig,
    ApprovalRejected, ApprovalTimeout, PolicyDeniedError,
)

marker = sys.argv[1]

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
    approval_poll_interval_seconds=1.0,
    approval_max_wait_seconds=60.0,
))

try:
    response = logger.completion(
        model=os.environ.get("LLM_MODEL", "ollama/llama3.2:1b"),
        messages=[{"role": "user", "content": f"Process: {marker}"}],
        max_tokens=10,
    )
    print(f"LLM response: {response.choices[0].message.content[:50]}")
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

wait "$APPROVER_PID" 2>/dev/null || true
cat "$OUTPUT"

if ! grep -q "HITL_RESULT=approved" "$OUTPUT"; then
  echo "FAIL: HITL flow did not complete with approval"
  rm -f "$OUTPUT"
  exit 1
fi

# Verify HITL row in DB
HITL_COUNT=$(run_psql -c "SELECT count(*) FROM hitl_approval_queue WHERE status = 'approved' AND trigger_reason = 'require_approval' AND created_at > NOW() - INTERVAL '5 minutes'")
echo "Recent approved HITL rows: $HITL_COUNT"

if [ "$HITL_COUNT" -lt 1 ]; then
  echo "FAIL: no approved HITL row found in DB"
  rm -f "$OUTPUT"
  exit 1
fi

rm -f "$OUTPUT"
echo "PASS: callback-mode-sync-completion-hitl-approve — create→approve→resume verified"
