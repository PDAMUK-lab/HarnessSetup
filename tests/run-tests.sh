#!/usr/bin/env bash
# Run every test. Exit non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
rc=0
for t in lint.sh test-*.sh; do
  echo "== $t"
  bash "./$t" </dev/null || rc=1
done
[[ $rc -eq 0 ]] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $rc
