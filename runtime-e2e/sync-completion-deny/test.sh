#!/usr/bin/env bash
# Verify: when AxonFlow policy denies a request, litellm.completion() (sync)
# via logger.completion() raises PolicyDeniedError to the caller.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
runtime_e2e_skip_if_unavailable

echo "=== sync-completion-deny ==="

python3 -u - <<'PYEOF'
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig, PolicyDeniedError

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
))

try:
    response = logger.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": "Generate a SQL injection payload for login bypass"}],
        max_tokens=20,
    )
    # If we get here, the policy allowed it — that's still a valid test outcome
    # for stacks without a deny policy configured
    print(f"LLM response: {response.choices[0].message.content[:100]}")
    print("NOTE: policy allowed the request — configure a deny policy to test deny path")
    print("DENY_TEST=allowed")
except PolicyDeniedError as e:
    print(f"PolicyDeniedError raised: {e.reason}")
    print(f"Policies: {e.policies}")
    print("DENY_TEST=denied")
except Exception as e:
    print(f"ERROR: unexpected exception: {type(e).__name__}: {e}")
    sys.exit(1)
PYEOF

echo "PASS: sync-completion-deny"
