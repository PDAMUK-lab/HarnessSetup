#!/usr/bin/env bash
# Sandboxed REAL runs (not dry runs) of the hermes-user stages: HOME is a temp dir and the external
# tools (hermes, gh, systemctl, ss, curl) are stubs from tests/fakebin that record their calls.
# GitHub's rulesets are emulated by a pre-receive hook on a local bare repo.
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
logged() { grep -qF -- "$1" "$FAKE_LOG"; }
cfgmissing() { ! python3 "$ROOT/lib/merge_yaml.py" "$1" --get "$2" >/dev/null 2>&1; }
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
check "06: the installer ran with --skip-setup (no wizard of its own)" grep -qx -- "--skip-setup" "$HOME/.hermes-install-args"
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
check "07: terminal cwd is the agent's real ~/repos" test "$(cfgget "$cfg" terminal.cwd)" = "$HOME/repos"
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
# no session bus and no lingering user manager either (CI runners have /run/user/<uid>, so point the lookup elsewhere)
OUT=$(XDG_RUNTIME_DIR='' HS_RUN_USER_DIR="$T/no-run-user" bash "$ROOT"/laptop/08-*.sh 2>&1); RC=$?
check "08: refuses without a user session" rc_nz_and_has machinectl

# ---- 11 local endpoints, fallback chain, local profile, hermes-mode
: >"$FAKE_LOG"
OUT=$(DESKTOP_LLM_KEY='key with space' bash "$ROOT"/laptop/11-*.sh 2>&1); RC=$?
check "11: rejects a key containing spaces" rc_nz_and_has "spaces or quotes"
stage_with_key() { OUT=$(DESKTOP_LLM_KEY=abc123def bash "$ROOT"/laptop/11-*.sh 2>&1); RC=$?; }
stage_with_key
check "11: exits 0" test $RC -eq 0
check "11: key stored in ~/.hermes/.env" grep -qx 'DESKTOP_LLM_KEY=abc123def' "$HOME/.hermes/.env"
check "11: .env stays private" test "$(stat -c %a "$HOME/.hermes/.env")" = 600
check "11: desktop endpoint registered" test "$(cfgget "$cfg" providers.desktop.api)" = http://192.168.1.100:8080/v1
check "11: laptop endpoint registered (loopback)" test "$(cfgget "$cfg" providers.laptop.api)" = http://127.0.0.1:8080/v1
check "11: desktop key comes from the env var, not the config" test "$(cfgget "$cfg" providers.desktop.key_env)" = DESKTOP_LLM_KEY
check "11: fallback chain is openrouter, desktop, laptop" test "$(python3 -c "import yaml;print(','.join(e['provider'] for e in yaml.safe_load(open('$cfg'))['fallback_providers']))")" = openrouter,custom:desktop,custom:laptop
check "11: second fallback model is the configured one" test "$(python3 -c "import yaml;print(yaml.safe_load(open('$cfg'))['fallback_providers'][0]['model'])")" = vendor-c/fallback
pc=$HOME/.hermes/profiles/local/config.yaml
check "11: local profile planner is the desktop model" test "$(cfgget "$pc" model.provider)/$(cfgget "$pc" model.default)" = custom:desktop/qwen3.6-35b-a3b
check "11: local profile has the laptop as its only fallback" test "$(python3 -c "import yaml;print(len(yaml.safe_load(open('$pc'))['fallback_providers']))")" = 1
check "11: local subagents run on the laptop (loopback base_url)" test "$(cfgget "$pc" delegation.base_url)" = http://127.0.0.1:8080/v1
check "11: leftover 'provider: openrouter' removed from delegation" cfgmissing "$pc" delegation.provider
check "11: cloud sub-agents fall back along the main chain" test "$(python3 -c "import yaml;print(','.join(e['provider'] for e in yaml.safe_load(open('$cfg'))['delegation']['fallback_providers']))")" = openrouter,custom:desktop,custom:laptop
check "11: local sub-agents fall back to the desktop only (never the cloud)" test "$(python3 -c "import yaml;print(','.join(e['provider'] for e in yaml.safe_load(open('$pc'))['delegation']['fallback_providers']))")" = custom:desktop
check "11: local profile gets the approval mode (its cron jobs and sub-agents run there)" test "$(cfgget "$pc" approvals.mode)" = off
check "11: local profile stops stuck sub-agents" test "$(cfgget "$pc" delegation.child_timeout_seconds)" = 1800
check "11: local profile carries the endpoints" test "$(cfgget "$pc" providers.laptop.context_length)" = 131072
sed -i 's/^LAPTOP_CTX=.*/LAPTOP_CTX=65536/' "$NODE_ENV"; stage_with_key
check "11 again: an existing local profile follows a changed laptop context" test "$(cfgget "$pc" providers.laptop.context_length)" = 65536
sed -i 's/^LAPTOP_CTX=.*/LAPTOP_CTX=131072/' "$NODE_ENV"; stage_with_key
sed -i 's/^APPROVAL_MODE=.*/APPROVAL_MODE=smart/' "$NODE_ENV"; stage 07
check "07 again: APPROVAL_MODE reaches both profiles" test "$(cfgget "$cfg" approvals.mode),$(cfgget "$pc" approvals.mode)" = smart,smart
sed -i 's/^APPROVAL_MODE=.*/APPROVAL_MODE=off/' "$NODE_ENV"; stage 07
check "07 again: and back" test "$(cfgget "$cfg" approvals.mode),$(cfgget "$pc" approvals.mode)" = off,off
check "11: review block uses the main model" test "$(cfgget "$pc" auxiliary.review.provider)" = main
check "11: review block keeps no stale OpenRouter model" cfgmissing "$pc" auxiliary.review.model
check "11: compression block keeps no stale OpenRouter model" cfgmissing "$pc" auxiliary.compression.model
check "11: local profile config never mentions openrouter" bash -c "! grep -qi openrouter '$pc'"
check "11: local profile .env has no OpenRouter key" bash -c "! grep -q OPENROUTER '$HOME/.hermes/profiles/local/.env'"
check "11: local profile .env keeps the desktop key" grep -qx 'DESKTOP_LLM_KEY=abc123def' "$HOME/.hermes/profiles/local/.env"
check "11: hermes-mode installed and executable" test -x "$HOME/.local/bin/hermes-mode"
check "11: hermes-mode targets the configured desktop" grep -q 'http://192.168.1.100:8080/health' "$HOME/.local/bin/hermes-mode"
check "11: records completion" done_marker 11
stage_with_key
check "11: re-run is idempotent" test $RC -eq 0
check "11: profile created exactly once" test "$(grep -c 'profile create local' "$FAKE_LOG")" -eq 1
out_lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }
check "11: no V100 hint while the tier is off" out_lacks 'v100-laptop'
mkdir -p "$HOME/.hermes/hermes-mode.d"; echo 'desktop-v100 x|http://h/health' >"$HOME/.hermes/hermes-mode.d/desktop-v100"
stage_with_key
check "11: a stale V100 probe is removed while the tier is off" test ! -e "$HOME/.hermes/hermes-mode.d/desktop-v100"
echo 'desktop-v100 x|http://h/health' >"$HOME/.hermes/hermes-mode.d/desktop-v100"
sed 's|^V100_ENABLED=.*|V100_ENABLED=1|' "$NODE_ENV" >"$T/v100.env"
OUT=$(NODE_ENV="$T/v100.env" DESKTOP_LLM_KEY=abc123def bash "$ROOT"/laptop/11-*.sh 2>&1); RC=$?
check "11: with the tier on, the stage still succeeds" test $RC -eq 0
check "11: ...keeps the V100 probe" test -e "$HOME/.hermes/hermes-mode.d/desktop-v100"
check "11: ...and puts the V100 endpoint first in the chain" test "$(python3 -c "import yaml;print(','.join(e['provider'] for e in yaml.safe_load(open('$cfg'))['fallback_providers']))")" = openrouter,custom:desktop-v100,custom:desktop,custom:laptop
rm -f "$HOME/.hermes/hermes-mode.d/desktop-v100"
hm=$HOME/.local/bin/hermes-mode
: >"$FAKE_LOG"
"$hm" local >/dev/null 2>&1
check "hermes-mode local switches the profile" logged "hermes profile use local"
"$hm" cloud >/dev/null 2>&1
check "hermes-mode cloud switches back" logged "hermes profile use default"
OUT=$("$hm" status 2>&1)
check "hermes-mode status probes all three endpoints" bash -c "grep -q laptop <<<'$OUT' && grep -q desktop <<<'$OUT' && grep -q openrouter <<<'$OUT'"
"$hm" bogus >/dev/null 2>&1; check "hermes-mode rejects unknown modes (exit 2)" test $? -eq 2

# ---- 12 skills and cron
: >"$FAKE_LOG"
stage 12
check "12: exits 0" test $RC -eq 0
check "12: /release skill in the default profile" test -f "$HOME/.hermes/skills/release/SKILL.md"
check "12: /release skill in the local profile" test -f "$HOME/.hermes/profiles/local/skills/release/SKILL.md"
check "12: skill front matter intact" grep -q '^name: release$' "$HOME/.hermes/skills/release/SKILL.md"
check "12: cron clone exists" test -d "$HOME/repos-cron/app/.git"
check "12: cron clone excludes worktrees" grep -qxF '.worktrees/' "$HOME/repos-cron/app/.git/info/exclude"
check "12: release-pending.sh is executable" test -x "$HOME/.hermes/scripts/release-pending.sh"
check "12: release-pending.sh points at the cron clone" grep -q "cd $HOME/repos-cron/app" "$HOME/.hermes/scripts/release-pending.sh"
check "12: nightly-tests created paused" bash -c "grep 'cron create' '$FAKE_LOG' | grep 'nightly-tests' | grep -q -- '--paused'"
check "12: release-watcher created paused by default" bash -c "grep 'cron create' '$FAKE_LOG' | grep 'release-watcher' | grep -q -- '--paused'"
check "12: release-watcher wired to the script and skill" bash -c "grep 'cron create' '$FAKE_LOG' | grep 'release-watcher' | grep -q -- '--script release-pending.sh --skill release'"
check "12: no cron.model set when CRON_MODEL is empty" bash -c "! grep -q 'config set cron.model' '$FAKE_LOG'"
stage 12
check "12: re-run creates no duplicate jobs" test "$(grep -c 'cron create' "$FAKE_LOG")" -eq 2
rm -f "$HOME/.hermes/fake-cron"; : >"$FAKE_LOG"
sed 's|^CRON_MODEL=.*|CRON_MODEL=cheap/model|' "$T/node.env" >"$T/cron.env"
OUT=$(NODE_ENV="$T/cron.env" bash "$ROOT"/laptop/12-*.sh --active 2>&1); RC=$?
check "12: --active creates the watcher running" bash -c "! grep 'cron create' '$FAKE_LOG' | grep 'release-watcher' | grep -q -- '--paused'"
check "12: CRON_MODEL is applied" logged "hermes config set cron.model cheap/model"

# ---- release-pending.sh (the zero-cost poll) against real git
git init -q --bare "$T/rp-origin.git"
rm -rf "$HOME/repos-cron/app" && git clone -q "$T/rp-origin.git" "$HOME/repos-cron/app" 2>/dev/null
( cd "$HOME/repos-cron/app" && git commit -q --allow-empty -m one && git push -q origin HEAD:main && git tag v1.1.0 && git push -q origin v1.1.0 )
rp=$HOME/.hermes/scripts/release-pending.sh
OUT=$(FAKE_PR_TITLES=$'Release v1.2.0\nRelease v1.1.0\n' bash "$rp"); 
check "release-pending: wakes the agent for a merged but untagged release" test "$OUT" = '{"wakeAgent": true, "context": {"version": "v1.2.0"}}'
OUT=$(FAKE_PR_TITLES=$'Release v1.1.0\n' bash "$rp")
check "release-pending: stays asleep when everything is tagged" test "$OUT" = '{"wakeAgent": false}'
OUT=$(FAKE_PR_TITLES='' bash "$rp")
check "release-pending: stays asleep with no release PRs" test "$OUT" = '{"wakeAgent": false}'
check "release-pending: searches the whole word Release (GitHub never matches a bare 'v' to 'v1.2.3')" grep -q -- "--search Release in:title" "$HOME/.gh-pr-list-args"
check "release-pending: asks for more than the default 30 PRs" grep -q -- "--limit 100" "$HOME/.gh-pr-list-args"
OUT=$(FAKE_PR_TITLES=$'Release prep for v1.9.0: notes\nNot a Release v1.8.0 PR\n' bash "$rp")
check "release-pending: PRs that merely mention a version do not wake the agent" test "$OUT" = '{"wakeAgent": false}'

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
OUT=$(FAKE_LOG="$T/smoke-gh.log" bash "$ROOT/tools/github-smoke-test.sh" --repo app --yes 2>&1); RC=$?
check "smoke: passes when the rules hold" test $RC -eq 0
check "smoke: reports seven PASS lines" test "$(grep -c 'PASS' <<<"$OUT")" -eq 7
check "smoke: tries to merge its own PR (the approval rule)" grep -q "gh pr merge hermes/smoke-" "$T/smoke-gh.log"
check "smoke: closes the PR and deletes its branch" grep -q "gh pr close hermes/smoke-.* --delete-branch" "$T/smoke-gh.log"
smoke_tag_off_main() { local t; for t in $(git -C "$T/origin.git" tag -l 'v0.0.0-smoke.*'); do git -C "$T/origin.git" merge-base --is-ancestor "$t" main && return 1; done; [[ -n $(git -C "$T/origin.git" tag -l 'v0.0.0-smoke.*') ]]; }
check "smoke: the pushed tag is on the throw-away commit, not on main (a release workflow must refuse it)" smoke_tag_off_main
check "smoke: leaves the clone on main with no leftover branch" bash -c "cd '$HOME/repos/app' && test \"\$(git branch --show-current)\" = main && test \"\$(git branch | wc -l)\" -eq 1"
check "smoke: leaves no local smoke tag" bash -c "cd '$HOME/repos/app' && test -z \"\$(git tag)\""
OUT=$(FAKE_REVIEW_DECISION='' bash "$ROOT/tools/github-smoke-test.sh" --repo app --yes 2>&1); RC=$?
check "smoke: a merge refused for another reason (no approval required) is a FAIL" bash -c "[[ $RC -ne 0 ]] && [[ \$(grep -c '  FAIL  ' <<<\"\$0\") -eq 1 ]] && grep -q 'does not require an approval' <<<\"\$0\"" "$OUT"
# (earlier runs' tags come back with every fetch: the agent cannot delete them, by design)
own_tag=$(grep -oE 'v0\.0\.0-smoke\.[0-9]+-[0-9]+' <<<"$OUT" | head -1)
check "smoke: ...and deletes its own local tag again" bash -c "[[ -n '$own_tag' ]] && ! git -C '$HOME/repos/app' tag | grep -qx '$own_tag'"
rm "$T/origin.git/hooks/pre-receive"
OUT=$(FAKE_PR_MERGE=ok bash "$ROOT/tools/github-smoke-test.sh" --repo app --yes 2>&1); RC=$?
check "smoke: FAILS when nothing is protected" test $RC -ne 0
check "smoke: flags exactly the four unprotected checks (incl. the unapproved merge)" test "$(grep -c '  FAIL  ' <<<"$OUT")" -eq 4

echo "real-run stages: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
