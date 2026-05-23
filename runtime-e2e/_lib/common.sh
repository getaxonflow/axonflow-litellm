#!/usr/bin/env bash
# Shared helpers for runtime-e2e tests.
# Source this from each test.sh: source "$SCRIPT_DIR/../_lib/common.sh"

set -euo pipefail

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${AXONFLOW_CLIENT_ID:=demo-client}"
: "${AXONFLOW_CLIENT_SECRET:=demo-secret}"
: "${LLM_MODEL:=gpt-4o-mini}"

export AXONFLOW_ENDPOINT AXONFLOW_CLIENT_ID AXONFLOW_CLIENT_SECRET LLM_MODEL

runtime_e2e_skip_if_unavailable() {
  if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not on PATH"
    exit 0
  fi
  if ! curl -sf --max-time 5 "${AXONFLOW_ENDPOINT}/health" &>/dev/null; then
    echo "SKIP: AxonFlow stack not reachable at ${AXONFLOW_ENDPOINT}"
    exit 0
  fi
}

run_python_test() {
  local script="$1"
  python3 -u "$script"
}
