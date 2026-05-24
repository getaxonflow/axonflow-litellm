#!/usr/bin/env bash
# Verify: the sync callback path (litellm.callbacks + litellm.completion)
# actually writes a POST-LLM audit row to llm_call_audits — not just a
# pre_check row to gateway_contexts.
#
# This is the audit-completeness assertion: pre_check fires via
# log_pre_api_call (gateway_contexts), and audit fires via
# log_success_event (llm_call_audits). Both must produce DB rows.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../_lib/common.sh"
require_stack
require_psql

echo "=== callback-mode-sync-audit-row-written ==="

OUTPUT=$(mktemp -t cb-audit-row-e2e.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

BEFORE_GC=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
BEFORE_AUDIT=$(run_psql -c "SELECT count(*) FROM llm_call_audits")
echo "gateway_contexts before: $BEFORE_GC"
echo "llm_call_audits before: $BEFORE_AUDIT"

python3 -u -c "
import os, litellm
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint=os.environ['AXONFLOW_ENDPOINT'],
    client_id=os.environ['AXONFLOW_CLIENT_ID'],
    client_secret=os.environ.get('AXONFLOW_CLIENT_SECRET', ''),
    default_user_token=os.environ.get('AXONFLOW_USER_TOKEN', 'anonymous'),
))

litellm.callbacks = [logger]

response = litellm.completion(
    model=os.environ.get('LLM_MODEL', 'ollama/llama3.2:1b'),
    messages=[{'role': 'user', 'content': 'Say exactly: audit-row-test'}],
    max_tokens=10,
)
content = response.choices[0].message.content
if not content or not content.strip():
    print('RESULT=empty_response')
    import sys; sys.exit(1)
print(f'LLM response: {content}')
print('RESULT=success')
" > "$OUTPUT" 2>&1

cat "$OUTPUT"

if ! grep -q "RESULT=success" "$OUTPUT"; then
  echo "FAIL: completion did not succeed"
  exit 1
fi

# Wait for async audit to complete (sync hook uses asyncio.run which blocks,
# but LiteLLM may fire hooks after returning the response)
sleep 3

AFTER_GC=$(run_psql -c "SELECT count(*) FROM gateway_contexts")
AFTER_AUDIT=$(run_psql -c "SELECT count(*) FROM llm_call_audits")
echo "gateway_contexts after: $AFTER_GC"
echo "llm_call_audits after: $AFTER_AUDIT"

# Assert 1: pre_check row created (governance fired)
if [ "$AFTER_GC" -le "$BEFORE_GC" ]; then
  echo "FAIL: no new gateway_contexts row — pre_check did not fire"
  exit 1
fi

# Assert 2: POST-LLM audit row created (audit callback fired)
if [ "$AFTER_AUDIT" -le "$BEFORE_AUDIT" ]; then
  echo "FAIL: no new llm_call_audits row — log_success_event did NOT write audit"
  echo "  This means the sync callback audit path is broken."
  echo "  Before: $BEFORE_AUDIT, After: $AFTER_AUDIT"
  exit 1
fi

# Show the latest audit row as evidence
LATEST=$(run_psql -c "SELECT audit_id, context_id, provider, model, prompt_tokens, completion_tokens, latency_ms FROM llm_call_audits ORDER BY created_at DESC LIMIT 1")
echo "Latest audit row: $LATEST"

echo "PASS: callback-mode-sync-audit-row-written"
echo "  gateway_contexts: $BEFORE_GC → $AFTER_GC"
echo "  llm_call_audits: $BEFORE_AUDIT → $AFTER_AUDIT"
