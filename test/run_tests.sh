#!/bin/sh
# Run all workspace CLI tests.
#
# Usage: sh test/run_tests.sh

set -e

cd "$(dirname "$0")"

echo ""
echo "workspace CLI tests"
echo "──────────────────────────────────"

TOTAL_FAIL=0

for test_file in *_test.sh; do
  sh "$test_file" || TOTAL_FAIL=$((TOTAL_FAIL + 1))
done

echo "──────────────────────────────────"

if [ $TOTAL_FAIL -eq 0 ]; then
  echo "  All tests passed"
else
  echo "  $TOTAL_FAIL test file(s) had failures"
  exit 1
fi
echo ""
