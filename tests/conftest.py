# Copyright 2026 AxonFlow
# SPDX-License-Identifier: MIT

"""Test stubs so tests run without litellm or axonflow installed."""

from __future__ import annotations

import sys
import types
from dataclasses import dataclass, field
from typing import Any
from unittest.mock import AsyncMock

# ---------------------------------------------------------------------------
# litellm stub
# ---------------------------------------------------------------------------


def _install_litellm_stub() -> None:
    if "litellm" in sys.modules:
        return

    litellm_mod = types.ModuleType("litellm")
    litellm_mod.callbacks = []  # type: ignore[attr-defined]

    async def _acompletion(**kwargs: Any) -> Any:
        return _make_response()

    def _completion(**kwargs: Any) -> Any:
        return _make_response()

    litellm_mod.acompletion = _acompletion  # type: ignore[attr-defined]
    litellm_mod.completion = _completion  # type: ignore[attr-defined]

    class _ContentPolicyViolationError(Exception):
        pass

    litellm_mod.ContentPolicyViolationError = _ContentPolicyViolationError  # type: ignore[attr-defined]

    integrations_mod = types.ModuleType("litellm.integrations")
    custom_logger_mod = types.ModuleType("litellm.integrations.custom_logger")

    class CustomLogger:
        def __init__(self) -> None:
            pass

        def log_pre_api_call(self, model: str, messages: Any, kwargs: dict) -> None:
            pass

        async def async_log_pre_api_call(self, model: str, messages: Any, kwargs: dict) -> None:
            pass

        def log_post_api_call(
            self,
            kwargs: dict,
            response_obj: Any,
            start_time: Any,
            end_time: Any,
        ) -> None:
            pass

        def log_success_event(
            self,
            kwargs: dict,
            response_obj: Any,
            start_time: Any,
            end_time: Any,
        ) -> None:
            pass

        async def async_log_success_event(
            self,
            kwargs: dict,
            response_obj: Any,
            start_time: Any,
            end_time: Any,
        ) -> None:
            pass

        def log_failure_event(
            self,
            kwargs: dict,
            response_obj: Any,
            start_time: Any,
            end_time: Any,
        ) -> None:
            pass

        async def async_log_failure_event(
            self,
            kwargs: dict,
            response_obj: Any,
            start_time: Any,
            end_time: Any,
        ) -> None:
            pass

    custom_logger_mod.CustomLogger = CustomLogger  # type: ignore[attr-defined]
    integrations_mod.custom_logger = custom_logger_mod  # type: ignore[attr-defined]

    sys.modules["litellm"] = litellm_mod
    sys.modules["litellm.integrations"] = integrations_mod
    sys.modules["litellm.integrations.custom_logger"] = custom_logger_mod


# ---------------------------------------------------------------------------
# axonflow stub
# ---------------------------------------------------------------------------


def _install_axonflow_stub() -> None:
    if "axonflow" in sys.modules:
        return

    axonflow_mod = types.ModuleType("axonflow")
    hitl_mod = types.ModuleType("axonflow.hitl")
    types_mod = types.ModuleType("axonflow.types")

    @dataclass
    class TokenUsage:
        prompt_tokens: int = 0
        completion_tokens: int = 0
        total_tokens: int = 0

    @dataclass
    class PolicyApprovalResult:
        context_id: str = ""
        approved: bool = True
        block_reason: str | None = None
        policies: list[str] | None = None
        requires_redaction: bool = False
        approved_data: dict[str, Any] = field(default_factory=dict)

    @dataclass
    class AuditResult:
        success: bool = True

    @dataclass
    class HITLCreateInput:
        client_id: str = ""
        original_query: str = ""
        request_type: str = ""
        user_id: str | None = None
        request_context: dict[str, Any] | None = None
        triggered_policy_id: str | None = None
        triggered_policy_name: str | None = None
        trigger_reason: str | None = None
        severity: str | None = None

    @dataclass
    class HITLApprovalRequest:
        request_id: str = ""
        status: str = "pending"
        org_id: str = ""
        tenant_id: str = ""
        client_id: str = ""
        original_query: str = ""
        request_type: str = ""
        triggered_policy_id: str = ""
        triggered_policy_name: str = ""
        trigger_reason: str = ""
        severity: str = ""
        expires_at: str = ""
        created_at: str = ""
        updated_at: str = ""

    class AxonFlow:
        def __init__(self, **kwargs: Any) -> None:
            self.pre_check = AsyncMock(return_value=PolicyApprovalResult())
            self.audit_llm_call = AsyncMock(return_value=AuditResult())
            self.create_hitl_request = AsyncMock(
                return_value=HITLApprovalRequest(request_id="hitl-123")
            )
            self.get_hitl_request = AsyncMock(
                return_value=HITLApprovalRequest(request_id="hitl-123", status="approved")
            )

    axonflow_mod.AxonFlow = AxonFlow  # type: ignore[attr-defined]
    axonflow_mod.TokenUsage = TokenUsage  # type: ignore[attr-defined]
    axonflow_mod.PolicyApprovalResult = PolicyApprovalResult  # type: ignore[attr-defined]
    axonflow_mod.AuditResult = AuditResult  # type: ignore[attr-defined]
    axonflow_mod.HITLApprovalRequest = HITLApprovalRequest  # type: ignore[attr-defined]

    hitl_mod.HITLCreateInput = HITLCreateInput  # type: ignore[attr-defined]
    hitl_mod.HITLApprovalRequest = HITLApprovalRequest  # type: ignore[attr-defined]

    types_mod.TokenUsage = TokenUsage  # type: ignore[attr-defined]
    types_mod.PolicyApprovalResult = PolicyApprovalResult  # type: ignore[attr-defined]
    types_mod.AuditResult = AuditResult  # type: ignore[attr-defined]

    sys.modules["axonflow"] = axonflow_mod
    sys.modules["axonflow.hitl"] = hitl_mod
    sys.modules["axonflow.types"] = types_mod


# ---------------------------------------------------------------------------
# Install stubs before any test module imports axonflow_litellm
# ---------------------------------------------------------------------------

_install_litellm_stub()
_install_axonflow_stub()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_response(
    content: str = "Hello, world!",
    prompt_tokens: int = 10,
    completion_tokens: int = 5,
) -> Any:
    @dataclass
    class _Usage:
        prompt_tokens: int = 0
        completion_tokens: int = 0
        total_tokens: int = 0

    @dataclass
    class _Message:
        content: str = ""
        role: str = "assistant"

    @dataclass
    class _Choice:
        message: _Message = field(default_factory=_Message)
        index: int = 0
        finish_reason: str = "stop"

    @dataclass
    class _Response:
        choices: list[_Choice] = field(default_factory=list)
        usage: _Usage = field(default_factory=_Usage)
        model: str = "gpt-4o"

    return _Response(
        choices=[_Choice(message=_Message(content=content))],
        usage=_Usage(
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=prompt_tokens + completion_tokens,
        ),
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

import pytest  # noqa: E402

from axonflow_litellm.config import AxonFlowLoggerConfig  # noqa: E402


@pytest.fixture
def config() -> AxonFlowLoggerConfig:
    return AxonFlowLoggerConfig(
        endpoint="http://localhost:8080",
        client_id="test-client",
        client_secret="test-secret",
        call_timeout_seconds=2.0,
        breaker_failure_threshold=3,
        breaker_recovery_seconds=1.0,
        approval_poll_interval_seconds=0.1,
        approval_max_wait_seconds=2.0,
    )


@pytest.fixture
def fake_client() -> Any:
    return sys.modules["axonflow"].AxonFlow()


@pytest.fixture
def make_response():
    return _make_response
