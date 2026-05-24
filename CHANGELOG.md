# Changelog

All notable changes to this project will be documented in this file.

## [1.0.3] - 2026-05-24

### Fixed

- **HITL user_id field overflow** — JWT user tokens (>255 chars) caused
  `pq: value too long for type character varying(255)` on HITL queue
  insertion. Fixed: truncate `user_id` to 255 characters.
- **Sync callback audit completeness** — added runtime-e2e test
  (`callback-mode-sync-audit-row-written`) proving that `log_success_event`
  via the sync `asyncio.run()` bridge actually writes a `llm_call_audits`
  row, not just a `gateway_contexts` pre-check row.
- **Unquoted bash heredocs** — Python f-strings inside unquoted `<<PYEOF`
  heredocs were expanded by bash, breaking HITL test scripts.
- **Telemetry leak in CI** — release workflow docker-compose ran without
  `AXONFLOW_TELEMETRY=off`, causing the stack to emit telemetry from
  GitHub Actions runners.

### Added

- 9 new callback-mode runtime-e2e tests (total: 16), all using
  `litellm.callbacks = [logger]` + `litellm.completion()` (the real
  customer pattern), with DB assertions via `psql`:
  - `callback-mode-sync-completion-policy-fires` — pre_check fires on sync
  - `callback-mode-async-completion-policy-fires` — governance wrapper async
  - `callback-mode-sync-completion-deny` — audit-only deny logged
  - `callback-mode-audit-recorded-on-failure` — pre_check fires on LLM error
  - `callback-mode-sync-audit-row-written` — post-LLM audit row verified
  - `callback-mode-sync-completion-hitl-approve` — full HITL create→approve→resume
  - `callback-mode-sync-completion-hitl-reject` — HITL rejection path
  - `callback-mode-sync-completion-hitl-timeout` — HITL client-side timeout
  - `callback-mode-sequential-calls-breaker-stable` — 5 sequential calls
  - `callback-mode-streaming-completion-governed` — streaming completion
- `wait_for_policy_active()` helper with retry loop for policy engine reload
- `hitl_approver.py` background worker for HITL approve/reject automation
- README "Sync callback mode caveats" section documenting audit semantics

### Known limitations

- **HITL reject/timeout tests flaky in sequential runs** — when the HITL
  approve test runs immediately before reject or timeout, the policy engine
  may not reload the new policy within the 15-second retry window. Root
  cause: engine-side reload race after rapid DELETE→CREATE between tests.
  Workaround: run HITL tests individually or add a longer delay between
  policy teardown and creation. Does not affect production use (policies
  are not created/deleted in rapid succession).

### Platform fixes (companion PRs)

- `gateway_handlers.go`: HITL `require_approval` sentinel not set when
  policy also triggers `Blocked` (enterprise PR merged).
- `sensitive-data` category required for HITL policies (detection config
  overrides `security-sqli` to `block`).

## [1.0.2] - 2026-05-24

### Fixed

- **Runtime-e2e silent-skip theater** — 5 of 7 runtime-e2e tests in v1.0.1
  could not fail when the feature was broken: tests accepted any exception
  as success, silently skipped when the stack was unavailable, or passed
  without querying stack state. All tests now query real API/DB state and
  exit non-zero on assertion failure.
- `require_stack` replaces `runtime_e2e_skip_if_unavailable` — tests fail
  loudly when the AxonFlow stack is not reachable instead of silently passing.
- Release workflow now brings up a real AxonFlow docker-compose stack in CI
  and runs all 7 runtime-e2e tests with DB/API assertions against it.
- Wall-time floor sanity check: release fails if runtime-e2e completes in
  under 30 seconds (catch silent skips).

### Changed

- `sync-completion-deny` now creates a deny policy via API, triggers it, and
  asserts `PolicyDeniedError` with the correct class (was: passed if no
  deny policy configured).
- `audit-recorded-on-success` now queries `GET /api/v1/decisions` to verify
  a decision row was recorded (was: no verification).
- `sync-completion-hitl-approve` now verifies the HITL row status in the
  database via `psql` (was: accepted any exception as success).
- `fail-open-on-stack-down` now asserts the specific result type and rejects
  governance exceptions leaking through (was: accepted any non-policy
  exception).

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
