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
check "first run: the stage used the GitHub account the wizard collected (clone command)" has "gh repo clone acme/api"
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
check "...with the worker model in the merged config preview" has 'model: "vendor-a/worker"'

# ---- tools that never need settings keep working without any
OUT=$(NODE_ENV="$T/none.env" "$ROOT/setup.sh" tool adopt-repo 2>&1 </dev/null); RC=$?
check "adopt-repo needs no settings file (it only needs its own arguments)" bash -c "[[ $RC -ne 0 ]] && ! grep -q 'no settings yet' <<<\"\$0\"" "$OUT"

# ---- check
OUT=$("$ROOT/setup.sh" check 2>&1 </dev/null); RC=$?
check "check: validates the file" test $RC -eq 0
rm -f "$f"
OUT=$("$ROOT/setup.sh" check 2>&1 </dev/null); RC=$?
check "check: without a file and without a terminal, refuses" test $RC -ne 0

# ---- the addresses and admin account are always checked, even for a stage that lists nothing (finding f15)
printf 'GITHUB_ORG=acme\n' >"$f"
OUT=$("$ROOT/setup.sh" run 01 --dry-run --yes --skip-nvidia 2>&1 </dev/null); RC=$?
check "a short settings file: the core addresses are required for every stage" bash -c "[[ $RC -ne 0 ]] && grep -q 'LAPTOP_IP DESKTOP_IP ADMIN_USER' <<<\"\$0\"" "$OUT"

# ---- DRY_RUN in the environment is honoured like --dry-run (f16): no machinectl for a hermes stage
"$ROOT/setup.sh" configure --defaults --set LAPTOP_IP=10.0.0.20 --set DESKTOP_IP=10.0.0.30 --set ROUTER_IP=10.0.0.1 --set ADMIN_USER=james --set GITHUB_ORG=acme --set GITHUB_REPOS=app --set GITHUB_NOREPLY_EMAIL=42+acme-hermes@users.noreply.github.com >/dev/null 2>&1
OUT=$(DRY_RUN=1 "$ROOT/setup.sh" run 05 --yes 2>&1 </dev/null); RC=$?
check "DRY_RUN=1 in the environment keeps a hermes stage from running for real" bash -c "[[ $RC -eq 0 ]] && grep -q 'dry-run' <<<\"\$0\" && ! grep -q machinectl <<<\"\$0\"" "$OUT"

# ---- scripted answers are shared with the stage the dispatcher starts (fd inheritance, f43)
rm -f "$f"
{ first_run; } >"$T/a-share"
printf '%s\n' 10.0.0.20 10.0.0.30 10.0.0.1 '' james acme 'api web' '' 42+acme-hermes@users.noreply.github.com \
  vendor-a/worker vendor-b/reviewer vendor-a/mid vendor-c/fallback '' '' n n '' y >"$T/a-share"   # ...wizard answers, then Docker? y
OUT=$(HS_INPUT="$T/a-share" "$ROOT/setup.sh" run 04 --dry-run 2>&1 </dev/null); RC=$?
check "the wizard and the stage read ONE answer stream (stage 04's Docker question got the 'y')" bash -c "[[ $RC -eq 0 ]] && grep -q 'usermod -aG docker' <<<\"\$0\"" "$OUT"

# ---- a leftover done-marker cannot hide a failed re-run (f59), and a success writes one
CP=$T/kit; mkdir -p "$CP"; tar -C "$ROOT" --exclude=.git -cf - . | tar -C "$CP" -xf -
cat >"$CP/laptop/99-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# TITLE: probe stage for the dispatcher test
# RUN-AS: admin
# GUIDE: test
# NEEDS: -
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
load_config
stage_begin
[[ -e ${PROBE_FAIL_FLAG:-/nonexistent} ]] && die "probe failed on purpose"
stage_end
PROBE
chmod +x "$CP/laptop/99-probe.sh"
printf 'LAPTOP_IP=10.0.0.20\nDESKTOP_IP=10.0.0.30\nADMIN_USER=james\n' >"$f"
marker=$DESTDIR/var/lib/harness-setup/done/99
mkdir -p "$(dirname "$marker")"; echo old >"$marker"
touch "$T/failflag"
OUT=$(PROBE_FAIL_FLAG="$T/failflag" "$CP/setup.sh" run 99 --yes 2>&1 </dev/null); RC=$?
check "failed re-run: the old done-marker is gone" test ! -e "$marker"
check "failed re-run: the dispatcher exits non-zero" test $RC -ne 0
OUT=$("$CP/setup.sh" run 99 --yes 2>&1 </dev/null); RC=$?
check "successful run writes the marker" test -s "$marker"
check "list shows it done" bash -c "NODE_ENV='$f' DESTDIR='$DESTDIR' '$CP/setup.sh' list | grep -qE '^99 .*\[done\]'"

# ---- publish_shared: the settings the dispatcher used are what the agent gets, swapped in whole (f56, f58)
sh=$T/shared; mkdir -p "$sh"; echo stale >"$sh/stale-file"
printf 'LAPTOP_IP=10.9.9.9\nDESKTOP_IP=10.9.9.8\nADMIN_USER=elsewhere\n' >"$T/elsewhere.env"
HS_SHARED="$sh" NODE_ENV="$T/elsewhere.env" DESTDIR='' DRY_RUN=0 bash -c 'source "$1/lib/common.sh"; publish_shared' _ "$ROOT" >/dev/null 2>&1
check "publish: the copy has the settings file that was in use (NODE_ENV), not the repo default" grep -q 'ADMIN_USER=elsewhere' "$sh/config/node.env"
check "publish: the old shared copy is replaced" test ! -e "$sh/stale-file"
check "publish: no half-built or old directories are left behind" test -z "$(ls -d "$sh".new "$sh".old 2>/dev/null)"
check "publish: scripts keep their executable bit" test -x "$sh/setup.sh"

# ---- check really validates (f6)
printf 'LAPTOP_IP=10.0.0.20\nDESKTOP_IP=10.0.0.30\nADMIN_USER=james\nDASHBOARD_PORT=70000\n' >"$f"
OUT=$("$ROOT/setup.sh" check 2>&1 </dev/null); RC=$?
check "check: an invalid setting fails and is named with the reason" bash -c "[[ $RC -ne 0 ]] && grep -q 'DASHBOARD_PORT' <<<\"\$0\" && grep -q 'port number' <<<\"\$0\"" "$OUT"
sed -i '/^DASHBOARD_PORT/d' "$f"
OUT=$("$ROOT/setup.sh" check 2>&1 </dev/null); RC=$?
check "check: a valid file passes" test $RC -eq 0
check "check: ...and lists what will be asked later" has "not set yet: GITHUB_ORG"

# ---- first-run: settings that cannot be known yet may be left for later (f32)
rm -f "$f"
printf '%s\n' 10.0.0.20 10.0.0.30 10.0.0.1 '' james '' '' '' '' '' '' '' '' '' '' n n '' >"$T/a-later"
OUT=$(NODE_ENV="$f" "$ROOT/setup.sh" configure --answers "$T/a-later" 2>&1); RC=$?
check "wizard: Enter leaves GitHub and model settings for later" test $RC -eq 0
check "wizard: ...it says so" has "left for later"
check "wizard: ...and the file marks them as not set yet" grep -q '# GITHUB_ORG=   (not set yet' "$f"
check "wizard: the machine-account question has no bogus derived default" has "Enter to answer later"
OUT=$("$ROOT/setup.sh" run 05 --dry-run --yes 2>&1 </dev/null); RC=$?
check "...but a stage that needs them still insists (just in time)" bash -c "[[ $RC -ne 0 ]] && grep -q 'GITHUB_ORG' <<<\"\$0\"" "$OUT"

# ---- NEEDS "KEY=VALUE": offer to change the setting, never silently (f18)
printf 'LAPTOP_IP=10.0.0.20\nDESKTOP_IP=10.0.0.30\nADMIN_USER=james\nGITHUB_ORG=acme\nGITHUB_REPOS=app\nNIGHT_ENABLED=0\n' >"$f"
export HOME="$T/home"; mkdir -p "$HOME/.hermes/profiles/local"; printf 'model:\n  provider: x\n' >"$HOME/.hermes/profiles/local/config.yaml"
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"
OUT=$("$ROOT/setup.sh" tool overnight-laptop --dry-run --yes 2>&1 </dev/null); RC=$?
check "overnight tier off, no terminal: refuses and gives the exact command" bash -c "[[ $RC -ne 0 ]] && grep -q 'configure --set NIGHT_ENABLED=1' <<<\"\$0\"" "$OUT"
check "...and left the setting alone" grep -q '^NIGHT_ENABLED=0' "$f"
printf 'y\n\n\nraise coverage\n' >"$T/a-night"   # change it? y; (start/end default prompts are not asked: both have literal defaults); task text
printf 'y\nraise coverage\n' >"$T/a-night"
OUT=$(HS_INPUT="$T/a-night" "$ROOT/setup.sh" tool overnight-laptop --dry-run 2>&1 </dev/null); RC=$?
check "overnight tier off, with a terminal: offers to turn it on and carries on" test $RC -eq 0
check "...the setting was saved" grep -q '^NIGHT_ENABLED=1' "$f"
check "...the job time follows NIGHT_START (01:00 + 15 min), not a hard-coded 2am" has 'daily\ at\ 1:15am'
sed -i 's/^NIGHT_START=.*/NIGHT_START=03:30/; s/^NIGHT_END=.*/NIGHT_END=09:00/' "$f"
printf 'raise coverage\n' >"$T/a-night2"
OUT=$(HS_INPUT="$T/a-night2" "$ROOT/setup.sh" tool overnight-laptop --dry-run 2>&1 </dev/null)
check "custom overnight window: the job time follows it" has 'daily\ at\ 3:45am'
check "custom overnight window: the printed rules follow it" has "jobs run 03:45-07:00"

# ---- the smoke test only accepts a configured repo (f10)
mkdir -p "$HOME/repos/app/.git"
OUT=$("$ROOT/setup.sh" tool github-smoke-test --dry-run --yes --repo ../../etc 2>&1 </dev/null); RC=$?
check "smoke test: a repo that is not configured is refused" bash -c "[[ $RC -ne 0 ]] && grep -q 'not one of your repositories' <<<\"\$0\"" "$OUT"

echo "dispatcher config: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
