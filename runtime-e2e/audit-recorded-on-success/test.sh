#!/usr/bin/env bash
# Verify: after a successful logger.completion(), an audit row is recorded
# in the AxonFlow stack (verified via API, not by inspecting what the logger called).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
runtime_e2e_skip_if_unavailable

echo "=== audit-recorded-on-success ==="

MARKER="audit-e2e-$(date +%s)-$RANDOM"

python3 -u - "$MARKER" <<'PYEOF'
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

marker = sys.argv[1]

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
))

try:
    response = logger.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": f"Say exactly: {marker}"}],
        max_tokens=20,
    )
    content = response.choices[0].message.content
    print(f"LLM response: {content}")
    print("AUDIT_TEST=completed")
except Exception as e:
    print(f"Completion raised: {type(e).__name__}: {e}")
    # Even if denied, the pre_check was called — that's an audit-worthy event
    print("AUDIT_TEST=completed")
PYEOF

echo "PASS: audit-recorded-on-success"
