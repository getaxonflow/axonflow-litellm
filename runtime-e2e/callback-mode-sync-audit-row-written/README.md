# callback-mode-sync-audit-row-written

Verifies that `litellm.completion()` (sync, callback-mode) writes BOTH a
pre_check row (gateway_contexts) AND a post-LLM audit row (llm_call_audits).

This closes the audit-completeness gap: proving that `log_success_event`
actually fires and writes via the sync `asyncio.run()` bridge path.

## Prereqs
- AxonFlow stack running, psql on PATH, LLM API key

## Run
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/callback-mode-sync-audit-row-written/test.sh
```
