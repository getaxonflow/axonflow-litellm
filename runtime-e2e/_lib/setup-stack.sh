#!/usr/bin/env bash
# Bring up the AxonFlow community stack for runtime-e2e testing.
# Set AXONFLOW_STACK_DIR to a directory containing docker-compose.yml.
# Exits 1 if the stack cannot be started — tests must NOT silently skip.

set -euo pipefail

STACK_DIR="${AXONFLOW_STACK_DIR:-}"

if [ -z "$STACK_DIR" ] || [ ! -f "$STACK_DIR/docker-compose.yml" ]; then
  echo "FAIL: AXONFLOW_STACK_DIR is not set or does not contain docker-compose.yml"
  echo "Set AXONFLOW_STACK_DIR to a directory with the AxonFlow docker-compose.yml"
  exit 1
fi

echo "Starting AxonFlow stack from $STACK_DIR ..."
cd "$STACK_DIR"
docker compose -f docker-compose.yml up -d --wait --timeout 120

echo "Waiting for agent health..."
for i in $(seq 1 30); do
  if curl -sf --max-time 5 http://localhost:8080/health &>/dev/null; then
    echo "AxonFlow stack healthy at http://localhost:8080"
    exit 0
  fi
  sleep 2
done

echo "FAIL: AxonFlow stack not healthy after 60s"
exit 1
