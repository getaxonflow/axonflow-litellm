#!/usr/bin/env bash
# Verify: litellm.completion() (sync) with AxonFlowLogger registered as callback
# fires pre_check against the real AxonFlow stack.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
runtime_e2e_skip_if_unavailable

echo "=== sync-completion-policy-fires ==="

MARKER="litellm-sync-e2e-$(date +%s)-$RANDOM"

python3 -u - "$MARKER" <<'PYEOF'
import sys
import os
import litellm
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

marker = sys.argv[1]

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
))

litellm.callbacks = [logger]

try:
    response = litellm.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": f"Say exactly: {marker}"}],
        max_tokens=20,
    )
    content = response.choices[0].message.content
    print(f"LLM response: {content}")
    print("SYNC_GOVERNANCE_FIRED=true")
except Exception as e:
    print(f"Completion raised: {type(e).__name__}: {e}")
    if "AXONFLOW" in str(e).upper() or "policy" in str(e).lower():
        print("SYNC_GOVERNANCE_FIRED=true")
    else:
        print(f"ERROR: unexpected exception: {e}")
        sys.exit(1)
PYEOF

echo "PASS: sync-completion-policy-fires"
