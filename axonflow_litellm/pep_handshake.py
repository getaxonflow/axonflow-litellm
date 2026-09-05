"""The ADR-065 PEP capability handshake, client side.

Tracking: getaxonflow/axonflow-enterprise#3763. Read by the platform on the
gateway pre-check plane as of axonflow-enterprise#3778.

This adapter tells the platform WHAT IT CAN DISCHARGE on every governed call, as
a base64url-encoded JSON document in one request header. A platform that would
attach a mandatory obligation this adapter has declared it cannot carry out
DENIES the request, rather than handing over the instruction and trusting the
adapter to act on it (ADR-065 invariant 8).

WHY THIS ADAPTER DECLARES NO CAPABILITIES
-----------------------------------------

A ``field_redact`` obligation is discharged by substituting the platform's
engine-masked content for the original; ADR-056 forbids a client from redacting
for itself, so that substitution is the only sanctioned discharge.

This adapter performs none. Its governed call is ``pre_check``, and it branches
on ``approved`` and ``block_reason`` alone (``logger.py:424`` and ``:499``); it
does not read ``requires_redaction`` and does not rewrite the prompt.

So it cannot ESTABLISH that such an obligation would be discharged, and a
declaration describes what an enforcement point CAN do rather than what it
should do. Declaring ``field_redact`` would tell the platform to ALLOW the call
on the strength of a substitution this adapter does not perform. Declaring the
empty set makes the platform refuse instead, which is the outcome invariant 8
requires while that remains true.

ONE ENFORCEMENT POINT
---------------------

Unlike the sibling clients that reach two planes, this adapter has a single
governed call path, so it presents a single declaration under a single
``pep_id``.

WHY THIS RE-IMPLEMENTS AN ENCODER THAT EXISTS
---------------------------------------------

The canonical encoder is ``contract.PEPHandshake.Encode`` in a PRIVATE
repository this public one cannot import, so this module is a hand transcription
of a wire format - the drift class that bit five SDKs in
axonflow-enterprise#3603. ``tests/test_pep_handshake.py`` asserts the exact bytes
against a vector captured from the platform's own shipped encoder.
"""

from __future__ import annotations

import base64
import json
import re

#: The request header a declaration rides on.
PEP_HANDSHAKE_HEADER = "X-Axonflow-PEP-Handshake"

#: The only profile this build emits. The platform matches it with EXACT
#: equality, never as a floor or a range: a build that cannot emit the named
#: profile must not answer as though negotiation succeeded.
PROFILE_VERSION = 1

#: The obligation type for engine-fulfilled redaction, and its schema version.
CAP_FIELD_REDACT = "field_redact"
CAP_SCHEMA_V1 = 1

#: This enforcement point's name, inside the caller's credential namespace.
#:
#: It carries no colon: the platform composes ``client:<credential>:<pep_id>``,
#: so admitting one would let a name appear inside an identifier that no string
#: search could tell apart from a real in-process plane.
PEP_ID = "litellm-gateway"

#: The platform refuses a header value longer than this.
MAX_HANDSHAKE_BYTES = 4096

#: Bounds the operator-supplied audience before it can reach the wire, so a
#: malformed value fails at construction rather than 400-ing every governed call
#: in production.
# `\Z` rather than `$`, and that is not style: Python's `$` also matches just
# BEFORE a trailing newline, so `^...$` accepts "aud\n" - which the platform
# refuses, because its own grammar is anchored to the end of the string. A
# newline-terminated audience would then be built here and 400 every governed
# call. Caught by test_a_malformed_audience_raises_rather_than_silently_disabling.
_AUDIENCE_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._:-]*\Z")


def encode_handshake(pep_id: str, audience: str, capabilities: list[dict[str, object]]) -> str:
    """Render one declaration as the header value.

    Raises ``ValueError`` on a malformed audience or an over-long document,
    rather than returning an empty string: a value that silently disabled the
    handshake would leave an operator believing a control was in force when it
    was not.
    """
    if not 1 <= len(audience) <= 128 or not _AUDIENCE_PATTERN.match(audience):
        raise ValueError(
            f"invalid AxonFlow PEP audience {audience!r}: "
            f"1-128 bytes matching {_AUDIENCE_PATTERN.pattern}"
        )

    # Canonical (type, version) order so two installs declaring the same set in
    # a different order send the same bytes. The platform sorts too; agreeing
    # here is what makes the encoding reproducible and the golden vector
    # meaningful.
    ordered = sorted(capabilities, key=lambda c: (str(c["type"]), int(c["version"])))  # type: ignore[index]

    doc = {
        "profile_version": PROFILE_VERSION,
        "pep_id": pep_id,
        "audience": audience,
        # ALWAYS serialised, never omitted when empty. An OMITTED
        # `capabilities` member is MALFORMED to the platform and refuses the
        # request, while `[]` is the legitimate declaration "I discharge
        # nothing" - different facts with different outcomes.
        "capabilities": ordered,
    }
    # separators without spaces so the bytes match the platform's compact
    # encoding; the key order is the insertion order above.
    raw = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    if len(encoded) > MAX_HANDSHAKE_BYTES:
        raise ValueError(
            f"the AxonFlow PEP capability handshake encodes to {len(encoded)} bytes; "
            f"the header carries at most {MAX_HANDSHAKE_BYTES}"
        )
    return encoded


def build_pep_handshake(audience: str | None) -> str | None:
    """Build the declaration, or ``None`` when no audience is configured.

    WHY AN AUDIENCE IS REQUIRED RATHER THAN DEFAULTED

    The audience is what a decision proof gets bound to and only the DEPLOYMENT
    knows it; an adapter that invented one would assert a binding nobody asked
    for. It is also why the handshake is opt-in: on an Enterprise platform
    carrying axonflow-enterprise#3778 the transition it gates is ALLOW -> DENY
    for a governed call the platform requires a redaction on. ``None`` here
    means no header at all, and the adapter then behaves byte for byte as it did
    before.

    ``None`` rather than an empty string, deliberately: a header PRESENT with an
    empty value is MALFORMED to the platform and refuses the request, which an
    ABSENT header does not.

    Same knob name and semantics as every other AxonFlow client
    (``AXONFLOW_PEP_AUDIENCE``): one contract across the fleet, no per-client
    dialects.
    """
    if not audience:
        return None
    # The empty set. See the module docstring for why that is the honest answer.
    return encode_handshake(PEP_ID, audience, [])
