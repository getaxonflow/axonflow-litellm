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
import importlib
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


@pytest.mark.parametrize(
    "raised",
    [RuntimeError("telemetry module is broken"), AttributeError("no attribute 'x'")],
)
def test_a_real_fault_in_the_sdk_call_is_NOT_swallowed(monkeypatch, raised):
    """The CALL is unguarded, and `AttributeError` is the case that matters.

    An earlier version wrapped the call in ``except AttributeError`` "for a
    build where the symbol exists but is not callable". That was wrong twice
    over: calling a non-callable raises ``TypeError``, not ``AttributeError``,
    so it did not catch what it claimed — and it DID catch a genuine
    ``AttributeError`` raised inside the SDK's own ``register_adapter``, masking
    a real defect and making this integration silently stop declaring itself.
    That is the same invisible-adoption-data failure the feature exists to fix.

    Both are asserted, because a guard catching only the exotic one would still
    pass a test that used only ``RuntimeError``.
    """

    def _boom(_name: str) -> None:
        raise raised

    fake = types.ModuleType("axonflow")
    fake.register_adapter = _boom  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "axonflow", fake)

    with pytest.raises(type(raised)):
        logger_module._declare_adapter()


def test_a_non_ImportError_from_the_IMPORT_is_NOT_swallowed(monkeypatch):
    """The import guard catches ``ImportError`` and nothing else.

    MUTATION GATE: widening it to ``except Exception`` survives every other test
    in this file, because they only ever make the import succeed or raise
    ``ImportError``. A guard that swallowed, say, a ``RuntimeError`` from the
    SDK's module-level initialisation would turn a broken install into silent
    non-reporting.

    The fault is raised from the module's ``__getattr__``, which is what runs
    during ``from axonflow import register_adapter``.
    """

    class _ExplodingModule(types.ModuleType):
        def __getattr__(self, name: str):
            raise RuntimeError(f"module initialisation failed for {name}")

    monkeypatch.setitem(sys.modules, "axonflow", _ExplodingModule("axonflow"))

    with pytest.raises(RuntimeError, match="module initialisation failed"):
        logger_module._declare_adapter()


def test_importing_this_package_declares_NOTHING(monkeypatch):
    """An import says INSTALLED; a client says IN USE.

    MUTATION GATE: add a module-level ``_declare_adapter()`` beside the kept
    call sites and this fails. Without it, that mutant survives — every other
    test in this file calls ``_declare_adapter`` (or a constructor that does),
    so none of them can tell a call at import time from a call at client time.

    Import-time registration is the over-reporting twin of the under-reporting
    this whole lane started from: a linter, a test collector or an IDE indexer
    would declare LiteLLM adoption that never happened.
    """
    calls: list[str] = []
    fake = types.ModuleType("axonflow")
    fake.register_adapter = calls.append  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "axonflow", fake)

    # A genuinely fresh import, not a cached module object.
    for name in [m for m in sys.modules if m.startswith("axonflow_litellm")]:
        monkeypatch.delitem(sys.modules, name, raising=False)
    importlib.import_module("axonflow_litellm")
    importlib.import_module("axonflow_litellm.logger")

    assert calls == [], (
        f"importing the package declared {calls}. An import says this package is "
        "INSTALLED, not that it is being used to govern a call."
    )


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


def test_from_client_declares_the_adapter(monkeypatch):
    """`from_client` is a SECOND way a client comes into existence, and it
    bypasses `_get_client` entirely.

    It sets ``_client`` directly, so ``_get_client`` returns on its first line
    and never reaches the declaration. An application that injects its own
    AxonFlow client would therefore have reported as bare SDK use forever —
    measured: the registry stayed empty on this path.

    MUTATION GATE: delete the ``_declare_adapter()`` call from ``from_client``
    and this fails. No other test in this file covers that path.
    """
    calls: list[str] = []
    fake = types.ModuleType("axonflow")
    fake.register_adapter = calls.append  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "axonflow", fake)

    from axonflow_litellm import AxonFlowLoggerConfig

    injected = object()
    logger = logger_module.AxonFlowLogger.from_client(
        injected,
        AxonFlowLoggerConfig(
            endpoint="http://127.0.0.1:1",
            client_id="id",
            client_secret="secret",
        ),
    )

    assert calls == ["litellm"], (
        f"from_client declared {calls}; an injected-client application must not "
        "report as bare SDK use"
    )
    # Positive control: the injected client really is the one in use, so this is
    # the path an application would take.
    assert asyncio.run(logger._get_client()) is injected
