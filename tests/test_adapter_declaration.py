"""LiteLLM declares itself on the SDK's telemetry heartbeat.

axonflow-enterprise#3682 item 1. Without this, an application governed through
this integration is indistinguishable from bare SDK use on every telemetry
dimension — same ``sdk``, same ``sdk_version``, same endpoint.

WHAT THESE TESTS CAN AND CANNOT VARY. They vary what
``axonflow.register_adapter`` receives and whether it exists at all, which is
the whole surface this package owns. They CANNOT vary what the SDK then does
with the name: the wire, the caps and the 7-day cadence belong to
``axonflow-sdk-python`` and are asserted there. Duplicating those assertions
here would be a second copy of a contract that already has an owner.
"""

from __future__ import annotations

import asyncio
import sys
import types

import pytest

from axonflow_litellm import logger as logger_module


def test_the_adapter_name_is_exactly_litellm(monkeypatch):
    """The name is a literal, and it is the one the receiver buckets.

    MUTATION GATE: change the string in ``_declare_adapter`` and this fails.
    """
    calls: list[str] = []
    fake = types.ModuleType("axonflow")
    fake.register_adapter = calls.append  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "axonflow", fake)

    logger_module._declare_adapter()

    assert calls == ["litellm"]


def test_an_sdk_without_register_adapter_is_tolerated(monkeypatch):
    """`pyproject.toml` floors the SDK at ``axonflow>=8.2.0`` and
    ``register_adapter`` arrives in 9.3.0, so an installation that satisfies the
    floor may not have the symbol.

    THIS IS NOT A HYPOTHETICAL PATH: the SDK currently resolved in this repo's
    own dev environment does not have it, which is how the guard was verified
    rather than assumed.

    Declaring the adapter must never break a caller's LLM call, so an older SDK
    is a silent no-op — not an exception, and not a warning on every governed
    request.
    """
    fake = types.ModuleType("axonflow")  # no register_adapter attribute
    monkeypatch.setitem(sys.modules, "axonflow", fake)

    logger_module._declare_adapter()  # must not raise


def test_a_real_fault_in_the_sdk_is_NOT_swallowed(monkeypatch):
    """The guard is narrow on purpose.

    A broad ``except Exception`` would swallow a genuine fault in the SDK's
    telemetry module and make this integration silently stop declaring itself —
    the failure mode would be invisible adoption data, which is exactly what
    this feature exists to fix. Only ``ImportError`` and ``AttributeError`` are
    caught, so anything else propagates.
    """

    def _boom(_name: str) -> None:
        raise RuntimeError("the SDK's telemetry module is broken")

    fake = types.ModuleType("axonflow")
    fake.register_adapter = _boom  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "axonflow", fake)

    with pytest.raises(RuntimeError, match="broken"):
        logger_module._declare_adapter()


def test_the_declaration_happens_before_the_client_is_built(monkeypatch):
    """ORDER IS THE CONTRACT, not an implementation detail.

    The SDK's heartbeat fires on the client's FIRST OUTBOUND REQUEST
    (axonflow-enterprise#3682), so a declaration made after the client has
    already sent something rides the NEXT heartbeat — a week later — instead of
    the first one. Registering must therefore happen before ``AxonFlow(...)``.

    Asserted by recording the ORDER of both events, rather than merely that both
    happened: "both were called" is satisfied by the broken ordering too.
    """
    order: list[str] = []

    fake = types.ModuleType("axonflow")
    fake.register_adapter = lambda name: order.append(f"register:{name}")  # type: ignore[attr-defined]

    class _FakeClient:
        def __init__(self, **_kwargs: object) -> None:
            order.append("construct-client")

    fake.AxonFlow = _FakeClient  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "axonflow", fake)

    from axonflow_litellm import AxonFlowLoggerConfig

    logger = logger_module.AxonFlowLogger(
        AxonFlowLoggerConfig(
            endpoint="http://127.0.0.1:1",
            client_id="id",
            client_secret="secret",
        )
    )

    asyncio.run(logger._get_client())

    assert order == ["register:litellm", "construct-client"], (
        "the adapter must be declared BEFORE the client is constructed; a "
        "declaration made after the client's first request rides the next "
        f"heartbeat instead of the first. Got {order}"
    )


def test_the_declaration_is_not_repeated_per_request(monkeypatch):
    """A per-request registration would be pointless work on a hot path.

    The registry deduplicates, so repeats are harmless on the wire — but this
    runs inside the client lock on every governed call, and doing it once is the
    documented behaviour.
    """
    calls: list[str] = []
    fake = types.ModuleType("axonflow")
    fake.register_adapter = calls.append  # type: ignore[attr-defined]

    class _FakeClient:
        def __init__(self, **_kwargs: object) -> None:
            pass

    fake.AxonFlow = _FakeClient  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "axonflow", fake)

    from axonflow_litellm import AxonFlowLoggerConfig

    logger = logger_module.AxonFlowLogger(
        AxonFlowLoggerConfig(
            endpoint="http://127.0.0.1:1",
            client_id="id",
            client_secret="secret",
        )
    )

    async def _three_calls() -> None:
        for _ in range(3):
            await logger._get_client()

    asyncio.run(_three_calls())

    assert calls == ["litellm"], f"declared {len(calls)} times, want exactly once: {calls}"
