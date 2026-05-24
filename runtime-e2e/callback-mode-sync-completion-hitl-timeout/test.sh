#!/usr/bin/env bash
# Verify: HITL timeout raises ApprovalTimeout when nobody approves/rejects.
# Requires eval-tier stack with HITL enabled.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_hitl

echo "=== callback-mode-sync-completion-hitl-timeout ==="

MARKER="e2e-hitl-timeout-$(date +%s)-$RANDOM"

POLICY_RESPONSE=$(create_require_approval_policy "HITL timeout test ${MARKER}" "(?i)${MARKER}")
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

OUTPUT=$(mktemp -t hitl-timeout-e2e.XXXXXX)

# NO background approver — intentional timeout
python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<PYEOF
import sys, os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig, ApprovalRejected, ApprovalTimeout

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
    approval_poll_interval_seconds=0.5,
    approval_max_wait_seconds=3.0,
))

try:
    logger.completion(model=os.environ.get("LLM_MODEL", "ollama/llama3.2:1b"),
        messages=[{"role": "user", "content": f"Process: {sys.argv[1]}"}], max_tokens=10)
    print("HITL_RESULT=allowed")
    sys.exit(1)
except ApprovalTimeout as e:
    print(f"ApprovalTimeout: {e.reason}")
    print("HITL_RESULT=timeout")
except ApprovalRejected as e:
    print(f"ApprovalRejected: {e.reason}")
    print("HITL_RESULT=rejected")
    sys.exit(1)
except Exception as e:
    print(f"Unexpected: {type(e).__name__}: {e}")
    print("HITL_RESULT=error")
    sys.exit(1)
PYEOF

cat "$OUTPUT"

if ! grep -q "HITL_RESULT=timeout" "$OUTPUT"; then
  echo "FAIL: expected ApprovalTimeout"
  rm -f "$OUTPUT"
  exit 1
fi

rm -f "$OUTPUT"
echo "PASS: callback-mode-sync-completion-hitl-timeout — ApprovalTimeout raised after 3s"
