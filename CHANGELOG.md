# Changelog

All notable changes to this project will be documented in this file.

## [1.0.1] - 2026-05-24

### Fixed

- **Sync callback governance bypass** — `log_pre_api_call`, `log_success_event`,
  and `log_failure_event` were silent no-ops in v1.0.0. Sync `litellm.completion()`
  users got no governance and no audit trail. Fixed via `asyncio.run()` bridge:
  sync hooks now delegate to their async counterparts when no event loop is
  running (the common sync LiteLLM pattern). When called inside a running
  event loop, a one-time `RuntimeWarning` directs users to `acompletion()`.
- Ruff lint errors (f-string-without-placeholder, unused imports, import
  ordering, line length) — 15 errors on v1.0.0 main, all resolved.

### Changed

- Release workflow now gates on `ruff check .` (lint job) before build and
  publish. A red lint blocks the release.
- Release workflow now runs runtime-e2e smoke tests (sync + async policy
  enforcement + deny path) before PyPI publish.
- Renamed `ci.yml` → `test.yml` (convention coherence with ADK plugin).

### Added

- `runtime-e2e/` test suite — 7 tests against real LiteLLM + real AxonFlow
  docker-compose stack with zero mocks. Verifies sync/async governance,
  HITL approval, deny, fail-open, fail-closed, and audit recording via
  direct database queries.

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
