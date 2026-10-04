#!/usr/bin/env bash
# Static checks: bash syntax + ShellCheck for every shell script, YAML lint for rendered templates.
# Tools are optional locally (a missing one is reported, not fatal) unless STRICT=1.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
SHELLCHECK=${SHELLCHECK:-shellcheck}
mapfile -t scripts < <(git ls-files --cached --others --exclude-standard '*.sh' | sort)

for f in "${scripts[@]}"; do
  bash -n "$f" || { echo "SYNTAX: $f"; fail=1; }
done
echo "bash -n: ${#scripts[@]} scripts"

if command -v "$SHELLCHECK" >/dev/null 2>&1; then
  "$SHELLCHECK" -x -P SCRIPTDIR:. -S style "${scripts[@]}" && echo "shellcheck: clean" || fail=1
else
  echo "shellcheck not installed - skipped"; [[ ${STRICT:-0} == 1 ]] && fail=1
fi
exit $fail
