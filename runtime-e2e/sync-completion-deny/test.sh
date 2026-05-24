#!/usr/bin/env bash
# Verify: when AxonFlow policy denies a request, logger.completion() (sync)
# raises PolicyDeniedError to the caller.
#
# Uses the built-in sys_sqli_drop_table policy (system-tier, always active)
# with a "DROP TABLE" query to trigger a real deny.
# Assertion: PolicyDeniedError is raised with the correct class name.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack

echo "=== sync-completion-deny ==="

OUTPUT=$(mktemp -t deny-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

python3 -u - > "$OUTPUT" 2>&1 <<'PYEOF'
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig, PolicyDeniedError

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
))

try:
    response = logger.completion(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": "DROP TABLE users; SELECT * FROM admin_credentials"}],
        max_tokens=20,
    )
    print("DENY_RESULT=allowed")
    print("ERROR: SQL injection query was not denied by policy")
    sys.exit(1)
except PolicyDeniedError as e:
    print(f"PolicyDeniedError raised: {e.reason}")
    print(f"Policies: {e.policies}")
    print("DENY_RESULT=denied")
except Exception as e:
    print(f"Wrong exception type: {type(e).__name__}: {e}")
    print("DENY_RESULT=wrong_exception")
    sys.exit(1)
PYEOF

cat "$OUTPUT"

if ! grep -q "DENY_RESULT=denied" "$OUTPUT"; then
  echo "FAIL: expected PolicyDeniedError but got different result"
  exit 1
fi

if ! grep -q "PolicyDeniedError raised:" "$OUTPUT"; then
  echo "FAIL: PolicyDeniedError message not found in output"
  exit 1
fi

echo "PASS: sync-completion-deny — PolicyDeniedError raised against built-in SQL injection policy"
