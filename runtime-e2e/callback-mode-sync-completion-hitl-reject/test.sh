#!/usr/bin/env bash
# Verify: HITL rejection raises ApprovalRejected via logger.completion().
# Requires eval-tier stack with HITL enabled.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_hitl

echo "=== callback-mode-sync-completion-hitl-reject ==="

MARKER="e2e-hitl-reject-$(date +%s)-$RANDOM"

POLICY_RESPONSE=$(create_require_approval_policy "HITL reject test ${MARKER}" "(?i)${MARKER}")
POLICY_ID=$(echo "$POLICY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [ -z "$POLICY_ID" ]; then
  echo "FAIL: could not create require_approval policy"
  exit 1
fi
echo "Created policy: $POLICY_ID"

# Verify sentinel
SENTINEL_BR=$(axonflow_api POST "/api/policy/pre-check" \
  -d "{\"user_token\":\"${AXONFLOW_USER_TOKEN}\",\"query\":\"${MARKER}\",\"client_id\":\"${AXONFLOW_CLIENT_ID}\",\"context\":{}}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('block_reason',''))" 2>/dev/null || echo "")
if [ "$SENTINEL_BR" != "require_approval" ]; then
  echo "FAIL: sentinel not set — got '$SENTINEL_BR'. Platform fix needed."
  delete_policy "$POLICY_ID"
  exit 1
fi

cleanup() { delete_policy "$POLICY_ID"; echo "Cleaned up"; }
trap cleanup EXIT

OUTPUT=$(mktemp -t hitl-reject-e2e.XXXXXX)

# Background rejector
python3 -u - > /dev/null 2>&1 <<PYEOF &
import time, os, requests
endpoint = os.environ["AXONFLOW_ENDPOINT"]
auth = os.environ["AXONFLOW_AUTH"]
for _ in range(60):
    time.sleep(1)
    try:
        resp = requests.get(f"{endpoint}/api/v1/hitl/queue?status=pending&limit=10",
            headers={"Authorization": f"Basic {auth}"}, timeout=5)
        if resp.status_code == 200:
            items = resp.json().get("data", resp.json().get("items", []))
            if isinstance(items, list):
                for item in items:
                    if item.get("status") == "pending":
                        req_id = item["request_id"]
                        requests.post(f"{endpoint}/api/v1/hitl/queue/{req_id}/reject",
                            headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"},
                            json={"reviewer_id": "e2e-rejector", "comments": "rejected by test"}, timeout=5)
                        exit(0)
    except Exception:
        pass
PYEOF
REJECTOR_PID=$!

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<PYEOF
import sys, os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig, ApprovalRejected, ApprovalTimeout

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
    approval_poll_interval_seconds=1.0,
    approval_max_wait_seconds=60.0,
))

try:
    logger.completion(model=os.environ.get("LLM_MODEL", "ollama/llama3.2:1b"),
        messages=[{"role": "user", "content": f"Process: {sys.argv[1]}"}], max_tokens=10)
    print("HITL_RESULT=allowed")
    sys.exit(1)
except ApprovalRejected as e:
    print(f"ApprovalRejected: {e.reason}")
    print("HITL_RESULT=rejected")
except ApprovalTimeout as e:
    print(f"ApprovalTimeout: {e.reason}")
    print("HITL_RESULT=timeout")
    sys.exit(1)
except Exception as e:
    print(f"Unexpected: {type(e).__name__}: {e}")
    print("HITL_RESULT=error")
    sys.exit(1)
PYEOF

wait "$REJECTOR_PID" 2>/dev/null || true
cat "$OUTPUT"

if ! grep -q "HITL_RESULT=rejected" "$OUTPUT"; then
  echo "FAIL: expected ApprovalRejected"
  rm -f "$OUTPUT"
  exit 1
fi

rm -f "$OUTPUT"
echo "PASS: callback-mode-sync-completion-hitl-reject — ApprovalRejected raised"
