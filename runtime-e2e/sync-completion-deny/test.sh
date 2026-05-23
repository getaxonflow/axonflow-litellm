#!/usr/bin/env bash
# Verify: when AxonFlow policy denies a request, logger.completion() (sync)
# raises PolicyDeniedError to the caller.
#
# Setup: creates a deny policy via API that blocks the test marker pattern.
# Assertion: PolicyDeniedError is raised with the correct class name.
# Cleanup: deletes the policy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack

echo "=== sync-completion-deny ==="

MARKER="e2e-deny-$(date +%s)-$RANDOM"

# Setup: create a deny policy matching our marker
POLICY_RESPONSE=$(create_deny_policy "E2E deny test ${MARKER}" "(?i)${MARKER}")
POLICY_ID=$(echo "$POLICY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [ -z "$POLICY_ID" ]; then
  echo "FAIL: could not create deny policy — response: $POLICY_RESPONSE"
  exit 1
fi
echo "Created deny policy: $POLICY_ID"

cleanup() {
  delete_policy "$POLICY_ID"
  echo "Cleaned up policy $POLICY_ID"
}
trap cleanup EXIT

OUTPUT=$(mktemp -t deny-e2e.XXXXXX)

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<'PYEOF'
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig, PolicyDeniedError

marker = sys.argv[1]

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
))

try:
    response = logger.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": f"Process this: {marker}"}],
        max_tokens=20,
    )
    print("DENY_RESULT=allowed")
    sys.exit(1)
except PolicyDeniedError as e:
    print(f"PolicyDeniedError raised: {e.reason}")
    print(f"Policies: {e.policies}")
    print("DENY_RESULT=denied")
except Exception as e:
    print(f"Wrong exception type: {type(e).__name__}: {e}")
    print("DENY_RESULT=wrong_exception")
    sys.exit(1)
PYEOF

cat "$OUTPUT"

if ! grep -q "DENY_RESULT=denied" "$OUTPUT"; then
  echo "FAIL: expected PolicyDeniedError but got different result"
  exit 1
fi

echo "PASS: sync-completion-deny — PolicyDeniedError raised against real deny policy"
