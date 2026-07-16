# Copyright 2026 AxonFlow
# SPDX-License-Identifier: MIT

from __future__ import annotations

import asyncio
import sys
from datetime import datetime, timedelta
from typing import Any
from unittest.mock import AsyncMock

import pytest

from axonflow_litellm.config import AxonFlowLoggerConfig
from axonflow_litellm.logger import (
    ApprovalRejected,
    ApprovalTimeout,
    AxonFlowLogger,
    PolicyDeniedError,
    _BreakerState,
    _CircuitBreaker,
    _elapsed_ms,
    _extract_query,
    _extract_summary,
    _infer_provider,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

PolicyApprovalResult = sys.modules["axonflow"].PolicyApprovalResult
HITLApprovalRequest = sys.modules["axonflow"].HITLApprovalRequest


def _denied_result(reason: str = "content violation", policies: list[str] | None = None):
    return PolicyApprovalResult(
        context_id="ctx-denied",
        approved=False,
        block_reason=reason,
        policies=policies or ["pol-1"],
    )


def _approved_result():
    return PolicyApprovalResult(
        context_id="ctx-ok",
        approved=True,
    )


def _require_approval_result():
    return PolicyApprovalResult(
        context_id="ctx-approval",
        approved=False,
        block_reason="require_approval",
        policies=["pol-hitl"],
    )


# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------


class TestConfig:
    def test_valid_config(self, config: AxonFlowLoggerConfig) -> None:
        assert config.endpoint == "http://localhost:8080"
        assert config.client_id == "test-client"

    def test_missing_endpoint(self) -> None:
        with pytest.raises(ValueError, match="endpoint is required"):
            AxonFlowLoggerConfig(endpoint="", client_id="x", client_secret="s")

    def test_missing_client_id(self) -> None:
        with pytest.raises(ValueError, match="client_id is required"):
            AxonFlowLoggerConfig(endpoint="http://x", client_id="", client_secret="s")

    def test_invalid_timeout(self) -> None:
        with pytest.raises(ValueError, match="call_timeout_seconds must be positive"):
            AxonFlowLoggerConfig(
                endpoint="http://x",
                client_id="c",
                client_secret="s",
                call_timeout_seconds=0,
            )

    def test_invalid_breaker_threshold(self) -> None:
        with pytest.raises(ValueError, match="breaker_failure_threshold"):
            AxonFlowLoggerConfig(
                endpoint="http://x",
                client_id="c",
                client_secret="s",
                breaker_failure_threshold=0,
            )


# ---------------------------------------------------------------------------
# Governance: acompletion
# ---------------------------------------------------------------------------


class TestACompletion:
    @pytest.mark.asyncio
    async def test_allow_passthrough(self, config, fake_client, make_response) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "Hello"}],
        )

        assert response is not None
        fake_client.pre_check.assert_awaited_once()
        fake_client.audit_llm_call.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_deny_raises_policy_denied(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_denied_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="content violation") as exc_info:
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "bad query"}],
            )

        assert exc_info.value.policies == ["pol-1"]

    @pytest.mark.asyncio
    async def test_deny_no_block_reason(self, config, fake_client) -> None:
        result = PolicyApprovalResult(
            context_id="ctx-x",
            approved=False,
            block_reason=None,
            policies=[],
        )
        fake_client.pre_check = AsyncMock(return_value=result)

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="denied by policy"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "x"}],
            )

    @pytest.mark.asyncio
    async def test_user_token_forwarded(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
            user_token="jwt-abc",
        )

        call_kwargs = fake_client.pre_check.call_args
        assert call_kwargs.kwargs["user_token"] == "jwt-abc"

    @pytest.mark.asyncio
    async def test_default_user_token(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        call_kwargs = fake_client.pre_check.call_args
        assert call_kwargs.kwargs["user_token"] == "anonymous"

    @pytest.mark.asyncio
    async def test_audit_receives_correct_shape(self, config, fake_client, make_response) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        audit_kwargs = fake_client.audit_llm_call.call_args.kwargs
        assert audit_kwargs["context_id"] == "ctx-ok"
        assert audit_kwargs["model"] == "gpt-4o"
        assert audit_kwargs["provider"] == "openai"
        assert isinstance(audit_kwargs["latency_ms"], int)
        assert audit_kwargs["latency_ms"] >= 0

    @pytest.mark.asyncio
    async def test_extra_context_forwarded(self, fake_client) -> None:
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            extra_context={"env": "staging"},
            tenant_id="t-1",
        )
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        call_kwargs = fake_client.pre_check.call_args.kwargs
        assert call_kwargs["context"]["env"] == "staging"
        assert call_kwargs["context"]["tenant_id"] == "t-1"


# ---------------------------------------------------------------------------
# Governance: sync completion
# ---------------------------------------------------------------------------


class TestSyncCompletion:
    def test_sync_completion_delegates_to_async(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = logger.completion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        assert response is not None
        fake_client.pre_check.assert_awaited_once()

    def test_sync_deny(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_denied_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError):
            logger.completion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "bad"}],
            )


# ---------------------------------------------------------------------------
# HITL approval flow
# ---------------------------------------------------------------------------


class TestHITLFlow:
    @pytest.mark.asyncio
    async def test_approval_approved(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_require_approval_result())
        fake_client.create_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="pending")
        )
        fake_client.get_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="approved")
        )

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "approve me"}],
        )

        assert response is not None
        fake_client.create_hitl_request.assert_awaited_once()
        fake_client.get_hitl_request.assert_awaited()

    @pytest.mark.asyncio
    async def test_approval_rejected(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_require_approval_result())
        fake_client.create_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="pending")
        )
        fake_client.get_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="rejected")
        )

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(ApprovalRejected):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "approve me"}],
            )

    @pytest.mark.asyncio
    async def test_approval_expired(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_require_approval_result())
        fake_client.create_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="pending")
        )
        fake_client.get_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="expired")
        )

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(ApprovalRejected):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "approve me"}],
            )

    @pytest.mark.asyncio
    async def test_approval_create_failure_denies(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_require_approval_result())
        fake_client.create_hitl_request = AsyncMock(side_effect=Exception("server error"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(ApprovalRejected):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "approve me"}],
            )

    @pytest.mark.asyncio
    async def test_hitl_disabled_denies_fast(self, fake_client) -> None:
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            enable_hitl_polling=False,
        )
        fake_client.pre_check = AsyncMock(return_value=_require_approval_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="require_approval"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "approve me"}],
            )

        fake_client.create_hitl_request.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_hitl_poll_transitions_pending_to_approved(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_require_approval_result())
        fake_client.create_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="pending")
        )
        poll_results = [
            HITLApprovalRequest(request_id="hitl-1", status="pending"),
            HITLApprovalRequest(request_id="hitl-1", status="pending"),
            HITLApprovalRequest(request_id="hitl-1", status="approved"),
        ]
        fake_client.get_hitl_request = AsyncMock(side_effect=poll_results)

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "approve me"}],
        )

        assert response is not None
        assert fake_client.get_hitl_request.await_count == 3

    @pytest.mark.asyncio
    async def test_hitl_consecutive_poll_failures_deny(self, fake_client) -> None:
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            breaker_failure_threshold=2,
            approval_poll_interval_seconds=0.05,
            approval_max_wait_seconds=5.0,
        )
        fake_client.pre_check = AsyncMock(return_value=_require_approval_result())
        fake_client.create_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="pending")
        )
        fake_client.get_hitl_request = AsyncMock(side_effect=Exception("poll error"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(ApprovalRejected):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "approve me"}],
            )

        assert fake_client.get_hitl_request.await_count == 2

    @pytest.mark.asyncio
    async def test_approval_timeout_raises_approval_timeout(self, fake_client) -> None:
        """Client-side deadline exceeded raises ApprovalTimeout, not ApprovalRejected."""
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            approval_poll_interval_seconds=0.05,
            approval_max_wait_seconds=0.1,
        )
        fake_client.pre_check = AsyncMock(return_value=_require_approval_result())
        fake_client.create_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="pending")
        )
        fake_client.get_hitl_request = AsyncMock(
            return_value=HITLApprovalRequest(request_id="hitl-1", status="pending")
        )

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(ApprovalTimeout, match="timed out"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "approve me"}],
            )

    @pytest.mark.asyncio
    async def test_require_approval_exact_sentinel(self, config, fake_client) -> None:
        """Substring 'approval' should NOT trigger HITL — exact match only."""
        result = PolicyApprovalResult(
            context_id="ctx-x",
            approved=False,
            block_reason="needs_approval_from_admin",
            policies=["pol-x"],
        )
        fake_client.pre_check = AsyncMock(return_value=result)

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="needs_approval_from_admin"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "x"}],
            )

        fake_client.create_hitl_request.assert_not_awaited()


# ---------------------------------------------------------------------------
# Fail-open / fail-closed
# ---------------------------------------------------------------------------


class TestFailOpen:
    @pytest.mark.asyncio
    async def test_pre_check_error_fail_open(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(side_effect=Exception("connection refused"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        assert response is not None

    @pytest.mark.asyncio
    async def test_pre_check_error_fail_closed_raises(self, fake_client) -> None:
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            fail_open=False,
        )
        fake_client.pre_check = AsyncMock(side_effect=Exception("connection refused"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(Exception, match="connection refused"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "hi"}],
            )

    @pytest.mark.asyncio
    async def test_pre_check_timeout_fail_closed_raises(self, fake_client) -> None:
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            fail_open=False,
            call_timeout_seconds=0.1,
        )

        async def slow_pre_check(**kwargs: Any) -> Any:
            await asyncio.sleep(10)

        fake_client.pre_check = slow_pre_check

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="fail_open=False"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "hi"}],
            )

    @pytest.mark.asyncio
    async def test_pre_check_timeout_fail_open(self, fake_client) -> None:
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            call_timeout_seconds=0.1,
        )

        async def slow_pre_check(**kwargs: Any) -> Any:
            await asyncio.sleep(10)

        fake_client.pre_check = slow_pre_check

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        assert response is not None

    @pytest.mark.asyncio
    async def test_audit_error_does_not_break_response(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())
        fake_client.audit_llm_call = AsyncMock(side_effect=Exception("audit failed"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        assert response is not None


# ---------------------------------------------------------------------------
# Platform rejections fail closed (#2946)
# ---------------------------------------------------------------------------

AuthenticationError = sys.modules["axonflow.exceptions"].AuthenticationError
BudgetExceededError = sys.modules["axonflow.exceptions"].BudgetExceededError
PolicyViolationError = sys.modules["axonflow.exceptions"].PolicyViolationError


class TestPlatformRejectionFailsClosed:
    """A 4xx rejection from AxonFlow must never fail open.

    Pins the live #2946 finding: against an enterprise/evaluation
    deployment, ``default_user_token="anonymous"`` is rejected by
    ``/api/policy/pre-check`` with 401 — and the default ``fail_open=True``
    used to swallow that into an ungoverned LLM call while the platform
    audit trail recorded ``blocked``.
    """

    @pytest.mark.asyncio
    async def test_rejected_default_token_fails_closed_despite_fail_open(
        self, config, fake_client
    ) -> None:
        # The exact enterprise "anonymous" case: pre-check 401s, fail_open=True.
        assert config.fail_open is True
        fake_client.pre_check = AsyncMock(side_effect=AuthenticationError("Invalid credentials"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="rejected"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "hi"}],
            )

    @pytest.mark.asyncio
    async def test_policy_violation_fails_closed_despite_fail_open(
        self, config, fake_client
    ) -> None:
        fake_client.pre_check = AsyncMock(side_effect=PolicyViolationError("Tenant mismatch"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="Tenant mismatch"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "hi"}],
            )

    @pytest.mark.asyncio
    async def test_rejections_do_not_trip_breaker_into_ungoverned(self, fake_client) -> None:
        # Rejections must not count as breaker failures: with threshold=2 an
        # open breaker would skip pre-check entirely and (fail_open=True)
        # resume the silent ungoverned pass-through after two calls.
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            breaker_failure_threshold=2,
        )
        fake_client.pre_check = AsyncMock(side_effect=AuthenticationError("Invalid credentials"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        for _ in range(5):
            with pytest.raises(PolicyDeniedError):
                await logger.acompletion(
                    model="gpt-4o",
                    messages=[{"role": "user", "content": "hi"}],
                )

        # Every call reached the platform — none was skipped by an open breaker.
        assert fake_client.pre_check.await_count == 5

    @pytest.mark.asyncio
    async def test_transport_error_still_fails_open(self, config, fake_client) -> None:
        # The availability contract is unchanged: a transport error under
        # fail_open=True still bypasses governance transparently.
        fake_client.pre_check = AsyncMock(side_effect=Exception("connection refused"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        assert response is not None

    @pytest.mark.asyncio
    async def test_callback_mode_rejection_is_swallowed(self, config, fake_client) -> None:
        # Audit-only callback mode cannot block by design (LiteLLM swallows
        # callback exceptions) — the rejection must not escape the hook, and
        # no context id is recorded.
        fake_client.pre_check = AsyncMock(side_effect=AuthenticationError("Invalid credentials"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        kwargs: dict[str, Any] = {}
        await logger.async_log_pre_api_call("gpt-4o", [{"role": "user", "content": "hi"}], kwargs)

        assert "_axonflow_context_id" not in kwargs

    @pytest.mark.asyncio
    async def test_budget_block_fails_closed_despite_fail_open(self, config, fake_client) -> None:
        # 402 is a deliberate block verdict on the same endpoint (the platform
        # writes a `blocked` audit row) — it must fail closed exactly like
        # 401/403, not be swallowed as degradation.
        fake_client.pre_check = AsyncMock(side_effect=BudgetExceededError("Budget exceeded"))

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="Budget exceeded"):
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "hi"}],
            )

    @pytest.mark.asyncio
    async def test_rejection_with_fail_closed_raises_policy_denied_with_cause(
        self, fake_client
    ) -> None:
        # Under fail_open=False a rejection raises the normalized
        # PolicyDeniedError (not the raw SDK error), with the original
        # exception chained as __cause__.
        config = AxonFlowLoggerConfig(
            endpoint="http://localhost:8080",
            client_id="c",
            client_secret="s",
            fail_open=False,
        )
        original = AuthenticationError("Invalid credentials")
        fake_client.pre_check = AsyncMock(side_effect=original)

        logger = AxonFlowLogger.from_client(fake_client, config)
        with pytest.raises(PolicyDeniedError, match="rejected") as exc_info:
            await logger.acompletion(
                model="gpt-4o",
                messages=[{"role": "user", "content": "hi"}],
            )

        assert exc_info.value.__cause__ is original

    @pytest.mark.asyncio
    async def test_audit_auth_error_does_not_discard_response(self, config, fake_client) -> None:
        # reject_closed applies to the pre-check gate only: a 401 from the
        # post-LLM audit call must never discard the already-obtained response.
        fake_client.pre_check = AsyncMock(return_value=_approved_result())
        fake_client.audit_llm_call = AsyncMock(
            side_effect=AuthenticationError("Invalid credentials")
        )

        logger = AxonFlowLogger.from_client(fake_client, config)
        response = await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "hi"}],
        )

        assert response is not None


# ---------------------------------------------------------------------------
# Circuit breaker
# ---------------------------------------------------------------------------


class TestCircuitBreaker:
    @pytest.mark.asyncio
    async def test_breaker_opens_after_threshold(self) -> None:
        breaker = _CircuitBreaker(failure_threshold=3, recovery_seconds=10.0)

        for _ in range(3):
            assert await breaker.acquire() is True
            await breaker.record_failure()

        assert breaker._state is _BreakerState.OPEN
        assert await breaker.acquire() is False

    @pytest.mark.asyncio
    async def test_breaker_recovers_after_window(self) -> None:
        breaker = _CircuitBreaker(failure_threshold=2, recovery_seconds=0.1)

        for _ in range(2):
            await breaker.acquire()
            await breaker.record_failure()

        assert breaker._state is _BreakerState.OPEN
        await asyncio.sleep(0.15)

        assert await breaker.acquire() is True
        assert breaker._state is _BreakerState.HALF_OPEN

    @pytest.mark.asyncio
    async def test_breaker_half_open_one_probe(self) -> None:
        breaker = _CircuitBreaker(failure_threshold=1, recovery_seconds=0.05)

        await breaker.acquire()
        await breaker.record_failure()

        await asyncio.sleep(0.1)

        assert await breaker.acquire() is True
        assert await breaker.acquire() is False

    @pytest.mark.asyncio
    async def test_breaker_half_open_success_closes(self) -> None:
        breaker = _CircuitBreaker(failure_threshold=1, recovery_seconds=0.05)

        await breaker.acquire()
        await breaker.record_failure()

        await asyncio.sleep(0.1)

        await breaker.acquire()
        await breaker.record_success()

        assert breaker._state is _BreakerState.CLOSED
        assert await breaker.acquire() is True

    @pytest.mark.asyncio
    async def test_breaker_half_open_failure_reopens(self) -> None:
        breaker = _CircuitBreaker(failure_threshold=1, recovery_seconds=0.05)

        await breaker.acquire()
        await breaker.record_failure()

        await asyncio.sleep(0.1)

        await breaker.acquire()
        await breaker.record_failure()

        assert breaker._state is _BreakerState.OPEN

    @pytest.mark.asyncio
    async def test_breaker_skips_during_open(self, config, fake_client) -> None:
        config.breaker_failure_threshold = 1
        fake_client.pre_check = AsyncMock(side_effect=Exception("fail"))

        logger = AxonFlowLogger.from_client(fake_client, config)

        await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "1"}],
        )

        assert fake_client.pre_check.await_count == 1

        await logger.acompletion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "2"}],
        )

        assert fake_client.pre_check.await_count == 1


# ---------------------------------------------------------------------------
# Callback hooks (audit-only mode)
# ---------------------------------------------------------------------------


class TestCallbackHooks:
    @pytest.mark.asyncio
    async def test_async_log_pre_api_call_does_pre_check(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        kwargs: dict[str, Any] = {"litellm_params": {"metadata": {}}}

        await logger.async_log_pre_api_call("gpt-4o", [{"role": "user", "content": "hi"}], kwargs)

        assert kwargs.get("_axonflow_context_id") == "ctx-ok"

    @pytest.mark.asyncio
    async def test_async_log_pre_api_call_skips_governed(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        kwargs: dict[str, Any] = {
            "litellm_params": {"metadata": {"_axonflow_governed": True}},
        }

        await logger.async_log_pre_api_call("gpt-4o", [{"role": "user", "content": "hi"}], kwargs)

        fake_client.pre_check.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_async_log_success_event_audits(self, config, fake_client, make_response) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())
        fake_client.audit_llm_call = AsyncMock()

        logger = AxonFlowLogger.from_client(fake_client, config)

        kwargs: dict[str, Any] = {
            "litellm_params": {"metadata": {}},
            "model": "gpt-4o",
        }
        await logger.async_log_pre_api_call("gpt-4o", [{"role": "user", "content": "hi"}], kwargs)

        now = datetime.now()
        await logger.async_log_success_event(
            kwargs, make_response(), now - timedelta(seconds=1), now
        )

        fake_client.audit_llm_call.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_async_log_success_skips_without_context_id(
        self, config, fake_client, make_response
    ) -> None:
        logger = AxonFlowLogger.from_client(fake_client, config)

        kwargs: dict[str, Any] = {"litellm_params": {"metadata": {}}, "model": "gpt-4o"}
        now = datetime.now()
        await logger.async_log_success_event(kwargs, make_response(), now, now)

        fake_client.audit_llm_call.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_async_log_failure_event_audits(self, config, fake_client) -> None:
        fake_client.pre_check = AsyncMock(return_value=_approved_result())
        fake_client.audit_llm_call = AsyncMock()

        logger = AxonFlowLogger.from_client(fake_client, config)

        kwargs: dict[str, Any] = {
            "litellm_params": {"metadata": {}},
            "model": "gpt-4o",
        }
        await logger.async_log_pre_api_call("gpt-4o", [{"role": "user", "content": "hi"}], kwargs)

        error = Exception("LLM provider error")
        now = datetime.now()
        await logger.async_log_failure_event(kwargs, error, now - timedelta(seconds=2), now)

        fake_client.audit_llm_call.assert_awaited_once()
        audit_kwargs = fake_client.audit_llm_call.call_args.kwargs
        assert "[ERROR]" in audit_kwargs["response_summary"]

    def test_sync_log_pre_api_call_invokes_pre_check(self, config, fake_client) -> None:
        """Sync hook fires governance via asyncio.run — NOT a no-op."""
        fake_client.pre_check = AsyncMock(return_value=_approved_result())

        logger = AxonFlowLogger.from_client(fake_client, config)
        kwargs: dict[str, Any] = {"litellm_params": {"metadata": {}}}

        logger.log_pre_api_call("gpt-4o", [{"role": "user", "content": "hi"}], kwargs)

        fake_client.pre_check.assert_awaited_once()
        assert kwargs.get("_axonflow_context_id") == "ctx-ok"

    def test_sync_log_success_event_audits(self, config, fake_client, make_response) -> None:
        """Sync success hook fires audit via asyncio.run."""
        fake_client.pre_check = AsyncMock(return_value=_approved_result())
        fake_client.audit_llm_call = AsyncMock()

        logger = AxonFlowLogger.from_client(fake_client, config)

        kwargs: dict[str, Any] = {
            "litellm_params": {"metadata": {}},
            "model": "gpt-4o",
        }
        logger.log_pre_api_call("gpt-4o", [{"role": "user", "content": "hi"}], kwargs)

        now = datetime.now()
        logger.log_success_event(kwargs, make_response(), now - timedelta(seconds=1), now)

        fake_client.audit_llm_call.assert_awaited_once()


# ---------------------------------------------------------------------------
# from_client ownership
# ---------------------------------------------------------------------------


class TestClientOwnership:
    @pytest.mark.asyncio
    async def test_from_client_does_not_close(self, config, fake_client) -> None:
        logger = AxonFlowLogger.from_client(fake_client, config)
        await logger.aclose()
        assert logger._client is None or not logger._owns_client

    @pytest.mark.asyncio
    async def test_owned_client_is_closed(self, config) -> None:
        logger = AxonFlowLogger(config)
        await logger._get_client()
        await logger.aclose()
        assert logger._client is None


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------


class TestHelpers:
    def test_extract_query_last_user_message(self) -> None:
        messages = [
            {"role": "system", "content": "You are helpful."},
            {"role": "user", "content": "What is AI?"},
        ]
        assert _extract_query(messages) == "What is AI?"

    def test_extract_query_multimodal(self) -> None:
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Describe this image"},
                    {"type": "image_url", "image_url": {"url": "..."}},
                ],
            }
        ]
        assert _extract_query(messages) == "Describe this image"

    def test_extract_query_empty(self) -> None:
        assert _extract_query([]) == ""
        assert _extract_query(None) == ""

    def test_extract_query_truncates(self) -> None:
        messages = [{"role": "user", "content": "x" * 5000}]
        assert len(_extract_query(messages)) == 4000

    def test_infer_provider(self) -> None:
        assert _infer_provider("gpt-4o") == "openai"
        assert _infer_provider("claude-sonnet-4-6") == "anthropic"
        assert _infer_provider("gemini-2.0-flash") == "google"
        assert _infer_provider("o1-mini") == "openai"
        assert _infer_provider("command-r-plus") == "cohere"
        assert _infer_provider("unknown-model") == "unknown"

    def test_extract_summary(self, make_response) -> None:
        resp = make_response(content="Test response here")
        assert _extract_summary(resp) == "Test response here"

    def test_extract_summary_empty(self) -> None:
        assert _extract_summary(None) == ""
        assert _extract_summary(object()) == ""

    def test_elapsed_ms(self) -> None:
        start = datetime(2026, 1, 1, 0, 0, 0)
        end = datetime(2026, 1, 1, 0, 0, 1, 500000)
        assert _elapsed_ms(start, end) == 1500

    def test_elapsed_ms_bad_input(self) -> None:
        assert _elapsed_ms(None, None) == 0
