#!/usr/bin/env bash
# The dispatcher asks for settings itself: a first-run wizard, and just-in-time prompts for what a stage needs.
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
has() { grep -qF -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
val() { bash -c "set -a; source '$1'; printf '%s' \"\${$2-<unset>}\""; }
unset SSH_CLIENT
export PATH="$ROOT/tests/fakebin:$PATH" FAKE_LOG=/dev/null DESTDIR="$T/root" ASSUME_YES=0
f=$T/node.env
export NODE_ENV=$f

# answers for a complete first run (see tests/test-config.sh for the question order), then Enters for any option prompts
first_run() {
  printf '%s\n' 10.0.0.20 10.0.0.30 10.0.0.1 '' james acme 'api web' '' 42+acme-hermes@users.noreply.github.com \
    vendor-a/worker vendor-b/reviewer vendor-a/mid vendor-c/fallback '' '' n n ''
  yes '' | head -40
}

# ---- no settings and no terminal
OUT=$("$ROOT/setup.sh" run 05 --dry-run </dev/null 2>&1); RC=$?
check "no settings, no terminal: refuses" test $RC -ne 0
check "...and points at ./setup.sh configure" has "./setup.sh configure"
check "...and does not create a file" test ! -e "$f"
OUT=$("$ROOT/setup.sh" run 05 --dry-run --yes 2>&1 </dev/null); RC=$?
check "--yes cannot invent settings that were never given" test $RC -ne 0

# ---- first run: the wizard starts by itself, then the stage runs
first_run >"$T/a1"
OUT=$(HS_INPUT="$T/a1" "$ROOT/setup.sh" run 05 --dry-run 2>&1); RC=$?
check "first run: exits 0" test $RC -eq 0
check "first run: announces the wizard" has "no settings yet"
check "first run: asked for the laptop IP" has "Laptop IP address"
check "first run: settings were saved" test "$(val "$f" LAPTOP_IP)" = 10.0.0.20
check "first run: the stage then ran with them" has "Stage 05"
check "first run: the stage saw the GitHub account the wizard collected" has "acme"
rm -f "$f"

# ---- just-in-time: a stage asks only for what it needs
"$ROOT/setup.sh" configure --defaults --set LAPTOP_IP=10.0.0.20 --set DESKTOP_IP=10.0.0.30 --set ROUTER_IP=10.0.0.1 --set ADMIN_USER=james >/dev/null 2>&1
check "setup: a defaults-only file exists" test -f "$f"
OUT=$("$ROOT/setup.sh" run 01 --dry-run --yes --skip-nvidia 2>&1 </dev/null); RC=$?
check "a stage that needs no GitHub settings does not ask for them" test $RC -eq 0
check "...and does not complain about them" lacks "GITHUB_ORG"
OUT=$("$ROOT/setup.sh" run 05 --dry-run --yes 2>&1 </dev/null); RC=$?
check "stage 05 without GitHub settings, no terminal: refuses" test $RC -ne 0
check "...naming exactly what is missing" has "GITHUB_ORG GITHUB_REPOS GITHUB_MACHINE_USER GITHUB_NOREPLY_EMAIL"
check "...and the command to fix it" has "configure --only"
printf '%s\n' acme 'api web' '' 42+acme-hermes@users.noreply.github.com >"$T/a2"; yes '' | head -20 >>"$T/a2"
OUT=$(HS_INPUT="$T/a2" "$ROOT/setup.sh" run 05 --dry-run 2>&1); RC=$?
check "stage 05 asks for the GitHub settings itself" test $RC -eq 0
check "...showing why it asks" has "this step needs: GITHUB_ORG GITHUB_REPOS GITHUB_MACHINE_USER GITHUB_NOREPLY_EMAIL"
check "...and does not re-ask the network settings" lacks "Laptop IP address"
check "...saved the answers" test "$(val "$f" GITHUB_ORG)/$(val "$f" GITHUB_REPOS)" = "acme/api web"
check "...and kept the earlier ones" test "$(val "$f" LAPTOP_IP)" = 10.0.0.20
OUT=$("$ROOT/setup.sh" run 05 --dry-run --yes 2>&1 </dev/null); RC=$?
check "second run: nothing left to ask" test $RC -eq 0
OUT=$("$ROOT/setup.sh" run 07 --dry-run --yes 2>&1 </dev/null); RC=$?
check "stage 07 needs the OpenRouter models and says so" bash -c "[[ $RC -ne 0 ]] && grep -q 'OR_WORKER_MODEL OR_REVIEW_MODEL OR_COMPRESSION_MODEL' <<<\"\$0\"" "$OUT"
printf '%s\n' vendor-a/worker vendor-b/reviewer vendor-a/mid >"$T/a3"
OUT=$(HS_INPUT="$T/a3" "$ROOT/setup.sh" run 07 --dry-run 2>&1); RC=$?
check "stage 07 prompts for the three roles and proceeds" test $RC -eq 0
check "...with the worker model in the merged config preview" has "vendor-a/worker"

# ---- tools that never need settings keep working without any
OUT=$(NODE_ENV="$T/none.env" "$ROOT/setup.sh" tool adopt-repo 2>&1 </dev/null); RC=$?
check "adopt-repo needs no settings file (it only needs its own arguments)" bash -c "[[ $RC -ne 0 ]] && ! grep -q 'no settings yet' <<<\"\$0\"" "$OUT"

# ---- check
OUT=$("$ROOT/setup.sh" check 2>&1 </dev/null); RC=$?
check "check: validates the file" test $RC -eq 0
rm -f "$f"
OUT=$("$ROOT/setup.sh" check 2>&1 </dev/null); RC=$?
check "check: without a file and without a terminal, refuses" test $RC -ne 0

echo "dispatcher config: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
