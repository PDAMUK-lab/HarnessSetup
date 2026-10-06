#!/usr/bin/env bash
# Tests for tools/: verify, fallback-test, overnight-laptop, adopt-repo (sandboxed, stubbed externals).
# shellcheck disable=SC2016,SC2031  # backticks in the expected markdown are literal; $! is read in the same shell
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'kill ${srv1:-} ${srv2:-} ${srv3:-} 2>/dev/null; rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
has() { grep -qF -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
logged() { grep -qF -- "$1" "$FAKE_LOG"; }
lineno() { grep -nF -- "$1" "$FAKE_LOG" | head -1 | cut -d: -f1; }

export HOME="$T/home" FAKE_LOG="$T/calls.log" XDG_RUNTIME_DIR="$T/run" ASSUME_YES=1 DRY_RUN=0
export HS_AGENT_RUNNER="$ROOT/tests/fakebin/agent-runner.sh" HS_ALLOW_ANY_USER=1
mkdir -p "$HOME/.hermes/profiles/local" "$XDG_RUNTIME_DIR"; : >"$FAKE_LOG"
export PATH="$ROOT/tests/fakebin:$PATH"
sed -E \
  -e 's|^GITHUB_ORG=.*|GITHUB_ORG=acme|' -e 's|^GITHUB_REPOS=.*|GITHUB_REPOS="app"|' \
  -e 's|^OR_WORKER_MODEL=.*|OR_WORKER_MODEL=a/w|' -e 's|^OR_REVIEW_MODEL=.*|OR_REVIEW_MODEL=b/r|' \
  -e 's|^OR_COMPRESSION_MODEL=.*|OR_COMPRESSION_MODEL=a/m|' -e 's|^OR_FALLBACK_MODEL=.*|OR_FALLBACK_MODEL=c/f|' \
  "$ROOT/config/node.env.example" >"$T/node.env"
export NODE_ENV="$T/node.env"
# what stages 11 and 7 would have left behind
printf 'model:\n  provider: custom:desktop\n' >"$HOME/.hermes/profiles/local/config.yaml"
(
  source "$ROOT/lib/common.sh"; load_config
  install_template "$ROOT/templates/bin/hermes-mode.tpl" "$HOME/.local/bin/hermes-mode" 755 self
) >/dev/null 2>&1

# ================= verify.sh
OUT=$(bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: all automatable checks pass on a healthy node (exit 0)" test $RC -eq 0
check "verify: summary shows FAIL 0" has "FAIL 0"
check "verify: GPU check passes" bash -c "grep -E '^.*PASS.*#1 +nvidia-smi' <<<\"\$0\" >/dev/null" "$OUT"
check "verify: lists the manual checks" has "MANUAL"
check "verify: points at the smoke test for check 3" has "github-smoke-test"
check "verify: fallback order is checked" has "fallback chain: OpenRouter, then desktop, then laptop"
check "verify: loopback binding is checked" has "dashboard listens on loopback only"
check "verify: approval mode is a manual check while Hermes cannot say" has "approval mode is off in the default profile (dashboard Config page)"
pc=$HOME/.hermes/profiles/local/config.yaml
cp "$HOME/.hermes/config.yaml" "$T/cfg.keep" 2>/dev/null || true; cp "$pc" "$T/pc.keep"
printf 'approvals:\n  mode: "off"\n' >"$HOME/.hermes/config.yaml"
printf 'approvals:\n  mode: off\n' >>"$pc"   # a bare off is YAML false: Hermes prints false, which means off
OUT=$(bash "$ROOT/tools/verify.sh" --no-models 2>&1)
check "verify: approval mode off matches the setting in both profiles (PASS)" bash -c "grep -qE 'PASS.*#2 +approval mode is off in the default profile' <<<\"\$0\" && grep -qE 'PASS.*#2 +approval mode is off in the local profile' <<<\"\$0\"" "$OUT"
cp "$T/pc.keep" "$pc"; printf 'approvals:\n  mode: smart\n' >>"$pc"
OUT=$(bash "$ROOT/tools/verify.sh" --no-models 2>&1)
check "verify: a different approval mode in the local profile is a WARN naming both" has "approval mode is 'smart' in the local profile, the setting APPROVAL_MODE says 'off'"
if [[ -f $T/cfg.keep ]]; then cp "$T/cfg.keep" "$HOME/.hermes/config.yaml"; else rm -f "$HOME/.hermes/config.yaml"; fi
cp "$T/pc.keep" "$pc"
sed 's/^AGENT_SUDO=.*/AGENT_SUDO=limited/' "$NODE_ENV" >"$T/lim.env"
OUT=$(NODE_ENV="$T/lim.env" FAKE_SUDO_MODE=limited bash "$ROOT/tools/verify.sh" --no-models 2>&1)
check "verify: AGENT_SUDO=limited passes when only the allowed commands work" bash -c "grep -qE 'PASS.*#2 +hermes has limited sudo' <<<\"\$0\"" "$OUT"
OUT=$(NODE_ENV="$T/lim.env" bash "$ROOT/tools/verify.sh" --no-models 2>&1)
check "verify: AGENT_SUDO=limited fails when the agent can still run everything" bash -c "grep -qE 'FAIL.*#2 +hermes has only limited sudo' <<<\"\$0\"" "$OUT"
sed 's/^AGENT_SUDO=.*/AGENT_SUDO=none/' "$NODE_ENV" >"$T/none.env"
OUT=$(NODE_ENV="$T/none.env" FAKE_SUDO_MODE=none bash "$ROOT/tools/verify.sh" --no-models 2>&1)
check "verify: AGENT_SUDO=none passes without sudo" bash -c "grep -qE 'PASS.*#2 +hermes has no sudo' <<<\"\$0\"" "$OUT"
OUT=$(FAKE_NVIDIA=missing bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: a missing GPU fails the run" test $RC -eq 1
check "verify: ...and names check 1" has "#1"
OUT=$(FAKE_SS_ADDR=0.0.0.0:9119 bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: a dashboard on 0.0.0.0 fails the run" test $RC -eq 1
# DASHBOARD_FROM (browsers on the LAN): the dashboard must listen on the LAN behind a login, not loopback-only
sed 's/^DASHBOARD_FROM=.*/DASHBOARD_FROM=192.168.1.40/' "$NODE_ENV" >"$T/lan.env"
OUT=$(NODE_ENV="$T/lan.env" FAKE_SS_ADDR=0.0.0.0:9119 FAKE_AUTH_REQ=true bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: DASHBOARD_FROM: a LAN dashboard behind a login passes (exit 0)" test $RC -eq 0
check "verify: ...and check 6 passes both the login and the LAN bind" bash -c "grep -qE 'PASS.*#6 +dashboard requires a login' <<<\"\$0\" && grep -qE 'PASS.*#6 +dashboard listens on the LAN' <<<\"\$0\"" "$OUT"
OUT=$(NODE_ENV="$T/lan.env" FAKE_SS_ADDR=0.0.0.0:9119 FAKE_AUTH_REQ=false bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: DASHBOARD_FROM: a LAN dashboard without a login fails the run" test $RC -eq 1
check "verify: ...and names the missing login" has "dashboard requires a login"
OUT=$(NODE_ENV="$T/lan.env" FAKE_SS_ADDR=127.0.0.1:9119 FAKE_AUTH_REQ=true bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: DASHBOARD_FROM: a dashboard still on loopback fails the run" test $RC -eq 1
# SMB_SHARE (finished work): an unreachable share is a WARN, never a FAIL
sed 's|^SMB_SHARE=.*|SMB_SHARE=//192.168.1.20/work|' "$NODE_ENV" >"$T/smbv.env"
OUT=$(NODE_ENV="$T/smbv.env" bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: SMB_SHARE unavailable is a warning, not a failure" test $RC -eq 0
check "verify: ...and names the share and the fix" bash -c "grep -qE 'WARN.*#17' <<<\"\$0\" && grep -q 'is not writable at /srv/share' <<<\"\$0\" && grep -q 'smb-share' <<<\"\$0\"" "$OUT"
OUT=$(FAKE_MODEL_ID=something-else bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: wrong model alias fails the run" test $RC -eq 1

# models path against fake llama-servers (real curl)
port=$((20000 + RANDOM % 20000))
python3 "$ROOT/tests/fakebin/fake_llm.py" "$port" tool & srv1=$!
python3 "$ROOT/tests/fakebin/fake_llm.py" "$((port + 1))" prose & srv2=$!
sleep 1
sed -e "s|^LLM_PORT=.*|LLM_PORT=$port|" -e 's|^DESKTOP_IP=.*|DESKTOP_IP=127.0.0.1|' "$T/node.env" >"$T/models.env"
OUT=$(NODE_ENV="$T/models.env" FAKE_CURL_REAL=1 FAKE_MODEL_ID=x bash "$ROOT/tools/verify.sh" 2>&1)
check "verify: laptop tool call checked for real" has "laptop answers with a tool call"
check "verify: desktop tool call checked for real" has "desktop answers with a tool call"
check "verify: tool-call checks pass against a --jinja-like server" bash -c "! grep -E 'FAIL.*answers with a tool call' <<<\"\$0\"" "$OUT"
sed -i "s|^LLM_PORT=.*|LLM_PORT=$((port + 1))|" "$T/models.env"
OUT=$(NODE_ENV="$T/models.env" FAKE_CURL_REAL=1 bash "$ROOT/tools/verify.sh" 2>&1)
check "verify: prose answer (no --jinja) is a FAIL with a hint" bash -c "grep -E 'FAIL.*laptop answers with a tool call.*jinja' <<<\"\$0\"" "$OUT"
# the optional V100 tier: its own port, checked only when switched on
OUT=$(NODE_ENV="$T/models.env" FAKE_CURL_REAL=1 bash "$ROOT/tools/verify.sh" 2>&1)
check "verify: no V100 lines while the tier is off" lacks "V100 model"
python3 "$ROOT/tests/fakebin/fake_llm.py" "$((port + 3))" tool & srv3=$!
sleep 1
sed -e "s|^LLM_PORT=.*|LLM_PORT=$port|" -e 's|^DESKTOP_IP=.*|DESKTOP_IP=127.0.0.1|' -e 's|^V100_ENABLED=.*|V100_ENABLED=1|' -e "s|^V100_PORT=.*|V100_PORT=$((port + 3))|" "$T/node.env" >"$T/v100v.env"
OUT=$(NODE_ENV="$T/v100v.env" FAKE_CURL_REAL=1 FAKE_MODEL_ID=x bash "$ROOT/tools/verify.sh" 2>&1)
check "verify: V100 port is checked when the tier is on" has "V100 model port reachable"
check "verify: V100 tool call is checked for real" has "V100 model answers with a tool call"
check "verify: ...and passes against a --jinja-like server" bash -c "! grep -E 'FAIL.*V100' <<<\"\$0\"" "$OUT"
sed -i "s|^V100_PORT=.*|V100_PORT=$((port + 20))|" "$T/v100v.env"
OUT=$(NODE_ENV="$T/v100v.env" FAKE_CURL_REAL=1 FAKE_MODEL_ID=x bash "$ROOT/tools/verify.sh" --no-models 2>&1)
check "verify: an unreachable V100 server is a WARN (the desktop may be off)" bash -c "grep -E 'WARN.*V100 model port reachable' <<<\"\$0\"" "$OUT"

# the desktop taken out of the loop on purpose: verify accepts the shorter chain (as a WARN), fallback-test refuses
mkdir -p "$HOME/.hermes"; echo "since test" >"$HOME/.hermes/desktop-away"
OUT=$(bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: desktop away is a WARN about the chain, not a FAIL" bash -c "[[ $RC -eq 0 ]] && grep -E 'WARN.*the desktop is OUT of the loop' <<<\"\$0\"" "$OUT"
OUT=$(bash "$ROOT/tools/fallback-test.sh" --yes 2>&1); RC=$?
check "fallback-test: refuses while the desktop is away" bash -c "[[ $RC -ne 0 ]] && grep -q 'hermes-desktop on' <<<\"\$0\"" "$OUT"
rm -f "$HOME/.hermes/desktop-away"

# ================= fallback-test.sh
: >"$FAKE_LOG"; printf 'I am qwen3.6-35b-a3b\nI am qwen3.5-9b\nfile1 file2\n' >"$T/answers"
printf 'y\n\n' >"$T/ftans"   # Continue? y, then Enter when the desktop is asleep
OUT=$(ASSUME_YES=0 HS_INPUT="$T/ftans" FAKE_ANSWERS="$T/answers" bash "$ROOT/tools/fallback-test.sh" --sleep 2>&1); RC=$?
check "fallback-test: succeeds when every step answers" test $RC -eq 0
check "fallback-test: claims confirmation only when every step ran" has "fallback behaviour confirmed"
check "fallback-test: desktop answer recognised" has "answered by qwen3.6-35b-a3b"
check "fallback-test: laptop answer recognised" has "answered by qwen3.5-9b"
check "fallback-test: order is pause, cut internet, ask, restore, resume" bash -c "
  l() { grep -nF -- \"\$1\" '$FAKE_LOG' | head -1 | cut -d: -f1; }
  [[ \$(l 'hermes pause') -lt \$(l 'ufw insert 1 deny out 443/tcp') && \$(l 'ufw insert 1 deny out 443/tcp') -lt \$(l 'hermes chat') && \$(l 'hermes chat') -lt \$(l 'ufw delete deny out 443/tcp') && \$(l 'ufw delete deny out 443/tcp') -lt \$(l 'hermes resume') ]]"
check "fallback-test: local profile step ran" logged "hermes -p local chat"
: >"$FAKE_LOG"; printf 'FAIL\nI am qwen3.5-9b\nfiles\n' >"$T/answers"
OUT=$(ASSUME_YES=0 HS_INPUT="$T/ftans" FAKE_ANSWERS="$T/answers" bash "$ROOT/tools/fallback-test.sh" --sleep 2>&1); RC=$?
check "fallback-test: a failing step makes the run fail" test $RC -eq 1
check "fallback-test: failure explains the one-fallback-per-turn case" has "stops after one fallback"
check "fallback-test: firewall is restored even after a failure" logged "ufw delete deny out 443/tcp"
check "fallback-test: schedules resumed even after a failure" logged "hermes resume"
# without a terminal the sleep step cannot be done: it is reported as NOT tested, not as passed
: >"$FAKE_LOG"; printf 'I am qwen3.6-35b-a3b\nfiles\n' >"$T/answers"
OUT=$(FAKE_ANSWERS="$T/answers" bash "$ROOT/tools/fallback-test.sh" --yes 2>&1); RC=$?
check "fallback-test --yes: still exits 0 for the checks that ran" test $RC -eq 0
check "fallback-test --yes: says step 2 was NOT tested" has "NOT tested: step 2"
check "fallback-test --yes: does not claim the fallback is confirmed" lacks "fallback behaviour confirmed"
: >"$FAKE_LOG"
OUT=$(bash "$ROOT/tools/fallback-test.sh" --yes --dry-run 2>&1); RC=$?
check "fallback-test: dry run changes nothing" bash -c "test $RC -eq 0 && ! grep -q . '$FAKE_LOG'"

# ================= overnight-laptop.sh
: >"$FAKE_LOG"
OUT=$(bash "$ROOT/tools/overnight-laptop.sh" 2>&1); RC=$?
check "overnight: refuses while NIGHT_ENABLED=0" test $RC -ne 0
sed 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|' "$T/node.env" >"$T/night.env"
OUT=$(NODE_ENV="$T/night.env" bash "$ROOT/tools/overnight-laptop.sh" --task "raise coverage to 90%" 2>&1); RC=$?
pc=$HOME/.hermes/profiles/local/config.yaml
check "overnight: exits 0" test $RC -eq 0
check "overnight: adds the desktop-night endpoint" test "$(python3 "$ROOT/lib/merge_yaml.py" "$pc" --get providers.desktop-night.default_model)" = qwen3.8-27b
check "overnight: installs the local profile's own gateway" logged "hermes -p local gateway install"
check "overnight: job is pinned to the 27B and created paused" bash -c "grep 'cron create' '$FAKE_LOG' | grep -q -- '--provider custom:desktop-night --model qwen3.8-27b --name overnight-coverage --paused'"
check "overnight: job runs in the cron clone" bash -c "grep 'cron create' '$FAKE_LOG' | grep -q -- 'repos-cron/app'"
: >"$FAKE_LOG"
OUT=$(NODE_ENV="$T/night.env" bash "$ROOT/tools/overnight-laptop.sh" --task "again" 2>&1); RC=$?
check "overnight: re-run does not duplicate the job" bash -c "! grep -q 'cron create' '$FAKE_LOG'"

# ================= v100-laptop.sh
cfgy=$HOME/.hermes/config.yaml
printf 'model:\n  provider: openrouter\nfallback_providers:\n  - provider: openrouter\n    model: "c/f"\n  - provider: custom:desktop\n    model: qwen3.6-35b-a3b\n  - provider: custom:laptop\n    model: qwen3.5-9b\nproviders:\n  desktop:\n    api: http://192.168.1.100:8080/v1\n' >"$cfgy"
printf "DESKTOP_LLM_KEY=testkey\n" >"$HOME/.hermes/.env"
printf 'model:\n  provider: custom:desktop\n  default: qwen3.6-35b-a3b\ndelegation:\n  model: qwen3.5-9b\n' >"$HOME/.hermes/profiles/local/config.yaml"
yget() { python3 - "$1" "$2" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    d = d[int(part)] if isinstance(d, list) else d[part]
print(d)
PY
}
: >"$FAKE_LOG"
OUT=$(bash "$ROOT/tools/v100-laptop.sh" 2>&1); RC=$?
check "v100: refuses while V100_ENABLED=0" test $RC -ne 0
sed 's|^V100_ENABLED=.*|V100_ENABLED=1|' "$T/node.env" >"$T/v100.env"
sed 's|^V100_PORT=.*|V100_PORT=8080|' "$T/v100.env" >"$T/v100-same.env"
OUT=$(NODE_ENV="$T/v100-same.env" bash "$ROOT/tools/v100-laptop.sh" 2>&1); RC=$?
check "v100: refuses a port equal to the day server's" bash -c "[[ $RC -ne 0 ]] && grep -q 'V100_PORT and LLM_PORT' <<<\"\$0\"" "$OUT"
: >"$FAKE_LOG"; cp "$cfgy" "$T/config.before"
OUT=$(NODE_ENV="$T/v100.env" bash "$ROOT/tools/v100-laptop.sh" --dry-run 2>&1); RC=$?
check "v100: dry run exits 0 and changes nothing" bash -c "[[ $RC -eq 0 ]] && cmp -s '$cfgy' '$T/config.before' && [[ ! -e '$HOME/.hermes/hermes-mode.d/desktop-v100' ]]"
check "v100: dry run shows the endpoint it would add" has "http://192.168.1.100:8081/v1"
OUT=$(NODE_ENV="$T/v100.env" bash "$ROOT/tools/v100-laptop.sh" 2>&1); RC=$?
pc=$HOME/.hermes/profiles/local/config.yaml
check "v100: exits 0" test $RC -eq 0
check "v100: main config gets the endpoint" test "$(yget "$cfgy" providers.desktop-v100.api)" = http://192.168.1.100:8081/v1
check "v100: ...with the shared key variable" test "$(yget "$cfgy" providers.desktop-v100.key_env)" = DESKTOP_LLM_KEY
check "v100: the local profile gets the endpoint too" test "$(yget "$pc" providers.desktop-v100.default_model)" = qwen3.8-27b
check "v100: the existing desktop endpoint is kept" test "$(yget "$cfgy" providers.desktop.api)" = http://192.168.1.100:8080/v1
check "v100: chain is OpenRouter, V100, desktop, laptop" test "$(for i in 0 1 2 3; do yget "$cfgy" fallback_providers.$i.provider; done | tr '\n' ' ')" = "openrouter custom:desktop-v100 custom:desktop custom:laptop "
check "v100: the V100 is the local profile's first choice" test "$(yget "$pc" model.provider)/$(yget "$pc" model.default)" = custom:desktop-v100/qwen3.8-27b
check "v100: the local profile falls back to the desktop, then the laptop" test "$(yget "$pc" fallback_providers.0.provider) $(yget "$pc" fallback_providers.1.provider)" = "custom:desktop custom:laptop"
check "v100: other local profile settings are untouched" test "$(yget "$pc" delegation.model)" = qwen3.5-9b
check "v100: registers a hermes-mode probe" grep -qxF 'desktop-v100 qwen3.8-27b|http://192.168.1.100:8081/health' "$HOME/.hermes/hermes-mode.d/desktop-v100"
check "v100: reports the server as reachable" has "the V100 server answers on 192.168.1.100:8081"
HM=$(bash "$HOME/.local/bin/hermes-mode" status 2>&1)
check "v100: hermes-mode status shows the V100 line" grep -q '^desktop-v100 qwen3.8-27b *: 200' <<<"$HM"
check "v100: ...beside the day server's line" grep -q '^desktop (day model qwen3.6-35b-a3b) *: 200' <<<"$HM"
sed 's|^V100_PRIMARY=.*|V100_PRIMARY=0|' "$T/v100.env" >"$T/v100-second.env"
OUT=$(NODE_ENV="$T/v100-second.env" bash "$ROOT/tools/v100-laptop.sh" 2>&1); RC=$?
check "v100: V100_PRIMARY=0 puts the desktop model first" test "$(for i in 0 1 2 3; do yget "$cfgy" fallback_providers.$i.provider; done | tr '\n' ' ')" = "openrouter custom:desktop custom:desktop-v100 custom:laptop "
check "v100: ...and in the local profile" test "$(yget "$pc" model.provider) $(yget "$pc" fallback_providers.0.provider)" = "custom:desktop custom:desktop-v100"
rm -f "$HOME/.hermes/.env"
OUT=$(NODE_ENV="$T/v100.env" bash "$ROOT/tools/v100-laptop.sh" 2>&1); RC=$?
check "v100: without the desktop key it says to run stage 11" bash -c "[[ $RC -ne 0 ]] && grep -q 'run stage 11 first' <<<\"\$0\"" "$OUT"
printf "DESKTOP_LLM_KEY=testkey\n" >"$HOME/.hermes/.env"
OUT=$(NODE_ENV="$T/v100.env" FAKE_UFW_ACTIVE=1 FAKE_UFW_RULES='8080/tcp ALLOW OUT 192.168.1.100' bash "$ROOT/tools/v100-laptop.sh" 2>&1)
check "v100: warns when the firewall has no rule for the V100 port" has "re-run ./setup.sh run 13"
OUT=$(NODE_ENV="$T/v100.env" FAKE_UFW_ACTIVE=1 FAKE_UFW_RULES='8081/tcp ALLOW OUT 192.168.1.100' bash "$ROOT/tools/v100-laptop.sh" 2>&1)
check "v100: ...and stays quiet when the rule is there" lacks "re-run ./setup.sh run 13"
OUT=$(NODE_ENV="$T/v100.env" FAKE_HTTP_CODE=000 bash "$ROOT/tools/v100-laptop.sh" 2>&1); RC=$?
check "v100: an unreachable server is a warning, not a failure" bash -c "[[ $RC -eq 0 ]] && grep -q 'Install-V100.ps1' <<<\"\$0\"" "$OUT"

# ================= adopt-repo.sh
git init -q "$T/proj"
adopt() { OUT=$(bash "$ROOT/tools/adopt-repo.sh" "$@" 2>&1); RC=$?; }
adopt "$T/proj" --install 'npm ci' --test 'npm test' --package 'npm pack' --lint 'npm run lint' --version-file package.json
check "adopt: exits 0" test $RC -eq 0
check "adopt: writes AGENTS.md" test -f "$T/proj/AGENTS.md"
check "adopt: AGENTS.md carries the commands" grep -qF 'Test (must pass before any push): `npm test`' "$T/proj/AGENTS.md"
check "adopt: AGENTS.md carries the version file" grep -qF 'Version lives in: `package.json`' "$T/proj/AGENTS.md"
check "adopt: AGENTS.md has no leftover tokens" bash -c "! grep -q '@@' '$T/proj/AGENTS.md'"
check "adopt: writes both workflows" bash -c "test -f '$T/proj/.github/workflows/test.yml' && test -f '$T/proj/.github/workflows/release.yml'"
wfcheck() { python3 - "$1" "$2" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
runs = [s.get("run", "").strip() for s in wf["jobs"][sys.argv[2]]["steps"] if "run" in s]
assert "npm ci" in runs and "npm test" in runs, runs
PY
}
check "adopt: test.yml is valid YAML with the commands" wfcheck "$T/proj/.github/workflows/test.yml" test
check "adopt: release.yml is valid YAML with the commands" wfcheck "$T/proj/.github/workflows/release.yml" release
check "adopt: release.yml packages with the package command" grep -qF 'npm pack' "$T/proj/.github/workflows/release.yml"
echo "custom" >"$T/proj/AGENTS.md"
adopt "$T/proj" --install 'npm ci' --test 'npm test' --package 'npm pack'
check "adopt: never overwrites an existing file" test "$(cat "$T/proj/AGENTS.md")" = custom
check "adopt: says what it left alone" has "left alone: AGENTS.md"
adopt "$T/proj" --install 'npm ci' --test 'npm test' --package 'npm pack' --force
check "adopt: --force overwrites" grep -q 'Agent rules' "$T/proj/AGENTS.md"
git init -q "$T/proj2"
adopt "$T/proj2" --install 'pip install -e .' --test 'pytest -q -k "a: b"' --package 'python -m build' --no-workflows
check "adopt: --no-workflows skips the workflows" test ! -d "$T/proj2/.github"
adopt "$T/proj2" --install 'pip install -e .' --test 'pytest -q -k "a: b"' --package 'python -m build' --force
check "adopt: commands with colons and quotes stay valid YAML" python3 -c "
import yaml; wf=yaml.safe_load(open('$T/proj2/.github/workflows/test.yml'))
assert any('pytest -q -k \"a: b\"' in s.get('run','') for s in wf['jobs']['test']['steps'])"
adopt "$T/proj2" --install 'x' --test 'y'
check "adopt: requires --package" test $RC -ne 0
adopt "$T" --install x --test y --package z
check "adopt: refuses a non-git directory" test $RC -ne 0
adopt "$T/proj2" --install 'a @@ b' --test y --package z
check "adopt: refuses commands containing @@" test $RC -ne 0
adopt "$T/proj2" --install $'npm ci\r- run: evil' --test y --package z
check "adopt: refuses a carriage return in a command (it could inject workflow steps)" test $RC -ne 0
OUT=$("$ROOT/setup.sh" tool adopt-repo "$T/proj2" --install x --test y --package z 2>&1); RC=$?
check "setup.sh tool adopt-repo works through the dispatcher" test $RC -eq 0

# ---- dashboard login (tools/dashboard-login.sh): Hermes's scrypt format, the password never stored
mkdir -p "$HOME/.hermes"; [[ -f $HOME/.hermes/config.yaml ]] || echo 'model: x' >"$HOME/.hermes/config.yaml"
OUT=$(printf 'me\nshort\nshort\n' | bash "$ROOT/tools/dashboard-login.sh" 2>&1); RC=$?
check "dashboard-login: a short password is refused" test $RC -ne 0
OUT=$(printf 'me\ncorrect horse battery\ncorrect horse battery\n' | bash "$ROOT/tools/dashboard-login.sh" 2>&1); RC=$?
check "dashboard-login: exits 0" test $RC -eq 0
check "dashboard-login: writes a hash Hermes verifies, a secret, and no plain password" python3 -c "
import base64, hashlib, sys, yaml
c = yaml.safe_load(open(sys.argv[1]))['dashboard']['basic_auth']
s, n, r, p, salt, dk = c['password_hash'].split('\$')
ok = s == 'scrypt' and hashlib.scrypt(b'correct horse battery', salt=base64.b64decode(salt), n=int(n), r=int(r), p=int(p), dklen=32, maxmem=0) == base64.b64decode(dk)
sys.exit(0 if ok and c['username'] == 'me' and len(c['secret']) == 64 and 'correct horse' not in open(sys.argv[1]).read() else 1)" "$HOME/.hermes/config.yaml"

# ---- SMB share for finished work (tools/smb-share.sh)
OUT=$(printf 'u\np\n' | bash "$ROOT/tools/smb-share.sh" --dry-run 2>&1); RC=$?
check "smb-share: refuses while SMB_SHARE is none" bash -c "[[ $RC -ne 0 ]] && grep -q 'SMB_SHARE is none' <<<\"\$0\"" "$OUT"
sed 's|^SMB_SHARE=.*|SMB_SHARE=//192.168.1.20/work|' "$NODE_ENV" >"$T/smb.env"
OUT=$(printf '%s\n%s\n' 'OFFICE\nas-user' secret | NODE_ENV="$T/smb.env" DRY_RUN_SHOW=1 bash "$ROOT/tools/smb-share.sh" --dry-run 2>&1); RC=$?
check "smb-share: exits 0" test $RC -eq 0
check "smb-share: credentials root-only, with the domain split off" bash -c "grep -q 'hermes-smb.cred (mode 600' <<<\"\$0\" && grep -q 'username=nas-user' <<<\"\$0\" && grep -q 'domain=OFFICE' <<<\"\$0\"" "$OUT"
check "smb-share: a cifs mount at /srv/share owned by the agent, mounted on first use" bash -c "grep -q 'What=//192.168.1.20/work' <<<\"\$0\" && grep -q 'Where=/srv/share' <<<\"\$0\" && grep -q 'enable --now srv-share.automount' <<<\"\$0\"" "$OUT"

# ---- OpenRouter credit (tools/spend.sh, verify check 4, lib/common.sh or_spend)
spend_level() { ( source "$ROOT/lib/common.sh"; or_spend "$1" | cut -d'|' -f1 ); }
check "spend: 20% of a monthly limit is fine" test "$(spend_level '{"data":{"limit":50,"limit_remaining":40,"limit_reset":"monthly"}}')" = ok
check "spend: 85% warns (SPEND_WARN_PCT 80)" test "$(spend_level '{"data":{"limit":50,"limit_remaining":7.5,"limit_reset":"monthly"}}')" = warn
check "spend: a used-up limit fails" test "$(spend_level '{"data":{"limit":50,"limit_remaining":0,"limit_reset":"monthly"}}')" = fail
check "spend: no limit at all warns" test "$(spend_level '{"data":{"limit":null,"usage":3}}')" = warn
check "spend: a limit that never resets warns" test "$(spend_level '{"data":{"limit":50,"limit_remaining":45,"limit_reset":null}}')" = warn
check "spend: an unreadable answer is unknown" test "$(spend_level 'not json')" = unknown
mkdir -p "$HOME/.hermes"; cp "$HOME/.hermes/.env" "$T/env.keep" 2>/dev/null || : >"$T/env.keep"
echo 'OPENROUTER_API_KEY=sk-or-test' >>"$HOME/.hermes/.env"
OUT=$(bash "$ROOT/tools/spend.sh" 2>&1); RC=$?
check "spend tool: reports the month's spend and exits 0" bash -c "[[ $RC -eq 0 ]] && grep -qF 'spent \$10.00 of \$50.00 this month (20%)' <<<\"\$0\"" "$OUT"
OUT=$(FAKE_OR_KEY='{"data":{"limit":50,"limit_remaining":5,"limit_reset":"monthly"}}' bash "$ROOT/tools/spend.sh" 2>&1); RC=$?
check "spend tool: exits 1 near the limit" test $RC -eq 1
OUT=$(bash "$ROOT/tools/verify.sh" --no-models 2>&1)
check "verify: shows the OpenRouter credit (check 4)" bash -c "grep -qE 'PASS.*#4 +OpenRouter credit: spent' <<<\"\$0\"" "$OUT"
cp "$T/env.keep" "$HOME/.hermes/.env"

# ---- backup and restore of the agent's state (real run in the sandbox)
ah="$T/agent-home"; mkdir -p "$ah/.hermes/hermes-agent" "$ah/.hermes/cache" "$ah/.config/gh"
echo 'model: original' >"$ah/.hermes/config.yaml"; echo 'oauth_token: x' >"$ah/.config/gh/hosts.yml"; echo blob >"$ah/.hermes/hermes-agent/big"
python3 -c "import sqlite3; c=sqlite3.connect('$ah/.hermes/state.db'); c.execute('pragma journal_mode=wal'); c.execute('create table t(x)'); c.execute('insert into t values (42)'); c.commit()"
bk() { OUT=$(HS_AGENT_HOME="$ah" HS_BACKUP_DIR="$T/backups" bash "$ROOT/tools/backup.sh" 2>&1); RC=$?; }
bk
arc=$(find "$T/backups" -name "hermes-node-*.tar.gz" -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d" " -f2-)
check "backup: exits 0 and writes an archive" bash -c "[[ $RC -eq 0 && -s '$arc' ]]"
check "backup: holds the config, the GitHub login and the kit's settings" bash -c "tar -tzf '$arc' | grep -q '/.hermes/config.yaml$' && tar -tzf '$arc' | grep -q '/.config/gh/hosts.yml$' && tar -tzf '$arc' | grep -q 'node.env$'"
check "backup: only the backed-up paths, no parent folders (a restore would chmod / and chown the agent's home)" bash -c "! tar -tzf '$arc' | grep -qE '^\\./|^\\.\$|^${T#/}/\$|^${ah#/}/\$'"
check "backup: leaves out Hermes's own checkout and caches" bash -c "! tar -tzf '$arc' | grep -qE '/.hermes/(hermes-agent|cache)/'"
snap() { local d; d=$(mktemp -d); tar -C "$d" -xzf "$arc" && python3 -c "import os,sqlite3,sys; f=[os.path.join(r,'state.db') for r,_,fs in os.walk('$d') if 'state.db' in fs][0]; nowal=not os.path.exists(f+'-wal'); sys.exit(0 if nowal and sqlite3.connect(f).execute('select x from t').fetchone()[0]==42 else 1)"; }
check "backup: the SQLite database is a consistent snapshot" snap
check "backup: readable by owner and group only" test "$(stat -c %a "$arc")" = 640
sed -i 's/^BACKUP_KEEP=.*/BACKUP_KEEP=2/' "$NODE_ENV"; bk; bk
check "backup: keeps the newest BACKUP_KEEP" test "$(find "$T/backups" -name "hermes-node-*.tar.gz" | wc -l)" = 2
sed -i 's/^BACKUP_KEEP=.*/BACKUP_KEEP=14/' "$NODE_ENV"
arc=$(find "$T/backups" -name "hermes-node-*.tar.gz" -printf "%T@ %p\n" | sort -rn | head -1 | cut -d" " -f2-)
echo 'model: changed' >"$ah/.hermes/config.yaml"
OUT=$(HS_AGENT_HOME="$ah" bash "$ROOT/tools/restore.sh" "$arc" --yes 2>&1); RC=$?
check "restore: exits 0 and brings the backed-up config back" bash -c "[[ $RC -eq 0 ]] && grep -qx 'model: original' '$ah/.hermes/config.yaml'"
check "restore: keeps the state it replaced" bash -c "grep -qx 'model: changed' '$ah'/.hermes.before-restore-*/config.yaml"
check "restore: keeps the current settings and saves the backed-up ones beside them" bash -c "ls '$NODE_ENV'.from-backup-* >/dev/null && test -s '$NODE_ENV'"
check "restore: stops and starts the services" bash -c "grep -q 'systemctl --user stop hermes-dashboard hermes-gateway' '$FAKE_LOG' && grep -q 'systemctl --user start hermes-dashboard' '$FAKE_LOG'"
OUT=$(bash "$ROOT/tools/restore.sh" "$T/nope.tar.gz" --yes 2>&1); RC=$?
check "restore: a missing file is refused" test $RC -ne 0
OUT=$(bash "$ROOT/tools/backup.sh" --install --dry-run 2>&1)
check "backup --install: a daily timer at BACKUP_TIME" bash -c "grep -q 'hermes-backup.timer' <<<\"\$0\" && grep -q 'enable --now hermes-backup.timer' <<<\"\$0\"" "$OUT"

# ---- update-llama.sh: rebuild, test, roll back on failure (the build is a stub that writes a new llama-server)
lp="$T/llama"; mkdir -p "$lp/bin"
printf '#!/bin/sh\necho "version: 100 (old)"\n' >"$lp/bin/llama-server"; chmod +x "$lp/bin/llama-server"
newbuild="printf '#!/bin/sh\\necho \"version: 200 (new)\"\\n' >'$lp/bin/llama-server'"
upd() { OUT=$(HS_LLAMA_PREFIX="$lp" HS_LLAMA_BUILD="$newbuild" bash "$ROOT/tools/update-llama.sh" "$@" 2>&1); RC=$?; }
upd
check "update-llama: a build that serves tool calls is kept" bash -c "[[ $RC -eq 0 ]] && grep -q '200 (new)' '$lp/bin/llama-server' && grep -q '100 (old)' '$lp/bin.prev/llama-server'"
check "update-llama: restarts the service" grep -q 'systemctl restart llama-server' "$FAKE_LOG"
printf '#!/bin/sh\necho "version: 100 (old)"\n' >"$lp/bin/llama-server"
OUT=$(FAKE_TOOLCALL=no HS_LLAMA_PREFIX="$lp" HS_LLAMA_BUILD="$newbuild" bash "$ROOT/tools/update-llama.sh" 2>&1); RC=$?
check "update-llama: a build without tool calls is rolled back" bash -c "[[ $RC -ne 0 ]] && grep -q '100 (old)' '$lp/bin/llama-server' && grep -q '200 (new)' '$lp/bin.failed/llama-server'"
check "update-llama: says it rolled back" has "putting the previous one back"
upd --rollback
check "update-llama --rollback: puts the kept build back" bash -c "[[ $RC -eq 0 ]] && grep -q '100 (old)' '$lp/bin/llama-server'"

# ---- model-test.sh: a task set against a model (the hermes stub "does" a task by creating the file it names)
git init -q --bare "$T/mt-origin.git"; rm -rf "$HOME/repos/mt"; git clone -q "$T/mt-origin.git" "$HOME/repos/mt" 2>/dev/null
( cd "$HOME/repos/mt" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git push -q origin HEAD:main && git remote set-head origin main )
printf '# comment\nmakes-file | mt | test -f done.txt | Please create done.txt in the repo.\nnever-done | mt | test -f other.txt | Explain the code, change nothing.\n' >"$T/tasks.txt"
OUT=$(bash "$ROOT/tools/model-test.sh" --file "$T/tasks.txt" --provider custom:laptop --model m9 2>&1); RC=$?
check "model-test: runs every task and reports the pass rate" bash -c "grep -q 'm9: 1 of 2 passed' <<<\"\$0\" && [[ $RC -ne 0 ]]" "$OUT"
check "model-test: records each task in results.csv" bash -c "grep -q ',m9,local,custom:laptop,m9,makes-file,pass,' '$HOME/model-tests/results.csv' && grep -q ',never-done,fail,' '$HOME/model-tests/results.csv'"
check "model-test: passes the model and provider to hermes and reads the prompt from a file" grep -q 'hermes -p local chat --query-file .* --provider custom:laptop --model m9' "$FAKE_LOG"
check "model-test: removes its worktrees and leaves the clone untouched" bash -c "[[ \$(git -C '$HOME/repos/mt' worktree list | wc -l) -eq 1 && ! -e '$HOME/repos/mt/done.txt' ]]"
OUT=$(bash "$ROOT/tools/model-test.sh" --file "$T/tasks.txt" --only makes-file --label base 2>&1); RC=$?
check "model-test: --only runs one task; all passing exits 0" bash -c "[[ $RC -eq 0 ]] && grep -q 'base: 1 of 1 passed' <<<\"\$0\"" "$OUT"
OUT=$(bash "$ROOT/tools/model-test.sh" --file "$T/missing.txt" 2>&1); RC=$?
check "model-test: a missing task file points at the example" bash -c "[[ $RC -ne 0 ]] && grep -q 'model-tests.example' <<<\"\$0\"" "$OUT"

# ---- the kit's own release (.github/workflows/release.yml uses these)
check "release notes: the VERSION file's section exists in CHANGELOG.md" bash -c "[[ -n \$(bash '$ROOT/.github/scripts/release-notes.sh') ]]"
check "release notes: a section stops at the next heading" bash -c "! bash '$ROOT/.github/scripts/release-notes.sh' 0.3.1 | grep -q '^## '"
check "release notes: an unknown version fails" bash -c "! bash '$ROOT/.github/scripts/release-notes.sh' 9.9.9 2>/dev/null"
check "release notes: a malformed version fails" bash -c "! bash '$ROOT/.github/scripts/release-notes.sh' v1 2>/dev/null"
check "release workflow: valid YAML that tags only an untagged VERSION and publishes the notes" python3 -c "
import yaml,sys
w=yaml.safe_load(open('$ROOT/.github/workflows/release.yml'))
on=w[True] if True in w else w['on']
assert on['push']['branches']==['main'] and on['push']['paths']==['VERSION']
steps=w['jobs']['release']['steps']; run='\n'.join(s.get('run','') for s in steps)
assert 'release-notes.sh' in run and 'gh release create' in run and '--target' in run and 'already released' in run
assert w['permissions']['contents']=='write'
"
check "VERSION is X.Y.Z" grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/VERSION"

echo "tools: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
