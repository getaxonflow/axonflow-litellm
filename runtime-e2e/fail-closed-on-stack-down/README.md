# fail-closed-on-stack-down

Verifies that when AxonFlow is unreachable and `fail_open=False`, `logger.completion()`
raises an exception. The LLM call does NOT proceed without policy approval.

## Prereqs
- None (test intentionally points at unreachable endpoint)

## Run
```bash
bash runtime-e2e/fail-closed-on-stack-down/test.sh
```
