# runtime-e2e

> **If a user cannot reach the feature from their runtime, we did not ship a feature, we shipped a library.**

These tests verify that `axonflow-litellm` governance actually fires when a real
`litellm.completion()` call runs against a real AxonFlow stack. They use zero
mocks, zero stubs, zero HTTP interception — real LiteLLM, real AxonFlow
docker-compose stack, real policy evaluation.

## Prerequisites

- Docker + Docker Compose
- Python 3.10+
- `pip install axonflow-litellm litellm` (or `pip install -e .` from this repo)
- An LLM API key (set `OPENAI_API_KEY` or any LiteLLM-supported provider)
- AxonFlow community stack running (see below)

## Running

```bash
# Start the AxonFlow stack
bash runtime-e2e/_lib/setup-stack.sh

# Run all tests
for test in runtime-e2e/*/test.sh; do
  echo "--- Running $test ---"
  bash "$test" || exit 1
done

# Tear down
bash runtime-e2e/_lib/teardown-stack.sh
```

Or run individual tests:

```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/sync-completion-policy-fires/test.sh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AXONFLOW_ENDPOINT` | `http://localhost:8080` | AxonFlow agent URL |
| `AXONFLOW_CLIENT_ID` | `demo-client` | Client ID for AxonFlow |
| `AXONFLOW_CLIENT_SECRET` | `demo-secret` | Client secret |
| `LLM_API_KEY` | (none) | API key for the LLM provider |
| `LLM_MODEL` | `gpt-4o-mini` | Model to use for test completions |

## Test Structure

Each test folder contains:
- `test.sh` — the executable test script
- `README.md` — what the test asserts, prereqs, how to run

Tests exit 0 on pass, 1 on fail. If prerequisites are missing (no Docker,
no API key, stack not reachable), tests exit 0 with `SKIP:` prefix.
