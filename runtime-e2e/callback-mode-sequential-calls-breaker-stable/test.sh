#!/usr/bin/env bash
# Verify: 5 sequential litellm.completion() calls with callback-mode
# all succeed and each creates a gateway_contexts row. Circuit breaker
# stays closed throughout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== callback-mode-sequential-calls-breaker-stable ==="

N=5
OUTPUT=$(mktemp -t cb-seq-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts before: $BEFORE_COUNT"

python3 -u - "$N" > "$OUTPUT" 2>&1 <<PYEOF
import sys, os
import litellm
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

n = int(sys.argv[1])
logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
))
litellm.callbacks = [logger]

successes = 0
for i in range(n):
    try:
        r = litellm.completion(
            model=os.environ.get("LLM_MODEL", "ollama/llama3.2:1b"),
            messages=[{"role": "user", "content": f"Say {i}"}],
            max_tokens=5,
        )
        content = r.choices[0].message.content
        if content and content.strip():
            successes += 1
            print(f"Call {i+1}/{n}: {content.strip()[:20]}")
        else:
            print(f"Call {i+1}/{n}: empty response")
    except Exception as e:
        print(f"Call {i+1}/{n}: {type(e).__name__}: {e}")

print(f"SEQUENTIAL_RESULT={successes}/{n}")
PYEOF

cat "$OUTPUT"

EXPECTED_SUCCESSES="$N"
ACTUAL=$(grep -o "SEQUENTIAL_RESULT=[0-9]*" "$OUTPUT" | cut -d= -f2 || echo "0")

if [ "$ACTUAL" -ne "$EXPECTED_SUCCESSES" ]; then
  echo "FAIL: expected $EXPECTED_SUCCESSES/$N successes, got $ACTUAL"
  exit 1
fi

sleep 1
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts after: $AFTER_COUNT"
EXPECTED_NEW=$((BEFORE_COUNT + N))

if [ "$AFTER_COUNT" -lt "$EXPECTED_NEW" ]; then
  echo "FAIL: expected at least $N new gateway_contexts rows"
  echo "  Before: $BEFORE_COUNT, After: $AFTER_COUNT, Expected: >= $EXPECTED_NEW"
  exit 1
fi

echo "PASS: callback-mode-sequential-calls-breaker-stable"
echo "  $N/$N calls succeeded, gateway_contexts $BEFORE_COUNT → $AFTER_COUNT"
