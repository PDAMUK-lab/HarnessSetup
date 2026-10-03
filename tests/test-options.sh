#!/usr/bin/env bash
# Options are asked, not guessed: flags skip the question, --yes / no terminal take the default,
# and a scripted answer changes what a stage does.
# shellcheck disable=SC2016  # literal backticks and $ in expected text
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
has() { grep -qF -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
unset SSH_CLIENT HS_INPUT HS_INPUT_OPEN
export PATH="$ROOT/tests/fakebin:$PATH" FAKE_LOG="$T/calls.log" DESTDIR="$T/root" ASSUME_YES=0 HS_ALLOW_ANY_USER=1
export HOME="$T/home"; mkdir -p "$HOME"; : >"$FAKE_LOG"
sed -E \
  -e 's|^OR_WORKER_MODEL=.*|OR_WORKER_MODEL=vendor-a/worker|' -e 's|^OR_REVIEW_MODEL=.*|OR_REVIEW_MODEL=vendor-b/reviewer|' \
  -e 's|^OR_COMPRESSION_MODEL=.*|OR_COMPRESSION_MODEL=vendor-a/mid|' -e 's|^OR_FALLBACK_MODEL=.*|OR_FALLBACK_MODEL=vendor-c/fallback|' \
  -e 's|^GITHUB_ORG=.*|GITHUB_ORG=acme|' -e 's|^GITHUB_REPOS=.*|GITHUB_REPOS="app lib"|' \
  -e 's|^GITHUB_MACHINE_USER=.*|GITHUB_MACHINE_USER=acme-bot|' -e 's|^GITHUB_NOREPLY_EMAIL=.*|GITHUB_NOREPLY_EMAIL=42+acme-bot@users.noreply.github.com|' \
  -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|' "$ROOT/config/node.env.example" >"$T/node.env"
export NODE_ENV="$T/node.env"
ans() { printf '%b' "$1" >"$T/ans"; export HS_INPUT="$T/ans"; unset HS_INPUT_OPEN; }
noans() { unset HS_INPUT HS_INPUT_OPEN; }
run() { OUT=$("$ROOT/setup.sh" "$@" 2>&1 </dev/null); RC=$?; }

# ---- stage 04: Docker
ans 'y\n'; run run 04 --dry-run
check "04: asks about Docker" has "Install Docker?"
check "04: yes installs it" has "usermod -aG docker hermes"
ans 'n\n'; run run 04 --dry-run
check "04: no skips it" lacks "usermod"
check "04: ...and installs no docker package" lacks "install docker.io"
ans '\n'; run run 04 --dry-run
check "04: Enter takes the default (no)" lacks "usermod"
noans; run run 04 --dry-run --yes
check "04: --yes takes the default without asking" bash -c "! grep -q 'Install Docker' <<<\"\$0\" && ! grep -q usermod <<<\"\$0\"" "$OUT"
ans ''; run run 04 --dry-run --docker
check "04: --docker is not asked (an empty answers file would fail if it were)" has "usermod -aG docker hermes"
ans ''; run run 04 --dry-run --no-docker
check "04: --no-docker is not asked either" lacks "usermod"

# ---- stage 01: NVIDIA, with and without the GPU
noans; FAKE_LSPCI=none run run 01 --dry-run --yes
check "01: no NVIDIA card: default is to skip the driver" lacks "nvidia-driver"
FAKE_LSPCI=nvidia run run 01 --dry-run --yes
check "01: GTX 1070 present: default installs the 550 driver" has "nvidia-kernel-dkms nvidia-driver"
ans 'n\n'; FAKE_LSPCI=nvidia run run 01 --dry-run
check "01: answering no skips it even with a card" lacks "nvidia-driver"
ans 'y\n'; FAKE_LSPCI=none run run 01 --dry-run
check "01: answering yes installs it" has "nvidia-driver"
check "01: the question explains why 550" has "newer drivers drop Pascal"
ans ''; FAKE_LSPCI=none run run 01 --dry-run --nvidia
check "01: --nvidia is not asked" has "nvidia-driver"

# ---- stage 09: CUDA or Vulkan
ans 'n\n'; run run 09 --dry-run
check "09: no to CUDA selects Vulkan" has "DGGML_VULKAN=ON"
ans 'y\n'; run run 09 --dry-run
check "09: yes selects CUDA for Pascal" has "DCMAKE_CUDA_ARCHITECTURES=61"
noans; run run 09 --dry-run --yes
check "09: default is CUDA" has "DGGML_CUDA=ON"
ans ''; run run 09 --dry-run --vulkan
check "09: --vulkan is not asked" has "DGGML_VULKAN=ON"

# ---- stage 10: benchmark and start
ans 'y\nn\n'; run run 10 --dry-run
check "10: benchmark yes" has "llama-bench"
check "10: start no" lacks "enable --now"
ans 'n\ny\n'; run run 10 --dry-run
check "10: benchmark no" lacks "llama-bench"
check "10: start yes" has "enable --now llama-server"
noans; run run 10 --dry-run --yes
check "10: --yes: no benchmark, starts the service" bash -c "! grep -q llama-bench <<<\"\$0\" && grep -q 'enable --now' <<<\"\$0\"" "$OUT"

# ---- stage 12: the release watcher
ans 'y\n'; run run 12 --dry-run
check "12: yes starts the watcher running" lacks "release-watcher --paused"
ans 'n\n'; run run 12 --dry-run
check "12: no leaves it paused" has "release-watcher --paused"
noans; run run 12 --dry-run --yes
check "12: --yes keeps it paused" has "release-watcher --paused"

# ---- tools/verify: the slow model tests
mkdir -p "$HOME/.hermes"; printf 'DESKTOP_LLM_KEY=k\n' >"$HOME/.hermes/.env"
export HS_AGENT_RUNNER="$ROOT/tests/fakebin/agent-runner.sh" XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"
ans 'n\n'; run tool verify
check "verify: answering no skips the model smoke tests" has "re-run without --no-models"
check "verify: ...and says so" bash -c "grep -q 'MANUAL.*tool-call smoke test' <<<\"\$0\"" "$OUT"
noans

# ---- tools/fallback-test: the sleep step
ans 'n\ny\n'; printf 'I am qwen3.6-35b-a3b\nfiles\n' >"$T/answers"
OUT=$(FAKE_ANSWERS="$T/answers" "$ROOT/setup.sh" tool fallback-test 2>&1 </dev/null); RC=$?
check "fallback-test: asks whether you will sleep the desktop" has "put the desktop to sleep for step 2?"
check "fallback-test: the Continue? confirmation reads the same scripted answers" test $RC -eq 0
check "fallback-test: no to sleeping skips step 2" lacks "2. desktop asleep"
check "fallback-test: ...and says it was not tested" has "NOT tested: step 2"
noans

# ---- tools/overnight-laptop: the task is asked for
mkdir -p "$HOME/.hermes/profiles/local"; printf 'model:\n  provider: custom:desktop\n' >"$HOME/.hermes/profiles/local/config.yaml"
: >"$FAKE_LOG"; ans 'raise coverage of src/parser to 90 percent\n'
OUT=$("$ROOT/tools/overnight-laptop.sh" 2>&1 </dev/null); RC=$?
check "overnight: asks for the task" has "Overnight task"
check "overnight: the answer becomes the job's prompt" bash -c "grep 'cron create' '$FAKE_LOG' | grep -q 'raise coverage of src/parser to 90 percent'"
: >"$FAKE_LOG"; rm -f "$HOME/.hermes/profiles/local/fake-cron"; ans '\n'
OUT=$("$ROOT/tools/overnight-laptop.sh" 2>&1 </dev/null); RC=$?
check "overnight: an empty answer creates no job" bash -c "! grep -q 'cron create' '$FAKE_LOG'"
noans

# ---- tools/github-smoke-test: which repo
mkdir -p "$HOME/repos/app/.git" "$HOME/repos/lib/.git"
ans 'lib\nn\n'
OUT=$("$ROOT/setup.sh" tool github-smoke-test --dry-run 2>&1 </dev/null); RC=$?
check "smoke test: asks which repo when there are several" has "Which repo should the smoke test use?"
check "smoke test: uses the chosen one" has "acme/lib"
ans '\nn\n'
OUT=$("$ROOT/setup.sh" tool github-smoke-test --dry-run 2>&1 </dev/null)
check "smoke test: Enter takes the first repo" has "acme/app"
noans

# ---- tools/adopt-repo: asks, and guesses from the project
mkdir -p "$T/js" "$T/py" "$T/rs" "$T/bare"; for d in js py rs bare; do git init -q "$T/$d"; done
echo '{}' >"$T/js/package.json"; : >"$T/py/pyproject.toml"; : >"$T/rs/Cargo.toml"
adopt() { OUT=$("$ROOT/tools/adopt-repo.sh" "$@" 2>&1 </dev/null); RC=$?; }
ans '\n\n\n\n\n'; adopt "$T/js"
check "adopt (npm): accepting every guess works" test $RC -eq 0
check "adopt (npm): guessed npm ci / npm test" grep -qF 'Test (must pass before any push): `npm test`' "$T/js/AGENTS.md"
check "adopt (npm): guessed lint" grep -qF 'Lint: `npm run lint`' "$T/js/AGENTS.md"
check "adopt (npm): the guessed package command writes into dist/ (the release workflow publishes dist/*)" grep -q 'npm pack --pack-destination dist' "$T/js/AGENTS.md"
check "adopt (npm): ...in the release workflow too" grep -q 'pack-destination dist' "$T/js/.github/workflows/release.yml"
check "adopt (npm): guessed version file" grep -qF 'Version lives in: `package.json`' "$T/js/AGENTS.md"
ans '\n\n\n\n\n'; adopt "$T/py"
check "adopt (python): guessed pytest" grep -qF '`pytest -q`' "$T/py/AGENTS.md"
ans '\n\n\n\n\n'; adopt "$T/rs"
check "adopt (rust): guessed cargo test" grep -qF '`cargo test`' "$T/rs/AGENTS.md"
ans 'make setup\nmake check\nnone\nmake bundle\nVERSION\n'; adopt "$T/bare"
check "adopt (unknown project): the typed commands are used" grep -qF '`make check`' "$T/bare/AGENTS.md"
check "adopt (unknown project): ...also in the workflows" grep -q 'make bundle' "$T/bare/.github/workflows/release.yml"
ans '\n\n\n\n\n'; rm -rf "$T/bare2"; git init -q "$T/bare2"; adopt "$T/bare2"
check "adopt (unknown project): blank required answers are refused" test $RC -ne 0
ans "$T/js\n\n\n\n\n\n"; rm -f "$T/js/AGENTS.md"; OUT=$("$ROOT/tools/adopt-repo.sh" --force 2>&1 </dev/null); RC=$?
check "adopt: asks for the path when none is given" bash -c "[[ $RC -eq 0 ]] && [[ -f '$T/js/AGENTS.md' ]]"
noans; adopt
check "adopt: no path and no terminal is a usage error" test $RC -ne 0
ans ''; adopt "$T/js" --force --install a --test b --package c --lint d --version-file v
check "adopt: all flags given means no questions" test $RC -eq 0

echo "options: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
