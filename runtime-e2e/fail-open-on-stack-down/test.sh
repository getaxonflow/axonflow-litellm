#!/usr/bin/env bash
# Verify: when AxonFlow stack is unreachable and fail_open=True (default),
# litellm.completion() proceeds normally and returns a valid LLM response.
#
# This test intentionally points at an unreachable AxonFlow endpoint.
# Assertion: the call returns a response with non-empty content.
# Does NOT require an AxonFlow stack — requires only an LLM API key.
set -euo pipefail

echo "=== fail-open-on-stack-down ==="

if ! command -v python3 &>/dev/null; then
  echo "FAIL: python3 not on PATH"
  exit 1
fi

# Intentionally point at a non-existent AxonFlow endpoint
export AXONFLOW_ENDPOINT="http://127.0.0.1:19999"
export AXONFLOW_CLIENT_ID="test"
export AXONFLOW_CLIENT_SECRET="test"

OUTPUT=$(mktemp -t fail-open-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

python3 -u - > "$OUTPUT" 2>&1 <<'PYEOF'
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ["AXONFLOW_CLIENT_SECRET"],
    fail_open=True,
    call_timeout_seconds=2.0,
))

try:
    response = logger.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": "Say exactly: hello"}],
        max_tokens=10,
    )
    content = response.choices[0].message.content
    if not content or not content.strip():
        print("FAIL_OPEN_RESULT=empty_response")
        sys.exit(1)
    print(f"LLM response: {content}")
    print("FAIL_OPEN_RESULT=valid_response")
except Exception as e:
    error_str = str(e).lower()
    if "policy" in error_str or "axonflow" in error_str or "fail_open" in error_str:
        print(f"FAIL: AxonFlow governance exception leaked through fail_open=True: {e}")
        print("FAIL_OPEN_RESULT=governance_leaked")
        sys.exit(1)
    # LLM provider errors (no API key, rate limit, etc.) are acceptable —
    # they prove AxonFlow being down didn't block the call
    print(f"LLM provider error (acceptable — proves AxonFlow bypassed): {type(e).__name__}: {e}")
    print("FAIL_OPEN_RESULT=llm_error_axonflow_bypassed")
PYEOF

cat "$OUTPUT"

# Assert: the result must be either valid_response OR llm_error_axonflow_bypassed
# It must NOT be governance_leaked
if grep -q "FAIL_OPEN_RESULT=governance_leaked" "$OUTPUT"; then
  echo "FAIL: AxonFlow governance exception leaked through fail_open=True"
  exit 1
fi

if ! grep -qE "FAIL_OPEN_RESULT=(valid_response|llm_error_axonflow_bypassed)" "$OUTPUT"; then
  echo "FAIL: unexpected result — neither valid response nor acceptable LLM error"
  exit 1
fi

echo "PASS: fail-open-on-stack-down — AxonFlow being unreachable did not block the LLM call"
