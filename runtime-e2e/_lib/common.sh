#!/usr/bin/env bash
# Shared helpers for runtime-e2e tests.
# Source this from each test.sh: source "$SCRIPT_DIR/../_lib/common.sh"

set -euo pipefail

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${AXONFLOW_CLIENT_ID:=demo-client}"
: "${AXONFLOW_CLIENT_SECRET:=demo-secret}"
: "${LLM_MODEL:=gpt-4o-mini}"
: "${AXONFLOW_DB_HOST:=localhost}"
: "${AXONFLOW_DB_PORT:=5432}"
: "${AXONFLOW_DB_USER:=axonflow}"
: "${AXONFLOW_DB_PASSWORD:=localdev123}"
: "${AXONFLOW_DB_NAME:=axonflow}"

export AXONFLOW_ENDPOINT AXONFLOW_CLIENT_ID AXONFLOW_CLIENT_SECRET LLM_MODEL
export AXONFLOW_DB_HOST AXONFLOW_DB_PORT AXONFLOW_DB_USER AXONFLOW_DB_PASSWORD AXONFLOW_DB_NAME

require_stack() {
  if ! command -v python3 &>/dev/null; then
    echo "FAIL: python3 not on PATH — cannot run runtime-e2e tests"
    exit 1
  fi
  if ! curl -sf --max-time 5 "${AXONFLOW_ENDPOINT}/health" &>/dev/null; then
    echo "FAIL: AxonFlow stack not reachable at ${AXONFLOW_ENDPOINT} — runtime-e2e tests require a live stack"
    exit 1
  fi
}

require_psql() {
  if ! command -v psql &>/dev/null; then
    echo "FAIL: psql not on PATH — runtime-e2e tests require psql for DB assertions"
    exit 1
  fi
}

run_psql() {
  PGPASSWORD="$AXONFLOW_DB_PASSWORD" psql \
    -h "$AXONFLOW_DB_HOST" \
    -p "$AXONFLOW_DB_PORT" \
    -U "$AXONFLOW_DB_USER" \
    -d "$AXONFLOW_DB_NAME" \
    -t -A "$@"
}

create_deny_policy() {
  local name="$1"
  local pattern="$2"
  curl -sf -X POST "${AXONFLOW_ENDPOINT}/api/v1/static-policies" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"description\": \"E2E test deny policy\",
      \"category\": \"custom\",
      \"tier\": \"tenant\",
      \"pattern\": \"${pattern}\",
      \"action\": \"block\",
      \"severity\": \"critical\",
      \"enabled\": true,
      \"tags\": [\"e2e-test\"]
    }"
}

create_require_approval_policy() {
  local name="$1"
  local pattern="$2"
  curl -sf -X POST "${AXONFLOW_ENDPOINT}/api/v1/static-policies" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"description\": \"E2E test require_approval policy\",
      \"category\": \"custom\",
      \"tier\": \"tenant\",
      \"pattern\": \"${pattern}\",
      \"action\": \"require_approval\",
      \"severity\": \"high\",
      \"enabled\": true,
      \"tags\": [\"e2e-test\", \"hitl\"]
    }"
}

delete_policy() {
  local policy_id="$1"
  curl -sf -X DELETE "${AXONFLOW_ENDPOINT}/api/v1/static-policies/${policy_id}" || true
}

approve_hitl_request() {
  local request_id="$1"
  curl -sf -X POST "${AXONFLOW_ENDPOINT}/api/v1/hitl/queue/${request_id}/approve" \
    -H "Content-Type: application/json" \
    -d '{"reviewer_id": "e2e-test-reviewer", "comments": "auto-approved by e2e test"}'
}
