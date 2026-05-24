#!/usr/bin/env bash
# Verify: litellm.completion() (sync) with AxonFlowLogger registered as callback
# fires pre_check against the real AxonFlow stack.
#
# Assertion: queries gateway_contexts table via psql to verify a new row
# was created by the pre_check call (proving governance fired on the sync path).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== sync-completion-policy-fires ==="

MARKER="litellm-sync-e2e-$(date +%s)-$RANDOM"
OUTPUT=$(mktemp -t axonflow-sync-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

# Count pre_check rows before
BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts rows before: $BEFORE_COUNT"

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<'PYEOF'
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

try:
    response = litellm.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": f"Say exactly: {marker}"}],
        max_tokens=20,
    )
    content = response.choices[0].message.content
    print(f"LLM response: {content}")
    print("SYNC_COMPLETION=success")
except Exception as e:
    print(f"Completion raised: {type(e).__name__}: {e}")
    if "policy" in str(e).lower() or "axonflow" in str(e).lower():
        print("SYNC_COMPLETION=denied_by_policy")
    else:
        print("SYNC_COMPLETION=error")
        sys.exit(1)
PYEOF

cat "$OUTPUT"

if ! grep -qE "SYNC_COMPLETION=(success|denied_by_policy)" "$OUTPUT"; then
  echo "FAIL: sync completion did not succeed or get policy-denied"
  exit 1
fi

# Verify a new gateway_contexts row was created (proves pre_check fired)
sleep 1
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts rows after: $AFTER_COUNT"

if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  echo "FAIL: no new gateway_contexts row created — pre_check did not fire on sync path"
  echo "  Before: $BEFORE_COUNT, After: $AFTER_COUNT"
  exit 1
fi

echo "PASS: sync-completion-policy-fires — pre_check created new gateway_contexts row ($BEFORE_COUNT → $AFTER_COUNT)"
