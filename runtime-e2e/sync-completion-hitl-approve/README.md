# sync-completion-hitl-approve

Verifies the full HITL 4-step flow: pre-check returns `require_approval`, the
logger creates a HITL queue entry, a background thread auto-approves it via
direct API, and the completion proceeds.

## Prereqs
- AxonFlow stack with a `require_approval` policy
- `OPENAI_API_KEY` or equivalent

## Run
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/sync-completion-hitl-approve/test.sh
```
