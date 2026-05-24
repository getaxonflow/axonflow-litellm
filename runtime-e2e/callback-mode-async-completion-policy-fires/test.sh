#!/usr/bin/env bash
# Verify: logger.acompletion() (async governance wrapper) fires pre_check.
# NOTE: litellm.acompletion() with callbacks does NOT fire async_log_pre_api_call
# (LiteLLM only calls the sync hook for pre-call). For async governance, users
# MUST use logger.acompletion() directly.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== callback-mode-async-completion-policy-fires ==="

OUTPUT=$(mktemp -t cb-async-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts before: $BEFORE_COUNT"

python3 -u - > "$OUTPUT" 2>&1 <<PYEOF
import asyncio
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

async def main():
    logger = AxonFlowLogger(AxonFlowLoggerConfig(
        endpoint=os.environ["AXONFLOW_ENDPOINT"],
        client_id=os.environ["AXONFLOW_CLIENT_ID"],
        client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
        default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
    ))
    try:
        response = await logger.acompletion(
            model=os.environ.get("LLM_MODEL", "ollama/llama3.2:1b"),
            messages=[{"role": "user", "content": "Say hello"}],
            max_tokens=10,
        )
        content = response.choices[0].message.content
        if not content or not content.strip():
            print("RESULT=empty")
            sys.exit(1)
        print(f"LLM response: {content}")
        print("RESULT=success")
    finally:
        await logger.aclose()

asyncio.run(main())
PYEOF

cat "$OUTPUT"

if ! grep -q "RESULT=success" "$OUTPUT"; then
  echo "FAIL: async governance wrapper did not return a valid response"
  exit 1
fi

sleep 1
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts after: $AFTER_COUNT"

if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  echo "FAIL: no new gateway_contexts row — async governance did NOT fire"
  exit 1
fi

echo "PASS: callback-mode-async-completion-policy-fires ($BEFORE_COUNT → $AFTER_COUNT)"
