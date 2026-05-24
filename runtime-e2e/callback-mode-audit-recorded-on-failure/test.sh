#!/usr/bin/env bash
# Verify: pre_check fires even when the LLM call fails (invalid model).
# The governance gate runs BEFORE the LLM call, so pre_check should
# always create a gateway_contexts row regardless of LLM outcome.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== callback-mode-audit-recorded-on-failure ==="

OUTPUT=$(mktemp -t cb-fail-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts before: $BEFORE_COUNT"

python3 -u - > "$OUTPUT" 2>&1 <<PYEOF
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
))

try:
    response = logger.completion(
        model="nonexistent-model-xyz-404",
        messages=[{"role": "user", "content": "hello"}],
        max_tokens=10,
    )
    print("RESULT=unexpected_success")
except Exception as e:
    print(f"Expected error: {type(e).__name__}: {str(e)[:100]}")
    print("RESULT=error_after_precheck")
PYEOF

cat "$OUTPUT"

if ! grep -q "RESULT=error_after_precheck" "$OUTPUT"; then
  echo "FAIL: expected an error from the invalid model"
  exit 1
fi

sleep 1
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts after: $AFTER_COUNT"

if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  echo "FAIL: no new gateway_contexts row — pre_check did not fire before LLM failure"
  exit 1
fi

echo "PASS: callback-mode-audit-recorded-on-failure ($BEFORE_COUNT → $AFTER_COUNT)"
