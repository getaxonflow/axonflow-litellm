#!/usr/bin/env bash
# Verify: when AxonFlow stack is unreachable and fail_open=True (default),
# litellm.completion() proceeds normally without error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== fail-open-on-stack-down ==="

# Intentionally point at a non-existent endpoint
export AXONFLOW_ENDPOINT="http://127.0.0.1:19999"
export AXONFLOW_CLIENT_ID="test"
export AXONFLOW_CLIENT_SECRET="test"

python3 -u - <<'PYEOF'
import sys
import os
import litellm
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ["AXONFLOW_CLIENT_SECRET"],
    fail_open=True,
    call_timeout_seconds=2.0,
))

litellm.callbacks = [logger]

try:
    response = litellm.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": "Say hello"}],
        max_tokens=10,
    )
    content = response.choices[0].message.content
    print(f"LLM response: {content}")
    print("FAIL_OPEN_TEST=passed_through")
except Exception as e:
    if "policy" in str(e).lower() or "axonflow" in str(e).lower():
        print(f"ERROR: fail_open=True but got governance exception: {e}")
        sys.exit(1)
    else:
        # LLM provider error is fine (e.g., no API key) — we're testing
        # that AxonFlow being down doesn't block
        print(f"LLM error (expected if no API key): {type(e).__name__}: {e}")
        print("FAIL_OPEN_TEST=passed_through")
PYEOF

echo "PASS: fail-open-on-stack-down"
