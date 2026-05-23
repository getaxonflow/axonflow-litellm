#!/usr/bin/env bash
# Bring up the AxonFlow community stack for runtime-e2e testing.
# Set AXONFLOW_STACK_DIR to a directory containing docker-compose.yml.
# If not set, exits 0 — individual tests will skip when /health is unreachable.

set -euo pipefail

STACK_DIR="${AXONFLOW_STACK_DIR:-}"

if [ -n "$STACK_DIR" ] && [ -f "$STACK_DIR/docker-compose.yml" ]; then
  echo "Starting AxonFlow stack from $STACK_DIR ..."
  cd "$STACK_DIR"
  docker compose -f docker-compose.yml up -d --wait --timeout 60
  echo "AxonFlow stack ready at http://localhost:8080"
else
  echo "NOTE: AxonFlow stack not configured. Tests requiring a live stack will SKIP."
  echo "Set AXONFLOW_STACK_DIR to a directory containing docker-compose.yml."
fi
