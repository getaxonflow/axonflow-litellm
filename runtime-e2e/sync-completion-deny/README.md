# sync-completion-deny

Verifies that `logger.completion()` raises `PolicyDeniedError` when the AxonFlow
policy denies the request.

## Prereqs
- AxonFlow stack running with at least one deny policy (e.g., SQL injection detection)
- `OPENAI_API_KEY` or equivalent

## Run
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/sync-completion-deny/test.sh
```
