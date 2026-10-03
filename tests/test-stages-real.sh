#!/usr/bin/env bash
# Sandboxed REAL runs (not dry runs) of the hermes-user stages: HOME is a temp dir and the external
# tools (hermes, gh, systemctl, ss, curl) are stubs from tests/fakebin that record their calls.
# GitHub's rulesets are emulated by a pre-receive hook on a local bare repo.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
logged() { grep -qF -- "$1" "$FAKE_LOG"; }
cfgget() { python3 "$ROOT/lib/merge_yaml.py" "$1" --get "$2" 2>/dev/null; }

export HOME="$T/home" FAKE_LOG="$T/calls.log" HS_ALLOW_ANY_USER=1 XDG_RUNTIME_DIR="$T/run" DRY_RUN=0 ASSUME_YES=1
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"; : >"$FAKE_LOG"
REALPATH=$PATH
export PATH="$ROOT/tests/fakebin:$REALPATH"
sed -E \
  -e 's|^GITHUB_ORG=.*|GITHUB_ORG=acme|' -e 's|^GITHUB_REPOS=.*|GITHUB_REPOS="app lib"|' \
  -e 's|^GITHUB_MACHINE_USER=.*|GITHUB_MACHINE_USER=acme-bot|' -e 's|^GITHUB_NOREPLY_EMAIL=.*|GITHUB_NOREPLY_EMAIL=42+acme-bot@users.noreply.github.com|' \
  -e 's|^OR_WORKER_MODEL=.*|OR_WORKER_MODEL=vendor-a/worker|' -e 's|^OR_REVIEW_MODEL=.*|OR_REVIEW_MODEL=vendor-b/reviewer|' \
  -e 's|^OR_COMPRESSION_MODEL=.*|OR_COMPRESSION_MODEL=vendor-a/mid|' -e 's|^OR_FALLBACK_MODEL=.*|OR_FALLBACK_MODEL=vendor-c/fallback|' \
  "$ROOT/config/node.env.example" >"$T/node.env"
export NODE_ENV="$T/node.env"
stage() { local id=$1; shift; OUT=$(bash "$ROOT"/laptop/"$id"-*.sh "$@" 2>&1); RC=$?; }
rc_nz_and_has() { [[ $RC -ne 0 ]] && grep -qF -- "$1" <<<"$OUT"; }
done_marker() { test -f "$HOME/.harness-setup/done/$1"; }

# ---- 05 GitHub access (already-logged-in path; the token prompt itself needs a terminal)
echo acme-bot >"$HOME/.gh-logged-in"
stage 05
check "05: exits 0" test $RC -eq 0
check "05: sets up git credentials via gh" logged "gh auth setup-git"
check "05: git identity is the machine account" test "$(git config --global user.name)" = acme-bot
check "05: git email is the noreply address" test "$(git config --global user.email)" = 42+acme-bot@users.noreply.github.com
check "05: clones every repo" bash -c "test -d '$HOME/repos/app/.git' && test -d '$HOME/repos/lib/.git'"
check "05: worktrees are excluded from commits" grep -qxF '.worktrees/' "$HOME/repos/app/.git/info/exclude"
check "05: records completion" done_marker 05
stage 05
check "05: re-run is idempotent" test $RC -eq 0
check "05: re-run does not duplicate the exclude line" test "$(grep -cxF '.worktrees/' "$HOME/repos/app/.git/info/exclude")" -eq 1
sed 's|^GITHUB_ORG=.*|GITHUB_ORG=yourorg|' "$T/node.env" >"$T/ex.env"
OUT=$(NODE_ENV="$T/ex.env" bash "$ROOT"/laptop/05-*.sh 2>&1); RC=$?
check "05: refuses the example org name" rc_nz_and_has "example values"

# ---- 06 Hermes install: fresh machine (installer piped from a stub curl) and already installed
mkdir -p "$T/bin2" && cp "$ROOT/tests/fakebin/curl" "$T/bin2/curl"
rm -rf "$HOME/.local"
OUT=$(PATH="$T/bin2:/usr/bin:/bin" FAKE_HERMES_SRC="$ROOT/tests/fakebin/hermes" bash "$ROOT"/laptop/06-hermes-install.sh 2>&1); RC=$?
check "06: fresh install exits 0" test $RC -eq 0
check "06: hermes landed in ~/.local/bin" test -x "$HOME/.local/bin/hermes"
check "06: runs hermes doctor" logged "hermes doctor"
check "06: prints the manual 'hermes model' step" grep -q 'hermes model' <<<"$OUT"
check "06: records completion" done_marker 06
stage 06
check "06: already-installed path exits 0" test $RC -eq 0

# ---- 07 cloud config
mkdir -p "$HOME/.hermes"
printf 'model:\n  provider: openrouter\n  default: planner/best\ndisplay:\n  theme: dark\n' >"$HOME/.hermes/config.yaml"
echo 'OPENROUTER_API_KEY=sk-test' >"$HOME/.hermes/.env"
stage 07
check "07: exits 0" test $RC -eq 0
cfg=$HOME/.hermes/config.yaml
check "07: planner chosen by 'hermes model' is untouched" test "$(cfgget "$cfg" model.default)" = planner/best
check "07: workers get the configured model" test "$(cfgget "$cfg" delegation.model)" = vendor-a/worker
check "07: reviewer is set" test "$(cfgget "$cfg" auxiliary.review.model)" = vendor-b/reviewer
check "07: worktree isolation on" test "$(cfgget "$cfg" delegation.worktree_isolation)" = True
check "07: terminal backend local" test "$(cfgget "$cfg" terminal.backend)" = local
check "07: data collection denied" test "$(cfgget "$cfg" provider_routing.data_collection)" = deny
check "07: other settings preserved" test "$(cfgget "$cfg" display.theme)" = dark
check "07: re-run changes nothing" bash -c "bash '$ROOT'/laptop/07-*.sh 2>&1 | grep -q unchanged"
mv "$HOME/.hermes/config.yaml" "$T/saved.yaml"
OUT=$(bash "$ROOT"/laptop/07-*.sh 2>&1); RC=$?
check "07: refuses when 'hermes model' has not been run" rc_nz_and_has "hermes model"
mv "$T/saved.yaml" "$HOME/.hermes/config.yaml"
sed 's|^OR_WORKER_MODEL=.*|OR_WORKER_MODEL=|' "$T/node.env" >"$T/empty.env"
OUT=$(NODE_ENV="$T/empty.env" bash "$ROOT"/laptop/07-*.sh 2>&1); RC=$?
check "07: refuses an empty worker model" rc_nz_and_has OR_WORKER_MODEL

# ---- 08 services
: >"$FAKE_LOG"
stage 08
check "08: exits 0" test $RC -eq 0
check "08: installs the gateway" logged "hermes gateway install"
check "08: checks cron status" logged "hermes cron status"
unit=$HOME/.config/systemd/user/hermes-dashboard.service
check "08: dashboard unit uses the path of the hermes in use" grep -qxF "ExecStart=$HOME/.local/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open" "$unit"
check "08: enables and starts the dashboard" logged "systemctl --user enable --now hermes-dashboard"
check "08: reloads user units first" logged "systemctl --user daemon-reload"
check "08: reports loopback-only binding" grep -q 'listens on 127.0.0.1:9119 only' <<<"$OUT"
check "08: records completion" done_marker 08
OUT=$(FAKE_SS_ADDR=0.0.0.0:9119 bash "$ROOT"/laptop/08-*.sh 2>&1); RC=$?
check "08: FAILS if the dashboard listens beyond loopback" rc_nz_and_has "non-loopback"
OUT=$(XDG_RUNTIME_DIR='' bash "$ROOT"/laptop/08-*.sh 2>&1); RC=$?
check "08: refuses without a user session" rc_nz_and_has machinectl

# ---- tools/github-smoke-test.sh against a local bare repo that emulates the rulesets
git config --global init.defaultBranch main
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
( cd "$T/seed" && git commit -q --allow-empty -m seed && git push -q origin main )
rm -rf "$HOME/repos/app" && git clone -q "$T/origin.git" "$HOME/repos/app"
cat >"$T/origin.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
zero=0000000000000000000000000000000000000000
while read -r old new ref; do
  if [[ $ref == refs/heads/main ]]; then echo "ruleset: main is protected" >&2; exit 1; fi
  if [[ $new == "$zero" && $ref == refs/tags/* ]]; then echo "ruleset: tags cannot be deleted" >&2; exit 1; fi
  if [[ $new != "$zero" && $ref == refs/heads/* ]]; then
    base=$old; [[ $old == "$zero" ]] && base=$(git rev-parse refs/heads/main)
    if git diff --name-only "$base" "$new" | grep -q '^\.github/workflows/'; then echo "refusing to allow a workflow change" >&2; exit 1; fi
  fi
done
exit 0
HOOK
chmod +x "$T/origin.git/hooks/pre-receive"
OUT=$(bash "$ROOT/tools/github-smoke-test.sh" --repo app --yes 2>&1); RC=$?
check "smoke: passes when the rules hold" test $RC -eq 0
check "smoke: reports five PASS lines" test "$(grep -c 'PASS' <<<"$OUT")" -eq 5
check "smoke: leaves the clone on main with no leftover branch" bash -c "cd '$HOME/repos/app' && test \"\$(git branch --show-current)\" = main && test \"\$(git branch | wc -l)\" -eq 1"
check "smoke: leaves no local smoke tag" bash -c "cd '$HOME/repos/app' && test -z \"\$(git tag)\""
rm "$T/origin.git/hooks/pre-receive"
OUT=$(bash "$ROOT/tools/github-smoke-test.sh" --repo app --yes 2>&1); RC=$?
check "smoke: FAILS when nothing is protected" test $RC -ne 0
check "smoke: flags exactly the three unprotected checks" test "$(grep -c '  FAIL  ' <<<"$OUT")" -eq 3

echo "real-run stages: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
