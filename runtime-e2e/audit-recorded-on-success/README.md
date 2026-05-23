# audit-recorded-on-success

Verifies that `logger.completion()` records an audit row in AxonFlow after a
successful LLM call.

## Prereqs
- AxonFlow stack running at `$AXONFLOW_ENDPOINT`
- `OPENAI_API_KEY` or equivalent

## Run
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/audit-recorded-on-success/test.sh
```
