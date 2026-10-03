#!/usr/bin/env bash
# Tests for lib/merge_yaml.py, including the exact cloud -> local profile transformation (Step 22).
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
M="python3 $ROOT/lib/merge_yaml.py"
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
get() { python3 "$ROOT/lib/merge_yaml.py" "$1" --get "$2" 2>/dev/null; }
eq() { [[ $1 == "$2" ]]; }

# A config like the one Hermes writes, plus the cloud fragment merged in
cat >"$T/config.yaml" <<'YAML'
model:
  provider: openrouter
  default: some/planner
display:
  theme: dark
delegation:
  max_iterations: 50
YAML
cat >"$T/cloud.yaml" <<'YAML'
delegation:
  provider: openrouter
  model: worker/model
  max_concurrent_children: 3
  max_iterations: 200
  worktree_isolation: true
auxiliary:
  review: {provider: openrouter, model: frontier/model}
  compression: {provider: openrouter, model: mid/model}
fallback_providers:
  - {provider: openrouter, model: a/b}
  - {provider: custom:desktop, model: d}
  - {provider: custom:laptop, model: l}
YAML
chmod 640 "$T/config.yaml"
out=$($M "$T/config.yaml" "$T/cloud.yaml"); 
check "merge reports an update" grep -q updated <<<"$out"
check "unrelated keys survive" eq "$(get "$T/config.yaml" display.theme)" dark
check "existing keys are overridden" eq "$(get "$T/config.yaml" delegation.max_iterations)" 200
check "nested keys are added" eq "$(get "$T/config.yaml" delegation.worktree_isolation)" True
check "file mode is preserved" eq "$(stat -c %a "$T/config.yaml")" 640
check "a backup was made" test -n "$(ls "$T"/config.yaml.bak-* 2>/dev/null)"
out=$($M "$T/config.yaml" "$T/cloud.yaml")
check "second identical merge is a no-op" eq "$out" "$T/config.yaml: unchanged"

# Step 22: clone -> local profile
cp "$T/config.yaml" "$T/local.yaml"
cat >"$T/local-frag.yaml" <<'YAML'
model: {provider: custom:desktop, default: qwen}
fallback_providers:
  - {provider: custom:laptop, model: l}
delegation:
  base_url: http://127.0.0.1:8080/v1
  model: l
  api_key: local
  max_concurrent_children: 1
auxiliary:
  review: {provider: main}
  compression: {provider: main}
YAML
$M "$T/local.yaml" "$T/local-frag.yaml" --delete delegation.provider --delete auxiliary.review --delete auxiliary.compression >/dev/null
check "local: provider line removed from delegation" eq "$(get "$T/local.yaml" delegation.provider; echo rc=$?)" "rc=1"
check "local: subagent model replaced" eq "$(get "$T/local.yaml" delegation.model)" l
check "local: worktree isolation kept" eq "$(get "$T/local.yaml" delegation.worktree_isolation)" True
check "local: review block fully replaced (no leftover model)" eq "$(get "$T/local.yaml" auxiliary.review.model; echo rc=$?)" "rc=1"
check "local: review uses the main model" eq "$(get "$T/local.yaml" auxiliary.review.provider)" main
check "local: fallback list replaced, not appended" eq "$(python3 -c "import yaml;print(len(yaml.safe_load(open('$T/local.yaml'))['fallback_providers']))")" 1
check "local: planner is the desktop" eq "$(get "$T/local.yaml" model.provider)" custom:desktop

# creating a missing target
$M "$T/new/dir/c.yaml" "$T/cloud.yaml" >/dev/null
check "creates missing target and parents" eq "$(get "$T/new/dir/c.yaml" delegation.model)" worker/model
check "new file is private (600)" eq "$(stat -c %a "$T/new/dir/c.yaml")" 600
check "bad input is rejected" bash -c "! echo '- a' >'$T/list.yaml'; ! python3 '$ROOT/lib/merge_yaml.py' '$T/list.yaml' '$T/cloud.yaml' 2>/dev/null"

echo "merge_yaml: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
