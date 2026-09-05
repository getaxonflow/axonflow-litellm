"""The ADR-065 PEP capability handshake for this adapter.

Tracking: getaxonflow/axonflow-enterprise#3763; read by the platform on the
gateway pre-check plane as of axonflow-enterprise#3778.

THE GOLDEN VECTOR IS CAPTURED FROM THE PLATFORM'S OWN SHIPPED ENCODER
(``contract.PEPHandshake.Encode``), not regenerated from this module. This
repository cannot import the contract package - it lives in a private repo - so
``pep_handshake.py`` is a hand transcription of a wire format, the drift class
that bit five SDKs in axonflow-enterprise#3603.
"""

import base64
import json

import pytest

from axonflow_litellm.pep_handshake import (
    PEP_HANDSHAKE_HEADER,
    PEP_ID,
    build_pep_handshake,
    encode_handshake,
)

GOLDEN = "eyJwcm9maWxlX3ZlcnNpb24iOjEsInBlcF9pZCI6ImxpdGVsbG0tZ2F0ZXdheSIsImF1ZGllbmNlIjoiYXhvbmZsb3ctZGVjaXNpb24tcHJvb2YiLCJjYXBhYmlsaXRpZXMiOltdfQ"
AUDIENCE = "axonflow-decision-proof"


def _decode(encoded):
    return json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))


def test_encoding_matches_the_platform_encoder_byte_for_byte():
    assert build_pep_handshake(AUDIENCE) == GOLDEN


def test_the_adapter_declares_nothing_because_it_substitutes_nothing():
    # pre_check is this adapter's only governed call and it branches on
    # `approved` and `block_reason` alone; it does not read requires_redaction
    # and does not rewrite the prompt. Declaring field_redact would tell the
    # platform to allow the call on the strength of a substitution this adapter
    # does not perform.
    doc = _decode(build_pep_handshake(AUDIENCE))
    assert doc["capabilities"] == []
    assert doc["pep_id"] == PEP_ID


def test_an_empty_declaration_serialises_as_an_empty_array():
    # An OMITTED capabilities member is MALFORMED to the platform and refuses
    # the request; [] is the declaration "I discharge nothing".
    raw = base64.urlsafe_b64decode(build_pep_handshake(AUDIENCE) + "==").decode()
    assert '"capabilities":[]' in raw


def test_no_identity_or_entitlement_member_reaches_the_wire():
    # A PEP may declare what it CAN DO, never who it is or what it is entitled
    # to; the platform refuses an unknown member outright.
    assert set(_decode(build_pep_handshake(AUDIENCE))) == {
        "profile_version",
        "pep_id",
        "audience",
        "capabilities",
    }


def test_no_audience_presents_nothing_at_all():
    # None rather than "": a header PRESENT with an empty value is MALFORMED to
    # the platform and refuses the request, which an ABSENT header does not.
    assert build_pep_handshake(None) is None
    assert build_pep_handshake("") is None


@pytest.mark.parametrize(
    "bad",
    ["has spaces", "-leading-hyphen", "a" * 129, "aud\n", "aud\nhas spaces", "\naud"],
)
def test_a_malformed_audience_raises_rather_than_silently_disabling(bad):
    # The multi-line cases are regressions. The same grammar is hand-ported into
    # five clients and the end anchor differs in each: Python's `$` also matches
    # just BEFORE a trailing newline (so `^...$` accepted "aud\n" in a sibling
    # until it was anchored with \A/\Z), and shell's grep is line-based. A
    # newline inside the audience puts a raw newline inside a JSON string, which
    # the platform refuses as a malformed handshake on every governed call.
    with pytest.raises(ValueError):
        encode_handshake(PEP_ID, bad, [])


def test_the_header_is_named_exactly_as_the_platform_reads_it():
    assert PEP_HANDSHAKE_HEADER == "X-Axonflow-PEP-Handshake"
