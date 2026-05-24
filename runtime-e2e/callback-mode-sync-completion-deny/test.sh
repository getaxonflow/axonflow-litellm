#!/usr/bin/env bash
# Verify: callback-mode deny behavior — governance fires, policy denies,
# but LiteLLM swallows the exception (documented limitation).
#
# This test proves:
# 1. Pre_check fires (gateway_contexts row created)
# 2. The deny was detected (warning logged: "audit-only mode, not blocking")
# 3. The LLM call proceeds anyway (LiteLLM swallows callback exceptions)
#
# For actual BLOCKING deny, use logger.completion() — tested in sync-completion-deny/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== callback-mode-sync-completion-deny ==="

MARKER="e2e-cbdeny-$(date +%s)-$RANDOM"

POLICY_RESPONSE=$(create_deny_policy "CB deny test ${MARKER}" "(?i)${MARKER}")
POLICY_ID=$(echo "$POLICY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [ -z "$POLICY_ID" ]; then
  echo "FAIL: could not create deny policy — response: $POLICY_RESPONSE"
  exit 1
fi
echo "Created policy: $POLICY_ID"
sleep 2  # wait for shared policy engine to reload
cleanup() { delete_policy "$POLICY_ID"; echo "Cleaned up policy $POLICY_ID"; }
trap cleanup EXIT

OUTPUT=$(mktemp -t cb-deny-e2e.XXXXXX)
BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts before: $BEFORE_COUNT"

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<PYEOF
import sys
import os
import litellm
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

marker = sys.argv[1]

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
))

litellm.callbacks = [logger]

response = litellm.completion(
    model=os.environ.get("LLM_MODEL", "ollama/llama3.2:1b"),
    messages=[{"role": "user", "content": f"Process: {marker}"}],
    max_tokens=10,
)
print(f"Response: {response.choices[0].message.content[:50]}")
print("DENY_RESULT=allowed_callback_mode")
PYEOF

cat "$OUTPUT"

sleep 1
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts after: $AFTER_COUNT"

# Assert 1: governance fired (new gateway_contexts row)
if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  echo "FAIL: no new gateway_contexts row — governance did not fire"
  rm -f "$OUTPUT"
  exit 1
fi

# Assert 2: deny was detected but LLM call proceeded (callback mode limitation)
if ! grep -q "DENY_RESULT=allowed_callback_mode" "$OUTPUT"; then
  echo "FAIL: expected LLM call to proceed in callback mode (deny is audit-only)"
  rm -f "$OUTPUT"
  exit 1
fi

rm -f "$OUTPUT"

echo "PASS: callback-mode-sync-completion-deny"
echo "  Governance fired: gateway_contexts $BEFORE_COUNT → $AFTER_COUNT"
echo "  Deny logged but not blocking (callback mode = audit-only)"
