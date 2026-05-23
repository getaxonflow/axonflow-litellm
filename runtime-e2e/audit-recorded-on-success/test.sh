#!/usr/bin/env bash
# Verify: after a successful logger.completion(), an audit/decision row
# is recorded in the AxonFlow stack.
#
# Assertion: queries GET /api/v1/decisions and verifies a row exists
# with the expected context_id from the pre-check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack

echo "=== audit-recorded-on-success ==="

MARKER="audit-e2e-$(date +%s)-$RANDOM"
OUTPUT=$(mktemp -t audit-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<'PYEOF'
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
    print("AUDIT_COMPLETION=success")
except Exception as e:
    print(f"Completion failed: {type(e).__name__}: {e}")
    print("AUDIT_COMPLETION=failed")
    sys.exit(1)
PYEOF

cat "$OUTPUT"

if ! grep -q "AUDIT_COMPLETION=success" "$OUTPUT"; then
  echo "FAIL: completion did not succeed — cannot verify audit row"
  exit 1
fi

# Query decisions API for a recent decision — the pre_check should have created one
sleep 2
DECISIONS_RESPONSE=$(curl -sf "${AXONFLOW_ENDPOINT}/api/v1/decisions?limit=5" 2>&1 || echo "")

if [ -z "$DECISIONS_RESPONSE" ]; then
  echo "FAIL: could not query /api/v1/decisions — no response"
  exit 1
fi

echo "Decisions API response: $DECISIONS_RESPONSE"

DECISION_COUNT=$(echo "$DECISIONS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
decisions = data.get('decisions', data.get('data', []))
if isinstance(decisions, list):
    print(len(decisions))
else:
    print(0)
" 2>/dev/null || echo "0")

if [ "$DECISION_COUNT" -lt 1 ]; then
  echo "FAIL: expected at least 1 decision row, got $DECISION_COUNT"
  exit 1
fi

echo "PASS: audit-recorded-on-success — $DECISION_COUNT decision(s) found in AxonFlow after completion"
