#!/usr/bin/env bash
# Verify: after a successful logger.completion(), an audit row is recorded
# in the AxonFlow llm_call_audits table.
#
# Assertion: queries llm_call_audits via psql to verify a new row was created.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== audit-recorded-on-success ==="

MARKER="audit-e2e-$(date +%s)-$RANDOM"
OUTPUT=$(mktemp -t audit-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

BEFORE_COUNT=$(run_psql -c "SELECT count(*) FROM llm_call_audits")
echo "llm_call_audits rows before: $BEFORE_COUNT"

python3 -u - "$MARKER" > "$OUTPUT" 2>&1 <<'PYEOF'
import sys
import os
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

marker = sys.argv[1]

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ["AXONFLOW_ENDPOINT"],
    client_id=os.environ["AXONFLOW_CLIENT_ID"],
    client_secret=os.environ.get("AXONFLOW_CLIENT_SECRET", ""),
    default_user_token=os.environ.get("AXONFLOW_USER_TOKEN", "anonymous"),
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

# Wait for audit row to be written (async, may take a moment)
sleep 3
AFTER_COUNT=$(run_psql -c "SELECT count(*) FROM llm_call_audits")
echo "llm_call_audits rows after: $AFTER_COUNT"

if [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]; then
  echo "FAIL: no new llm_call_audits row created after successful completion"
  echo "  Before: $BEFORE_COUNT, After: $AFTER_COUNT"
  exit 1
fi

# Show the most recent audit row as evidence
LATEST_ROW=$(run_psql -c "SELECT audit_id, context_id, provider, model, prompt_tokens, completion_tokens, latency_ms FROM llm_call_audits ORDER BY created_at DESC LIMIT 1")
echo "Latest audit row: $LATEST_ROW"

echo "PASS: audit-recorded-on-success — new llm_call_audits row created ($BEFORE_COUNT → $AFTER_COUNT)"
