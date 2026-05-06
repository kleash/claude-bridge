#!/usr/bin/env bash
# Run every test in this directory. Each is a self-contained bash script
# that exits non-zero on failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS=(
  test-hook-per-session.sh
  test-router.sh
  test-router-directives.sh
  test-pretool-hook.sh
  test-notify-hook.sh
  test-doctor.sh
  test-index.sh
  test-cli.sh
)

failed=0
for t in "${TESTS[@]}"; do
  printf '\n=== %s ===\n' "$t"
  if bash "$ROOT/tests/$t"; then
    :
  else
    failed=$((failed+1))
    echo "*** $t FAILED ***"
  fi
done

printf '\n'
if [ "$failed" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "$failed test file(s) FAILED"
  exit 1
fi
