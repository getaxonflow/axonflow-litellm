#!/usr/bin/env bash
# Bring up the AxonFlow community stack for runtime-e2e testing.
# Uses the axonflow-enterprise docker-compose if available locally,
# otherwise pulls the published community images.

set -euo pipefail

ENTERPRISE_DIR="${AXONFLOW_ENTERPRISE_DIR:-$(cd "$(dirname "$0")/../../../../axonflow-enterprise" 2>/dev/null && pwd || echo "")}"

if [ -n "$ENTERPRISE_DIR" ] && [ -f "$ENTERPRISE_DIR/docker-compose.yml" ]; then
  echo "Starting AxonFlow stack from $ENTERPRISE_DIR ..."
  cd "$ENTERPRISE_DIR"
  docker compose -f docker-compose.yml up -d --wait --timeout 60
  echo "AxonFlow stack ready at http://localhost:8080"
else
  echo "ERROR: axonflow-enterprise repo not found at $ENTERPRISE_DIR"
  echo "Set AXONFLOW_ENTERPRISE_DIR to the path of your axonflow-enterprise checkout."
  exit 1
fi
