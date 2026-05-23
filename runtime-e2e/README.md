# runtime-e2e

> **If a user cannot reach the feature from their runtime, we did not ship a feature, we shipped a library.**

These tests verify that `axonflow-litellm` governance actually fires when a real
`litellm.completion()` call runs against a real AxonFlow stack. They use zero
mocks, zero stubs, zero HTTP interception — real LiteLLM, real AxonFlow
docker-compose stack, real policy evaluation.

Every test queries stack state (API responses, DB rows) to verify the feature
ran. Tests that cannot fail when the feature is broken are theater — they are
banned by HARD RULE 9a.

## Prerequisites

- Docker + Docker Compose
- Python 3.10+ with `axonflow-litellm` and `litellm` installed
- An LLM API key (set `OPENAI_API_KEY` or any LiteLLM-supported provider)
- `psql` on PATH (for DB assertion tests)
- AxonFlow community stack docker-compose directory

## Running

```bash
# Set the path to the AxonFlow docker-compose directory
export AXONFLOW_STACK_DIR=/path/to/axonflow-enterprise

# Start the stack
bash runtime-e2e/_lib/setup-stack.sh

# Run all tests
for test in runtime-e2e/*/test.sh; do
  echo "--- Running $test ---"
  bash "$test" || exit 1
done

# Tear down
bash runtime-e2e/_lib/teardown-stack.sh
```

## Tests

| Test | What it verifies | Stack needed | DB query |
|------|-----------------|:---:|:---:|
| `fail-closed-on-stack-down` | `fail_open=False` raises when AxonFlow unreachable | No | No |
| `fail-open-on-stack-down` | `fail_open=True` bypasses AxonFlow transparently | No | No |
| `sync-completion-policy-fires` | Sync `litellm.completion()` fires pre_check | Yes | API |
| `async-completion-policy-fires` | Async `litellm.acompletion()` fires pre_check | Yes | API |
| `sync-completion-deny` | Deny policy raises `PolicyDeniedError` | Yes | API |
| `audit-recorded-on-success` | Success path records decision row | Yes | API |
| `sync-completion-hitl-approve` | Full HITL create→approve→resume cycle | Yes | DB |

## Design rules

- Tests exit 0 ONLY after all assertions pass. Exit 1 on ANY failure.
- No silent skips. `require_stack` exits 1 when the stack is unreachable.
- Every assertion queries real stack state (API or DB), not logger internals.
- `grep -rE "mock|stub|patch|Mock" runtime-e2e/` must return zero hits in test scripts.
