# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-05-23

### Added

- `AxonFlowLogger` — LiteLLM `CustomLogger` subclass with AxonFlow governance
  - **Governance wrappers**: `completion()` and `acompletion()` — drop-in replacements
    for `litellm.completion()` / `litellm.acompletion()` with policy enforcement
  - **Audit callbacks**: `async_log_success_event` / `async_log_failure_event` —
    automatic audit trail when registered via `litellm.callbacks`
  - Pre-check policy enforcement with deny and require-approval handling
  - HITL (human-in-the-loop) approval flow: create request, poll for decision,
    resume on approve or deny on reject/timeout
  - Per-hook timeout (default 5s) with half-open circuit breaker
  - Fail-open default (AxonFlow outage does not break LLM calls) with explicit
    `fail_open=False` knob for high-stakes workloads
- `AxonFlowLoggerConfig` — configuration dataclass with validation
- `PolicyDeniedError`, `ApprovalRejected`, `ApprovalTimeout` — typed exceptions
- Example: `examples/governed_completion.py` — three scenarios (allow, deny,
  approval-required)
- Uses `axonflow` Python SDK (>=8.2.0) for all AxonFlow API calls
