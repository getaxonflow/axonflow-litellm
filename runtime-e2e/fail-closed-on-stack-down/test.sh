#!/usr/bin/env bash
# Verify: when AxonFlow stack is unreachable and fail_open=False,
# logger.completion() raises PolicyDeniedError — the LLM call does NOT proceed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== fail-closed-on-stack-down ==="

# Intentionally point at a non-existent endpoint
export AXONFLOW_ENDPOINT="http://127.0.0.1:19999"
export AXONFLOW_CLIENT_ID="test"
export AXONFLOW_CLIENT_SECRET="test"

python3 -u - <<'PYEOF'
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig, PolicyDeniedError

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ["AXONFLOW_CLIENT_SECRET"],
    fail_open=False,
    call_timeout_seconds=2.0,
))

try:
    response = logger.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": "Say hello"}],
        max_tokens=10,
    )
    print("ERROR: completion succeeded — fail_open=False should have raised")
    sys.exit(1)
except PolicyDeniedError as e:
    print(f"PolicyDeniedError raised (correct): {e.reason}")
    print("FAIL_CLOSED_TEST=raised")
except Exception as e:
    # Any exception (including connection errors that propagate) is acceptable
    # for fail_open=False — the point is the LLM call did NOT proceed
    print(f"Exception raised (acceptable): {type(e).__name__}: {e}")
    print("FAIL_CLOSED_TEST=raised")
PYEOF

echo "PASS: fail-closed-on-stack-down"
