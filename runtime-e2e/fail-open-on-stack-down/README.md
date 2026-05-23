# fail-open-on-stack-down

Verifies that when AxonFlow is unreachable and `fail_open=True` (default), the
LLM call proceeds normally. AxonFlow outage does not break the application.

## Prereqs
- `OPENAI_API_KEY` or equivalent (optional — test also passes if LLM provider
  rejects, as long as AxonFlow being down didn't cause the failure)

## Run
```bash
bash runtime-e2e/fail-open-on-stack-down/test.sh
```
