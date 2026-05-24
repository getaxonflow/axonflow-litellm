# axonflow-litellm

AxonFlow governance integration for [LiteLLM](https://github.com/BerriAI/litellm). Enforce policies, audit LLM calls, and gate high-risk requests behind human approval — all through a drop-in wrapper around `litellm.completion()`.

## Installation

```bash
pip install axonflow-litellm
```

## Quick Start

```python
from axonflow_litellm import AxonFlowLogger, AxonFlowLoggerConfig, PolicyDeniedError

logger = AxonFlowLogger(AxonFlowLoggerConfig(
    endpoint="http://localhost:8080",
    client_id="my-app",
    client_secret="...",
))

try:
    response = logger.completion(
        model="gpt-4o",
        messages=[{"role": "user", "content": "Summarize quarterly earnings"}],
    )
    print(response.choices[0].message.content)
except PolicyDeniedError as e:
    print(f"Blocked: {e.reason}")
```

## How It Works

`AxonFlowLogger` provides two integration modes:

### Governance Mode (recommended)

Use `logger.completion()` or `logger.acompletion()` as drop-in replacements for `litellm.completion()` / `litellm.acompletion()`:

1. **Pre-check** — sends the prompt to AxonFlow for policy evaluation
2. **HITL** — if the policy returns `require_approval`, creates a human-in-the-loop review request and polls until approved, rejected, or timed out
3. **LLM call** — delegates to LiteLLM (all providers supported)
4. **Audit** — records the response to AxonFlow for observability

```python
# Async (recommended for production)
response = await logger.acompletion(
    model="claude-sonnet-4-6",
    messages=[{"role": "user", "content": "..."}],
    user_token="jwt-from-your-auth",
)
```

### Audit-Only Mode

Register as a LiteLLM callback for observability without blocking:

```python
import litellm

litellm.callbacks = [logger]
response = litellm.acompletion(model="gpt-4o", messages=[...])
```

In this mode, every LLM call is recorded to AxonFlow for audit trail. Policy denials are logged as warnings but cannot block the request (a LiteLLM SDK limitation — callback exceptions are silently swallowed).

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `endpoint` | *(required)* | AxonFlow agent URL |
| `client_id` | *(required)* | AxonFlow client identifier |
| `client_secret` | `""` | AxonFlow client secret |
| `default_user_token` | `"anonymous"` | Token for policy evaluation when none provided |
| `tenant_id` | `None` | AxonFlow tenant identifier |
| `fail_open` | `True` | Allow LLM calls when AxonFlow is unreachable |
| `call_timeout_seconds` | `5.0` | Per-hook timeout for AxonFlow API calls |
| `breaker_failure_threshold` | `5` | Consecutive failures before circuit opens |
| `breaker_recovery_seconds` | `30.0` | Wait before attempting recovery probe |
| `enable_hitl_polling` | `True` | Enable HITL approval flow for `require_approval` |
| `approval_poll_interval_seconds` | `2.0` | Polling interval for HITL status |
| `approval_max_wait_seconds` | `300.0` | Maximum wait for HITL decision |
| `extra_context` | `{}` | Additional context sent with every pre-check |

### Fail-Open vs. Fail-Closed

By default, `fail_open=True`: if AxonFlow is unreachable or times out, the LLM call proceeds normally. This ensures an AxonFlow outage does not break your application.

For high-stakes workloads where unapproved LLM calls must never proceed:

```python
config = AxonFlowLoggerConfig(
    endpoint="http://localhost:8080",
    client_id="payments-service",
    client_secret="...",
    fail_open=False,
)
```

## Sync vs. Async

Both `litellm.completion()` (sync) and `litellm.acompletion()` (async) are fully supported.

When registered via `litellm.callbacks`, sync hooks delegate to their async counterparts via `asyncio.run()`. This adds minor overhead (~1ms) per hook call in the sync path. For performance-critical sync workloads, use `logger.completion()` directly (governance wrapper) which amortizes the event loop creation.

If sync hooks are invoked inside a running event loop (unusual — e.g., sync callbacks from an async framework), a one-time `RuntimeWarning` is emitted directing you to `acompletion()`.

### Sync callback mode caveats

In sync callback mode (`litellm.callbacks = [logger]` + `litellm.completion()`), each callback hook creates an ephemeral `asyncio` event loop via `asyncio.run()`. Pre-check (governance) and post-LLM audit both fire and write to AxonFlow. However:

- **Audit write failures are logged at WARNING level** and do not raise to the caller (fail-open by default). If AxonFlow is temporarily unreachable during the audit phase, the LLM response is still returned but the audit row may be missing.
- **Each hook creates a new event loop**, so connection pooling is not shared across hooks within the same LLM call. This is slightly less efficient than the governance wrapper path.

For strict audit guarantees (every LLM call audited, failure = exception), use `logger.completion()` or `logger.acompletion()` instead of the callback registration path.

## Exceptions

| Exception | When |
|-----------|------|
| `PolicyDeniedError` | Policy denied the request |
| `ApprovalRejected` | HITL approval was rejected |
| `ApprovalTimeout` | HITL approval timed out |

All exceptions carry `.reason` (string) and `.policies` (list of policy IDs).

These exceptions do NOT extend `litellm.exceptions.APIError` — catch governance denials via `PolicyDeniedError`, not LiteLLM's exception hierarchy.

## MCP Governance

LiteLLM is LLM-completion-focused. For MCP tool governance, use [AxonFlow's MCP server](https://docs.getaxonflow.com/docs/integration/mcp) directly.

## Requirements

- Python >= 3.10
- `litellm` >= 1.40
- `axonflow` >= 8.2.0

## License

MIT
