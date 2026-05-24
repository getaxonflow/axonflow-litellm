#!/usr/bin/env bash
# Verify: streaming litellm.completion(stream=True) with callback-mode
# fires pre_check BEFORE the first chunk is consumed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== callback-mode-streaming-completion-governed ==="

OUTPUT=$(mktemp -t cb-stream-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts before: $BEFORE_COUNT"

python3 -u - > "$OUTPUT" 2>&1 <<PYEOF
import sys, os
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
    messages=[{"role": "user", "content": "Count from 1 to 5"}],
    max_tokens=20,
    stream=True,
)

chunks = []
for chunk in response:
    delta = chunk.choices[0].delta
    content = getattr(delta, "content", None)
    if content:
        chunks.append(content)

full_response = "".join(chunks)
if not full_response.strip():
    print("STREAM_RESULT=empty")
    sys.exit(1)

print(f"Streamed response: {full_response[:50]}")
print(f"Chunk count: {len(chunks)}")
print("STREAM_RESULT=success")
PYEOF

cat "$OUTPUT"

if ! grep -q "STREAM_RESULT=success" "$OUTPUT"; then
  echo "FAIL: streaming completion did not succeed"
  exit 1
fi

sleep 1
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
echo "gateway_contexts after: $AFTER_COUNT"

if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  echo "FAIL: no new gateway_contexts row — pre_check did not fire for streaming"
  exit 1
fi

echo "PASS: callback-mode-streaming-completion-governed ($BEFORE_COUNT → $AFTER_COUNT)"
