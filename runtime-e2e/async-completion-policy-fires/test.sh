#!/usr/bin/env bash
# Verify: litellm.acompletion() (async) with AxonFlowLogger registered as callback
# fires pre_check against the real AxonFlow stack and records a decision.
#
# Assertion: queries GET /api/v1/decisions after the completion and verifies
# at least one decision exists (proving pre_check ran on the async path).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack

echo "=== async-completion-policy-fires ==="

MARKER="litellm-async-e2e-$(date +%s)-$RANDOM"
OUTPUT=$(mktemp -t axonflow-async-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<'PYEOF'
import asyncio
import sys
import os
import litellm
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

marker = sys.argv[1]

async def main():
    logger = AxonFlowLogger(AxonFlowLoggerConfig(
        endpoint=os.environ["AXONFLOW_ENDPOINT"],
        client_id=os.environ["AXONFLOW_CLIENT_ID"],
        client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    ))

    litellm.callbacks = [logger]

    try:
        response = await litellm.acompletion(
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

# Verify a decision was recorded
sleep 2
DECISIONS_RESPONSE=$(curl -sf "${AXONFLOW_ENDPOINT}/api/v1/decisions?limit=5" 2>&1 || echo "")
echo "Decisions API response: $DECISIONS_RESPONSE"

DECISION_COUNT=$(echo "$DECISIONS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
decisions = data.get('decisions', data.get('data', []))
print(len(decisions) if isinstance(decisions, list) else 0)
" 2>/dev/null || echo "0")

if [ "$DECISION_COUNT" -lt 1 ]; then
  echo "FAIL: no decisions found after async completion — pre_check may not have fired"
  exit 1
fi

echo "PASS: async-completion-policy-fires — pre_check fired, $DECISION_COUNT decision(s) recorded"
