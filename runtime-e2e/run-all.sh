#!/usr/bin/env bash
# Run all runtime-e2e tests sequentially. Exits 1 on first failure.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "===== RUNTIME-E2E FULL SUITE ====="
echo ""

PASS=0
FAIL=0
SKIP=0
START_TIME=$(date +%s)

for test_dir in "$SCRIPT_DIR"/*/; do
  test_script="$test_dir/test.sh"
  test_name=$(basename "$test_dir")
  [ -f "$test_script" ] || continue

  echo ""
  TEST_START=$(date +%s)
  if bash "$test_script" 2>&1; then
    TEST_END=$(date +%s)
    echo "  Duration: $((TEST_END - TEST_START))s"
    PASS=$((PASS + 1))
  else
    TEST_END=$(date +%s)
    echo "  Duration: $((TEST_END - TEST_START))s"
    echo "ABORT: $test_name failed"
    FAIL=$((FAIL + 1))
    END_TIME=$(date +%s)
    echo ""
    echo "===== SUITE ABORTED ====="
    echo "  PASS=$PASS FAIL=$FAIL Total=$((PASS + FAIL))"
    echo "  Duration: $((END_TIME - START_TIME))s"
    exit 1
  fi
done

END_TIME=$(date +%s)
echo ""
echo "===== SUITE COMPLETE ====="
echo "  PASS=$PASS FAIL=$FAIL Total=$((PASS + FAIL))"
echo "  Duration: $((END_TIME - START_TIME))s"
