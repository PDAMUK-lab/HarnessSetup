#!/usr/bin/env bash
# Tests for tools/: verify, fallback-test, overnight-laptop, adopt-repo (sandboxed, stubbed externals).
# shellcheck disable=SC2016,SC2031  # backticks in the expected markdown are literal; $! is read in the same shell
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'kill ${srv1:-} ${srv2:-} 2>/dev/null; rm -rf "$T"' EXIT
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
OUT=$(FAKE_NVIDIA=missing bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: a missing GPU fails the run" test $RC -eq 1
check "verify: ...and names check 1" has "#1"
OUT=$(FAKE_SS_ADDR=0.0.0.0:9119 bash "$ROOT/tools/verify.sh" --no-models 2>&1); RC=$?
check "verify: a dashboard on 0.0.0.0 fails the run" test $RC -eq 1
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

# ================= fallback-test.sh
: >"$FAKE_LOG"; printf 'I am qwen3.6-35b-a3b\nI am qwen3.5-9b\nfile1 file2\n' >"$T/answers"
OUT=$(FAKE_ANSWERS="$T/answers" bash "$ROOT/tools/fallback-test.sh" --yes 2>&1); RC=$?
check "fallback-test: succeeds when every step answers" test $RC -eq 0
check "fallback-test: desktop answer recognised" has "answered by qwen3.6-35b-a3b"
check "fallback-test: laptop answer recognised" has "answered by qwen3.5-9b"
check "fallback-test: order is pause, cut internet, ask, restore, resume" bash -c "
  l() { grep -nF -- \"\$1\" '$FAKE_LOG' | head -1 | cut -d: -f1; }
  [[ \$(l 'hermes pause') -lt \$(l 'ufw insert 1 deny out 443/tcp') && \$(l 'ufw insert 1 deny out 443/tcp') -lt \$(l 'hermes chat') && \$(l 'hermes chat') -lt \$(l 'ufw delete deny out 443/tcp') && \$(l 'ufw delete deny out 443/tcp') -lt \$(l 'hermes resume') ]]"
check "fallback-test: local profile step ran" logged "hermes -p local chat"
: >"$FAKE_LOG"; printf 'FAIL\nI am qwen3.5-9b\nfiles\n' >"$T/answers"
OUT=$(FAKE_ANSWERS="$T/answers" bash "$ROOT/tools/fallback-test.sh" --yes 2>&1); RC=$?
check "fallback-test: a failing step makes the run fail" test $RC -eq 1
check "fallback-test: failure explains the one-fallback-per-turn case" has "stops after one fallback"
check "fallback-test: firewall is restored even after a failure" logged "ufw delete deny out 443/tcp"
check "fallback-test: schedules resumed even after a failure" logged "hermes resume"
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

echo "tools: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
