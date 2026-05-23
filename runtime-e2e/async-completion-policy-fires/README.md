# async-completion-policy-fires

Verifies that `litellm.acompletion()` (async) with `AxonFlowLogger` as callback
fires governance against the AxonFlow stack.

## Prereqs
- AxonFlow stack running at `$AXONFLOW_ENDPOINT`
- `OPENAI_API_KEY` or equivalent LLM provider key

## Run
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/async-completion-policy-fires/test.sh
```
