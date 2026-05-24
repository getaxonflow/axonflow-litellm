#!/usr/bin/env bash
# Verify: litellm.completion() (sync, callback-mode) fires governance.
#
# Uses the REAL customer pattern:
#   litellm.callbacks = [AxonFlowLogger(...)]
#   response = litellm.completion(...)
#
# NOT logger.completion(). This is the v1.0.1 fix surface.
# Asserts: gateway_contexts row created (psql) + response has content.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== callback-mode-sync-completion-policy-fires ==="

OUTPUT=$(mktemp -t cb-sync-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts before: $BEFORE_COUNT"

python3 -u - > "$OUTPUT" 2>&1 <<PYEOF
import sys
import os
import litellm
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
))

litellm.callbacks = [logger]

response = litellm.completion(
    model=os.environ.get("LLM_MODEL", "ollama/llama3.2:1b"),
    messages=[{"role": "user", "content": "Say exactly: hello-e2e"}],
    max_tokens=10,
)
content = response.choices[0].message.content
if not content or not content.strip():
    print("RESULT=empty_response")
    sys.exit(1)
print(f"LLM response: {content}")
print("RESULT=success")
PYEOF

cat "$OUTPUT"

if ! grep -q "RESULT=success" "$OUTPUT"; then
  echo "FAIL: callback-mode sync completion did not return a valid response"
  exit 1
fi

sleep 1
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts after: $AFTER_COUNT"

if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  echo "FAIL: no new gateway_contexts row — callback-mode sync governance did NOT fire"
  exit 1
fi

echo "PASS: callback-mode-sync-completion-policy-fires ($BEFORE_COUNT → $AFTER_COUNT)"
