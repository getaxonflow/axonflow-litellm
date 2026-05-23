#!/usr/bin/env bash
# Tear down the AxonFlow stack started by setup-stack.sh.

set -euo pipefail

STACK_DIR="${AXONFLOW_STACK_DIR:-}"

if [ -n "$STACK_DIR" ] && [ -f "$STACK_DIR/docker-compose.yml" ]; then
  cd "$STACK_DIR"
  docker compose -f docker-compose.yml down -v --timeout 10
  echo "AxonFlow stack torn down."
else
  echo "No stack to tear down (AXONFLOW_STACK_DIR not set)"
fi
