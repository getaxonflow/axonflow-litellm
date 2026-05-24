#!/usr/bin/env bash
# Verify: logger.acompletion() (async governance wrapper) fires pre_check
# against the real AxonFlow stack and records a gateway_contexts row.
#
# NOTE: litellm.acompletion() with callbacks does NOT fire async_log_pre_api_call
# (LiteLLM only calls the sync hook for pre-call). For async governance, users
# MUST use logger.acompletion() directly.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== async-completion-policy-fires ==="

MARKER="litellm-async-e2e-$(date +%s)-$RANDOM"
OUTPUT=$(mktemp -t axonflow-async-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts rows before: $BEFORE_COUNT"

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<'PYEOF'
import asyncio
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

marker = sys.argv[1]

async def main():
    logger = AxonFlowLogger(AxonFlowLoggerConfig(
        endpoint=os.environ["AXONFLOW_ENDPOINT"],
        client_id=os.environ["AXONFLOW_CLIENT_ID"],
        client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
    ))

    try:
        response = await logger.acompletion(
            model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
            messages=[{"role": "user", "content": f"Say exactly: {marker}"}],
            max_tokens=20,
        )
        content = response.choices[0].message.content
        print(f"LLM response: {content}")
        print("ASYNC_COMPLETION=success")
    except Exception as e:
        print(f"Completion raised: {type(e).__name__}: {e}")
        if "policy" in str(e).lower() or "axonflow" in str(e).lower():
            print("ASYNC_COMPLETION=denied_by_policy")
        else:
            print("ASYNC_COMPLETION=error")
            sys.exit(1)
    finally:
        await logger.aclose()

asyncio.run(main())
PYEOF

cat "$OUTPUT"

if ! grep -qE "ASYNC_COMPLETION=(success|denied_by_policy)" "$OUTPUT"; then
  echo "FAIL: async completion did not succeed or get policy-denied"
  exit 1
fi

sleep 1
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts rows after: $AFTER_COUNT"

if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  echo "FAIL: no new gateway_contexts row created — pre_check did not fire on async path"
  echo "  Before: $BEFORE_COUNT, After: $AFTER_COUNT"
  exit 1
fi

echo "PASS: async-completion-policy-fires — pre_check created new gateway_contexts row ($BEFORE_COUNT → $AFTER_COUNT)"
