#!/usr/bin/env bash
# Render every template with the example settings and validate the result.
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SHELLCHECK=${SHELLCHECK:-shellcheck}
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }

# example settings + the model IDs the user must supply
sed -E \
  -e 's|^OR_WORKER_MODEL=.*|OR_WORKER_MODEL=vendor-a/worker|' \
  -e 's|^OR_REVIEW_MODEL=.*|OR_REVIEW_MODEL=vendor-b/reviewer|' \
  -e 's|^OR_COMPRESSION_MODEL=.*|OR_COMPRESSION_MODEL=vendor-a/mid|' \
  -e 's|^OR_FALLBACK_MODEL=.*|OR_FALLBACK_MODEL=vendor-c/fallback|' \
  "$ROOT/config/node.env.example" >"$T/node.env"
NODE_ENV="$T/node.env"
load_config
export INSTALL_CMD='npm ci' TEST_CMD='npm test' LINT_CMD='npm run lint' PACKAGE_CMD='npm pack' VERSION_FILE=package.json

out_of() { render_template "$ROOT/templates/$1"; printf '%s' "$RENDERED" >"$T/$2"; }
while IFS= read -r tpl; do
  rel=${tpl#"$ROOT/templates/"}; name=$(echo "$rel" | tr / _)
  out_of "$rel" "$name"
  check "$rel: no unreplaced @@tokens" bash -c "! grep -q '@@' '$T/$name'"
done < <(find "$ROOT/templates" -name '*.tpl' | sort)

yaml_ok() { python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert isinstance(d,dict) and d" "$1"; }
for f in hermes_cloud.yaml.tpl hermes_providers.yaml.tpl hermes_local-profile.yaml.tpl hermes_night-provider.yaml.tpl \
         hermes_v100-provider.yaml.tpl \
         repo_workflows_test.yml.tpl repo_workflows_release.yml.tpl; do
  check "$f is valid YAML" yaml_ok "$T/$f"
done
check "cloud.yaml: keeps worker model as a string" grep -q 'model: "vendor-a/worker"' "$T/hermes_cloud.yaml.tpl"
check "cloud.yaml: approval mode is the string 'off' (a bare off would be YAML false)" python3 -c "import yaml,sys; d=yaml.safe_load(open('$T/hermes_cloud.yaml.tpl')); assert d['approvals']['mode']=='off', d['approvals']"
check "cloud.yaml: a stuck sub-agent is stopped (child_timeout_seconds)" python3 -c "import yaml,sys; d=yaml.safe_load(open('$T/hermes_cloud.yaml.tpl')); assert d['delegation']['child_timeout_seconds']==1800"
check "providers.yaml: both endpoints, and no chain (lib/chain.sh writes it)" bash -c "grep -q 'desktop:' '$T/hermes_providers.yaml.tpl' && grep -q 'laptop:' '$T/hermes_providers.yaml.tpl' && ! grep -q fallback_providers '$T/hermes_providers.yaml.tpl'"
check "v100-provider.yaml: its own port and the shared key" bash -c "grep -q 'api: http://192.168.1.100:8081/v1' '$T/hermes_v100-provider.yaml.tpl' && grep -q 'key_env: DESKTOP_LLM_KEY' '$T/hermes_v100-provider.yaml.tpl'"
# shellcheck disable=SC2016  # the ${{ }} is literal GitHub Actions syntax
check "release.yml keeps the \${{ }} expression" grep -qF '${{ github.token }}' "$T/repo_workflows_release.yml.tpl"

# systemd units
check "llama unit: ExecStart continuation lines are intact" bash -c "awk '/^ExecStart/{f=1} f{print} /^Restart/{exit}' '$T/systemd_llama-server.service.tpl' | head -n -1 | grep -v '\\\\\$' | wc -l | grep -qx 1"
check "llama unit: has -nkvo, --jinja, -np 1, 131072" bash -c "grep -q -- '-nkvo' '$T/systemd_llama-server.service.tpl' && grep -q -- '--jinja' '$T/systemd_llama-server.service.tpl' && grep -q -- '-np 1' '$T/systemd_llama-server.service.tpl' && grep -q 131072 '$T/systemd_llama-server.service.tpl'"
check "llama unit: loopback only" grep -q -- '--host 127.0.0.1 --port 8080' "$T/systemd_llama-server.service.tpl"
check "dashboard unit: loopback only" grep -q -- '--host 127.0.0.1 --port 9119 --no-open' "$T/systemd_hermes-dashboard.service.tpl"
check "dashboard unit: restart guard for exit 78" grep -q 'RestartPreventExitStatus=78' "$T/systemd_hermes-dashboard.service.tpl"
nkvo_off() {
  sed 's/^LAPTOP_KV_IN_RAM=.*/LAPTOP_KV_IN_RAM=0/' "$T/node.env" >"$T/node-nokv.env"
  ( NODE_ENV="$T/node-nokv.env"; load_config; render_template "$ROOT/templates/systemd/llama-server.service.tpl"; ! grep -q -- '-nkvo' <<<"$RENDERED" )
}
check "LAPTOP_KV_IN_RAM=0 drops -nkvo" nkvo_off
qwen_default() { grep -qF -- "--chat-template-kwargs '{\"enable_thinking\":true}' --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0" "$T/systemd_llama-server.service.tpl"; }
check "llama unit: Qwen3.5 thinking switch and sampling by default" qwen_default
other_family() { # another model family: its own switches and sampling, or none at all
  sed -e "s/^LAPTOP_CHAT_KWARGS=.*/LAPTOP_CHAT_KWARGS=reasoning_effort=low,enable_thinking=false/" -e "s/^LAPTOP_SAMPLING=.*/LAPTOP_SAMPLING='--temp 1.0 --top-k 64'/" "$T/node.env" >"$T/node-fam.env"
  ( NODE_ENV="$T/node-fam.env"; load_config; render_template "$ROOT/templates/systemd/llama-server.service.tpl"
    grep -qF -- "--chat-template-kwargs '{\"reasoning_effort\":\"low\",\"enable_thinking\":false}' --temp 1.0 --top-k 64" <<<"$RENDERED" ) || return 1
  sed -e "s/^LAPTOP_CHAT_KWARGS=.*/LAPTOP_CHAT_KWARGS=none/" -e "s/^LAPTOP_SAMPLING=.*/LAPTOP_SAMPLING=none/" "$T/node.env" >"$T/node-none.env"
  ( NODE_ENV="$T/node-none.env"; load_config; render_template "$ROOT/templates/systemd/llama-server.service.tpl"
    ! grep -qE -- 'chat-template-kwargs|--temp' <<<"$RENDERED" )
}
check "llama unit: other families get their own switches and sampling; none leaves both out" other_family

# shell scripts rendered from templates
for f in bin_hermes-mode.tpl scripts_release-pending.sh.tpl; do
  check "$f: bash -n" bash -n "$T/$f"
  if command -v "$SHELLCHECK" >/dev/null 2>&1; then check "$f: shellcheck" "$SHELLCHECK" -s bash "$T/$f"; fi
done
check "hermes-mode: probes use configured addresses" grep -q 'http://192.168.1.100:8080/health' "$T/bin_hermes-mode.tpl"
check "release skill: never waits with 'gh run watch' (the fine-grained token cannot)" bash -c "! grep -q 'gh run watch' '$ROOT/templates/skills/release/SKILL.md' || grep -q 'Do not use gh run watch' '$ROOT/templates/skills/release/SKILL.md'"
# shellcheck disable=SC2016  # $GITHUB_SHA is literal workflow text
check "release.yml: refuses a tag that is not on main" grep -qF 'git merge-base --is-ancestor "$GITHUB_SHA" origin/main' "$T/repo_workflows_release.yml.tpl"
check "release.yml: checks out full history (needed to compare the tag with main)" grep -q 'fetch-depth: 0' "$T/repo_workflows_release.yml.tpl"
check "release skill: finds the tag's run by commit and polls gh run view" grep -q 'gh run list --workflow release.yml --commit' "$ROOT/templates/skills/release/SKILL.md"
check "workflows: actions/checkout is the current major (v4 is a retired Node 20 action)" bash -c "! grep -q 'checkout@v[1-6]\\b' '$T/repo_workflows_release.yml.tpl' '$T/repo_workflows_test.yml.tpl'"
check "guide: the release watcher script matches the template" bash -c "grep -qF \"gh pr list --state merged --search 'Release in:title' --limit 100\" '$ROOT/docs/GUIDE.md'"

echo "templates: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
