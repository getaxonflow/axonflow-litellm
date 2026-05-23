# Copyright 2026 AxonFlow
# SPDX-License-Identifier: MIT

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class AxonFlowLoggerConfig:
    """Configuration for AxonFlowLogger."""

    endpoint: str
    client_id: str
    client_secret: str = ""

    default_user_token: str = "anonymous"
    tenant_id: str | None = None
    extra_context: dict[str, Any] = field(default_factory=dict)

    fail_open: bool = True
    call_timeout_seconds: float = 5.0
    breaker_failure_threshold: int = 5
    breaker_recovery_seconds: float = 30.0

    enable_hitl_polling: bool = True
    approval_poll_interval_seconds: float = 2.0
    approval_max_wait_seconds: float = 300.0

    request_type: str = "litellm-completion"

    def __post_init__(self) -> None:
        if not self.endpoint:
            raise ValueError("endpoint is required")
        if not self.client_id:
            raise ValueError("client_id is required")
        if self.call_timeout_seconds <= 0:
            raise ValueError("call_timeout_seconds must be positive")
        if self.breaker_failure_threshold < 1:
            raise ValueError("breaker_failure_threshold must be >= 1")
        if self.breaker_recovery_seconds <= 0:
            raise ValueError("breaker_recovery_seconds must be positive")
        if self.approval_poll_interval_seconds <= 0:
            raise ValueError("approval_poll_interval_seconds must be positive")
        if self.approval_max_wait_seconds <= 0:
            raise ValueError("approval_max_wait_seconds must be positive")
