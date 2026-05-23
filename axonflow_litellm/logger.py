# Copyright 2026 AxonFlow
# SPDX-License-Identifier: MIT

from __future__ import annotations

import asyncio
import logging
import time
import warnings
from enum import Enum
from typing import Any

from litellm.integrations.custom_logger import CustomLogger

from axonflow_litellm.config import AxonFlowLoggerConfig

_log = logging.getLogger("axonflow_litellm")

_METADATA_CONTEXT_ID = "_axonflow_context_id"
_METADATA_GOVERNED = "_axonflow_governed"
_KWARGS_CONTEXT_ID = "_axonflow_context_id"


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class PolicyDeniedError(Exception):
    """Raised when an AxonFlow policy denies the LLM call."""

    def __init__(self, reason: str, *, policies: list[str] | None = None) -> None:
        self.reason = reason
        self.policies = policies or []
        super().__init__(reason)


class ApprovalRejected(PolicyDeniedError):
    """Raised when a HITL approval request is rejected."""


class ApprovalTimeout(PolicyDeniedError):
    """Raised when a HITL approval request times out waiting for a decision."""


# ---------------------------------------------------------------------------
# Circuit breaker
# ---------------------------------------------------------------------------


class _BreakerState(Enum):
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"


class _CircuitBreaker:
    """Half-open circuit breaker.

    HALF_OPEN admits exactly one probe at a time — concurrent hook
    invocations during recovery return False immediately (no thundering
    herd onto a still-recovering AxonFlow).
    """

    def __init__(self, failure_threshold: int, recovery_seconds: float) -> None:
        self._failure_threshold = failure_threshold
        self._recovery_seconds = recovery_seconds
        self._state = _BreakerState.CLOSED
        self._consecutive_failures = 0
        self._opened_at = 0.0
        self._lock = asyncio.Lock()
        self._probe_in_flight = False

    async def acquire(self) -> bool:
        async with self._lock:
            if self._state is _BreakerState.CLOSED:
                return True
            if self._state is _BreakerState.OPEN:
                if (time.monotonic() - self._opened_at) >= self._recovery_seconds:
                    self._state = _BreakerState.HALF_OPEN
                    self._probe_in_flight = True
                    return True
                return False
            if self._probe_in_flight:
                return False
            self._probe_in_flight = True
            return True

    async def record_success(self) -> None:
        async with self._lock:
            self._state = _BreakerState.CLOSED
            self._consecutive_failures = 0
            self._opened_at = 0.0
            self._probe_in_flight = False

    async def record_failure(self) -> None:
        async with self._lock:
            self._consecutive_failures += 1
            if self._consecutive_failures >= self._failure_threshold:
                self._state = _BreakerState.OPEN
                self._opened_at = time.monotonic()
            self._probe_in_flight = False


# ---------------------------------------------------------------------------
# AxonFlowLogger
# ---------------------------------------------------------------------------


class AxonFlowLogger(CustomLogger):
    """AxonFlow governance and audit for LiteLLM.

    Two usage modes:

    **Governance** (recommended) — use ``completion()`` or ``acompletion()``
    as drop-in replacements for ``litellm.completion()`` /
    ``litellm.acompletion()``.  These enforce AxonFlow policies before the
    LLM call and audit the result afterwards.

    **Audit-only** — register as a LiteLLM callback via
    ``litellm.callbacks = [logger]``.  The logger records every LLM call
    to AxonFlow for observability, but cannot block denied requests (a
    LiteLLM SDK limitation — callback exceptions are silently swallowed).
    """

    def __init__(
        self,
        config: AxonFlowLoggerConfig,
    ) -> None:
        super().__init__()
        self._config = config
        self._client: Any = None
        self._client_lock = asyncio.Lock()
        self._owns_client = True
        self._breaker = _CircuitBreaker(
            failure_threshold=config.breaker_failure_threshold,
            recovery_seconds=config.breaker_recovery_seconds,
        )
        self._sync_warned = False

    @classmethod
    def from_client(
        cls,
        client: Any,
        config: AxonFlowLoggerConfig,
    ) -> AxonFlowLogger:
        """Build a logger that reuses an existing ``AxonFlow`` client.

        The caller owns the client lifecycle — ``aclose()`` is a no-op.
        """
        inst = cls(config)
        inst._client = client
        inst._owns_client = False
        return inst

    # ----- Lifecycle -------------------------------------------------------

    async def aclose(self) -> None:
        if not self._owns_client:
            return
        async with self._client_lock:
            client = self._client
            if client is None:
                return
            self._client = None
        close = getattr(client, "close", None)
        if close is None:
            return
        try:
            result = close()
            if asyncio.iscoroutine(result):
                await result
        except Exception:
            _log.warning("AxonFlow client close failed", exc_info=True)

    async def __aenter__(self) -> AxonFlowLogger:
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        await self.aclose()

    # ----- Client management -----------------------------------------------

    async def _get_client(self) -> Any:
        if self._client is not None:
            return self._client
        async with self._client_lock:
            if self._client is None:
                from axonflow import AxonFlow

                self._client = AxonFlow(
                    endpoint=self._config.endpoint,
                    client_id=self._config.client_id,
                    client_secret=self._config.client_secret,
                    timeout=self._config.call_timeout_seconds,
                )
            return self._client

    # ----- Guard wrapper ---------------------------------------------------

    async def _call_with_guard(
        self,
        op_name: str,
        coro_factory: Any,
        *,
        fail_open: bool = True,
    ) -> Any:
        """Run ``coro_factory()`` with timeout + circuit breaker.

        Uses a 0-arg async callable so we can short-circuit without ever
        scheduling the underlying coroutine when the breaker is open.

        The breaker probe slot is always released even on
        ``asyncio.CancelledError`` (``BaseException`` subclass), preventing
        a permanent slot leak that would disable the breaker.
        """
        if not await self._breaker.acquire():
            _log.debug("axonflow.%s skipped: circuit open", op_name)
            if not fail_open:
                raise PolicyDeniedError(
                    "AxonFlow unreachable (circuit open) — fail_open=False"
                )
            return None
        outcome = "failure"
        try:
            try:
                result = await asyncio.wait_for(
                    coro_factory(),
                    timeout=self._config.call_timeout_seconds,
                )
                outcome = "success"
                return result
            except asyncio.TimeoutError:
                _log.warning(
                    "axonflow.%s timed out after %.1fs; %s",
                    op_name,
                    self._config.call_timeout_seconds,
                    "failing open" if fail_open else "failing closed",
                )
                if not fail_open:
                    raise PolicyDeniedError(
                        "AxonFlow timed out — fail_open=False"
                    )
                return None
            except Exception as exc:
                _log.warning(
                    "axonflow.%s failed: %s; %s",
                    op_name,
                    exc,
                    "failing open" if fail_open else "failing closed",
                )
                if not fail_open:
                    raise
                return None
        finally:
            if outcome == "success":
                await asyncio.shield(self._breaker.record_success())
            else:
                await asyncio.shield(self._breaker.record_failure())

    # ----- Governance wrappers ---------------------------------------------

    async def acompletion(
        self,
        *,
        user_token: str | None = None,
        **kwargs: Any,
    ) -> Any:
        """Governed async LiteLLM completion with AxonFlow policy enforcement.

        Drop-in replacement for ``litellm.acompletion()``.  Runs pre-check,
        handles HITL approval flow when required, delegates to LiteLLM, and
        audits the result.

        Args:
            user_token: AxonFlow user token for policy evaluation.  Defaults
                to ``config.default_user_token``.
            **kwargs: Forwarded verbatim to ``litellm.acompletion()``.

        Raises:
            PolicyDeniedError: Policy denied the request.
            ApprovalRejected: HITL approval was rejected.
            ApprovalTimeout: HITL approval timed out.
        """
        import litellm

        model = kwargs.get("model", "unknown")
        messages = kwargs.get("messages", [])
        token = user_token or self._config.default_user_token
        query = _extract_query(messages)

        context: dict[str, Any] = {**self._config.extra_context}
        if self._config.tenant_id:
            context["tenant_id"] = self._config.tenant_id

        pre_check_result = await self._call_with_guard(
            "pre_check",
            lambda: self._do_pre_check(token, query, context),
            fail_open=self._config.fail_open,
        )

        if pre_check_result is not None and not pre_check_result.approved:
            block_reason = pre_check_result.block_reason or "denied by policy"
            policies = pre_check_result.policies

            if block_reason == "require_approval" and self._config.enable_hitl_polling:
                hitl_result = await self._hitl_flow(
                    pre_check_result, model, query, token
                )
                if hitl_result == "timeout":
                    raise ApprovalTimeout(
                        "Approval request timed out",
                        policies=policies,
                    )
                if hitl_result != "approved":
                    raise ApprovalRejected(
                        "Approval request was rejected",
                        policies=policies,
                    )
            else:
                raise PolicyDeniedError(block_reason, policies=policies)

        context_id = (
            pre_check_result.context_id if pre_check_result else None
        )

        metadata = kwargs.get("metadata") or {}
        if context_id:
            metadata[_METADATA_CONTEXT_ID] = context_id
        metadata[_METADATA_GOVERNED] = True
        kwargs["metadata"] = metadata

        start = time.monotonic()
        response = await litellm.acompletion(**kwargs)
        latency_ms = int((time.monotonic() - start) * 1000)

        if context_id:
            await self._call_with_guard(
                "audit",
                lambda: self._do_audit(
                    context_id, response, model, latency_ms
                ),
            )

        return response

    def completion(
        self,
        *,
        user_token: str | None = None,
        **kwargs: Any,
    ) -> Any:
        """Governed sync LiteLLM completion with AxonFlow policy enforcement.

        Drop-in replacement for ``litellm.completion()``.  Use
        ``acompletion()`` in async contexts.
        """
        return asyncio.run(
            self.acompletion(user_token=user_token, **kwargs)
        )

    # ----- CustomLogger hooks (audit-only callback mode) -------------------

    async def async_log_pre_api_call(
        self, model: str, messages: Any, kwargs: dict[str, Any]
    ) -> None:
        metadata = (kwargs.get("litellm_params") or {}).get("metadata") or {}
        if metadata.get(_METADATA_GOVERNED):
            return

        token = self._config.default_user_token
        query = _extract_query(messages)
        context: dict[str, Any] = {**self._config.extra_context}
        if self._config.tenant_id:
            context["tenant_id"] = self._config.tenant_id

        try:
            result = await self._call_with_guard(
                "pre_check_audit",
                lambda: self._do_pre_check(token, query, context),
            )
            if result and result.context_id:
                kwargs[_KWARGS_CONTEXT_ID] = result.context_id
                if not result.approved:
                    _log.warning(
                        "AxonFlow policy denied (audit-only mode, not blocking): %s",
                        result.block_reason,
                    )
        except Exception:
            pass

    def log_pre_api_call(
        self, model: str, messages: Any, kwargs: dict[str, Any]
    ) -> None:
        self._run_sync_hook(
            self.async_log_pre_api_call(model, messages, kwargs)
        )

    async def async_log_success_event(
        self,
        kwargs: dict[str, Any],
        response_obj: Any,
        start_time: Any,
        end_time: Any,
    ) -> None:
        context_id = self._resolve_context_id(kwargs)
        if not context_id:
            return

        model = kwargs.get("model", "unknown")
        latency_ms = _elapsed_ms(start_time, end_time)

        await self._call_with_guard(
            "audit_success",
            lambda: self._do_audit(context_id, response_obj, model, latency_ms),
        )

    def log_success_event(
        self,
        kwargs: dict[str, Any],
        response_obj: Any,
        start_time: Any,
        end_time: Any,
    ) -> None:
        self._run_sync_hook(
            self.async_log_success_event(
                kwargs, response_obj, start_time, end_time
            )
        )

    async def async_log_failure_event(
        self,
        kwargs: dict[str, Any],
        response_obj: Any,
        start_time: Any,
        end_time: Any,
    ) -> None:
        context_id = self._resolve_context_id(kwargs)
        if not context_id:
            return

        model = kwargs.get("model", "unknown")
        latency_ms = _elapsed_ms(start_time, end_time)
        error_msg = ""
        if isinstance(response_obj, Exception):
            error_msg = str(response_obj)[:2000]

        await self._call_with_guard(
            "audit_failure",
            lambda: self._do_audit(
                context_id,
                response_obj,
                model,
                latency_ms,
                error=error_msg,
            ),
        )

    def log_failure_event(
        self,
        kwargs: dict[str, Any],
        response_obj: Any,
        start_time: Any,
        end_time: Any,
    ) -> None:
        self._run_sync_hook(
            self.async_log_failure_event(
                kwargs, response_obj, start_time, end_time
            )
        )

    # ----- Internal: sync hook bridge ----------------------------------------

    def _run_sync_hook(self, coro: Any) -> None:
        """Run an async hook coroutine from a sync context.

        When no event loop is running (the common ``litellm.completion()``
        path), delegates to ``asyncio.run()``.  When an event loop IS
        running (async caller using sync hooks — unusual), emits a
        one-time warning and skips the hook to avoid deadlock.
        """
        try:
            asyncio.get_running_loop()
        except RuntimeError:
            try:
                asyncio.run(coro)
            except Exception:
                _log.debug("Sync hook failed (non-blocking)", exc_info=True)
            return

        if not self._sync_warned:
            self._sync_warned = True
            warnings.warn(
                "axonflow-litellm: sync callback hooks invoked inside a "
                "running event loop — governance skipped for this call. "
                "Use logger.acompletion() or litellm.acompletion() for "
                "async contexts.",
                RuntimeWarning,
                stacklevel=3,
            )
        coro.close()

    # ----- Internal: pre-check + audit -------------------------------------

    async def _do_pre_check(
        self, user_token: str, query: str, context: dict[str, Any]
    ) -> Any:
        client = await self._get_client()
        return await client.pre_check(
            user_token=user_token,
            query=query,
            context=context if context else None,
        )

    async def _do_audit(
        self,
        context_id: str,
        response: Any,
        model: str,
        latency_ms: int,
        *,
        error: str = "",
    ) -> None:
        client = await self._get_client()
        from axonflow import TokenUsage

        usage = getattr(response, "usage", None)
        token_usage = TokenUsage(
            prompt_tokens=getattr(usage, "prompt_tokens", 0) or 0,
            completion_tokens=getattr(usage, "completion_tokens", 0) or 0,
            total_tokens=getattr(usage, "total_tokens", 0) or 0,
        )

        summary = _extract_summary(response)
        if error:
            summary = f"[ERROR] {error}" if not summary else f"{summary}\n[ERROR] {error}"

        await client.audit_llm_call(
            context_id=context_id,
            response_summary=summary[:2000],
            provider=_infer_provider(model),
            model=str(model),
            token_usage=token_usage,
            latency_ms=latency_ms,
        )

    # ----- Internal: HITL --------------------------------------------------

    async def _hitl_flow(
        self,
        pre_check_result: Any,
        model: str,
        query: str,
        user_token: str,
    ) -> str:
        """4-step HITL flow: create row -> poll -> resume/deny.

        Returns ``"approved"``, ``"rejected"``, or ``"timeout"``.  Uses a
        local consecutive-failure counter for polling (not the shared
        breaker) so a broken polling endpoint does not trip the breaker
        open for all other governance calls.
        """
        policies = pre_check_result.policies or []
        first_policy = policies[0] if policies else None

        try:
            created = await self._call_with_guard(
                "create_hitl",
                lambda: self._do_create_hitl(
                    query=query,
                    user_token=user_token,
                    model=model,
                    first_policy=first_policy,
                    block_reason=pre_check_result.block_reason,
                ),
                fail_open=False,
            )
        except Exception:
            return "rejected"

        if created is None:
            return "rejected"

        request_id = created.request_id
        deadline = time.monotonic() + self._config.approval_max_wait_seconds
        consecutive_failures = 0

        while time.monotonic() < deadline:
            await asyncio.sleep(self._config.approval_poll_interval_seconds)

            try:
                client = await self._get_client()
                req = await asyncio.wait_for(
                    client.get_hitl_request(request_id),
                    timeout=self._config.call_timeout_seconds,
                )
                consecutive_failures = 0

                if req.status == "approved":
                    return "approved"
                if req.status in ("rejected", "expired"):
                    return "rejected"
            except asyncio.CancelledError:
                raise
            except Exception:
                consecutive_failures += 1
                if consecutive_failures >= self._config.breaker_failure_threshold:
                    _log.warning(
                        "HITL polling failed %d times consecutively; denying",
                        consecutive_failures,
                    )
                    return "rejected"

        _log.warning(
            "HITL approval timed out after %.0fs",
            self._config.approval_max_wait_seconds,
        )
        return "timeout"

    async def _do_create_hitl(
        self,
        *,
        query: str,
        user_token: str,
        model: str,
        first_policy: str | None,
        block_reason: str | None,
    ) -> Any:
        from axonflow.hitl import HITLCreateInput

        client = await self._get_client()
        return await client.create_hitl_request(
            request=HITLCreateInput(
                client_id=self._config.client_id,
                user_id=user_token if user_token != "anonymous" else None,
                original_query=query[:4000],
                request_type=self._config.request_type,
                request_context={"model": model},
                triggered_policy_id=first_policy,
                triggered_policy_name=first_policy,
                trigger_reason=block_reason,
            ),
        )

    # ----- Helpers ---------------------------------------------------------

    @staticmethod
    def _resolve_context_id(kwargs: dict[str, Any]) -> str | None:
        metadata = (kwargs.get("litellm_params") or {}).get("metadata") or {}
        return (
            metadata.get(_METADATA_CONTEXT_ID)
            or kwargs.get(_KWARGS_CONTEXT_ID)
        )


# ---------------------------------------------------------------------------
# Module-level helpers
# ---------------------------------------------------------------------------


def _extract_query(messages: Any) -> str:
    if not messages:
        return ""
    for msg in reversed(messages):
        if isinstance(msg, dict) and msg.get("role") == "user":
            content = msg.get("content", "")
            if isinstance(content, str):
                return content[:4000]
            if isinstance(content, list):
                parts = [
                    p.get("text", "")
                    for p in content
                    if isinstance(p, dict) and p.get("type") == "text"
                ]
                return " ".join(parts)[:4000]
    last = messages[-1] if messages else {}
    if isinstance(last, dict):
        return str(last.get("content", ""))[:4000]
    return ""


def _extract_summary(response: Any) -> str:
    choices = getattr(response, "choices", None)
    if not choices:
        return ""
    msg = getattr(choices[0], "message", None)
    if msg is None:
        return ""
    content = getattr(msg, "content", None)
    return str(content)[:2000] if content else ""


def _infer_provider(model: str) -> str:
    m = model.lower()
    if "gpt" in m or "o1" in m or "o3" in m or "o4" in m:
        return "openai"
    if "claude" in m:
        return "anthropic"
    if "gemini" in m:
        return "google"
    if "bedrock" in m:
        return "bedrock"
    if "mistral" in m:
        return "mistral"
    if "llama" in m:
        return "meta"
    if "command" in m:
        return "cohere"
    return "unknown"


def _elapsed_ms(start_time: Any, end_time: Any) -> int:
    try:
        delta = end_time - start_time
        return int(delta.total_seconds() * 1000)
    except Exception:
        return 0
