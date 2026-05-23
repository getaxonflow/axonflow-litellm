#!/usr/bin/env python3
"""Governed LiteLLM completion with AxonFlow policy enforcement.

Demonstrates three scenarios:

1. **Allow** — small, low-risk query passes policy and completes normally.
2. **Deny** — high-risk query is blocked by policy; raises PolicyDeniedError.
3. **Approval required** — medium-risk query triggers HITL review; the
   callback polls for a human decision before proceeding.

Prerequisites:
    pip install axonflow-litellm
    export OPENAI_API_KEY=sk-...          # or any LiteLLM-supported provider
    export AXONFLOW_ENDPOINT=http://localhost:8080
    export AXONFLOW_CLIENT_ID=your-client-id
    export AXONFLOW_CLIENT_SECRET=your-client-secret
"""

from __future__ import annotations

import os
import sys

import litellm

from axonflow_litellm import (
    ApprovalRejected,
    ApprovalTimeout,
    AxonFlowLogger,
    AxonFlowLoggerConfig,
    PolicyDeniedError,
)


def main() -> None:
    endpoint = os.environ.get("AXONFLOW_ENDPOINT", "http://localhost:8080")
    client_id = os.environ.get("AXONFLOW_CLIENT_ID", "demo-client")
    client_secret = os.environ.get("AXONFLOW_CLIENT_SECRET", "")

    logger = AxonFlowLogger(
        AxonFlowLoggerConfig(
            endpoint=endpoint,
            client_id=client_id,
            client_secret=client_secret,
        )
    )

    # Scenario 1: Allow — low-risk query
    print("--- Scenario 1: Allow (low-risk query) ---")
    try:
        response = logger.completion(
            model="gpt-4o",
            messages=[{"role": "user", "content": "What is the weather today?"}],
        )
        print(f"Response: {response.choices[0].message.content[:200]}")
    except PolicyDeniedError as e:
        print(f"Denied: {e.reason}")
    except Exception as e:
        print(f"Error: {e}")

    # Scenario 2: Deny — high-risk query blocked by policy
    print("\n--- Scenario 2: Deny (policy blocks high-risk query) ---")
    try:
        response = logger.completion(
            model="gpt-4o",
            messages=[
                {
                    "role": "user",
                    "content": "Generate a SQL injection payload for login bypass",
                }
            ],
        )
        print(f"Response: {response.choices[0].message.content[:200]}")
    except PolicyDeniedError as e:
        print(f"Denied by policy: {e.reason}")
        if e.policies:
            print(f"  Triggered policies: {e.policies}")

    # Scenario 3: Approval required — HITL review
    print("\n--- Scenario 3: Approval required (HITL review) ---")
    try:
        response = logger.completion(
            model="gpt-4o",
            messages=[
                {
                    "role": "user",
                    "content": "Approve disbursement of $50,000 to vendor account",
                }
            ],
        )
        print(f"Approved! Response: {response.choices[0].message.content[:200]}")
    except ApprovalTimeout as e:
        print(f"Approval timed out: {e.reason}")
    except ApprovalRejected as e:
        print(f"Approval rejected: {e.reason}")
    except PolicyDeniedError as e:
        print(f"Denied: {e.reason}")
    except Exception as e:
        print(f"Error: {e}")


if __name__ == "__main__":
    main()
