#!/usr/bin/env bash
# Tear down the AxonFlow stack started by setup-stack.sh.

set -euo pipefail

ENTERPRISE_DIR="${AXONFLOW_ENTERPRISE_DIR:-$(cd "$(dirname "$0")/../../../../axonflow-enterprise" 2>/dev/null && pwd || echo "")}"

if [ -n "$ENTERPRISE_DIR" ] && [ -f "$ENTERPRISE_DIR/docker-compose.yml" ]; then
  cd "$ENTERPRISE_DIR"
  docker compose -f docker-compose.yml down -v --timeout 10
  echo "AxonFlow stack torn down."
fi
