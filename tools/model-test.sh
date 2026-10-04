#!/usr/bin/env bash
# TITLE: Model test set: run your tasks against a model and record the pass rate and the time
# RUN-AS: hermes
# GUIDE: Step 30 (measure every change; keep a model only if it passes more tasks)
# NEEDS: AGENT_USER
# Usage:  model-test.sh [--file ~/model-tests.txt] [--profile local|default] [--provider custom:desktop --model NAME]
#                       [--label NAME] [--only TASK] [--timeout 1800]
# Tasks file format: see config/model-tests.example. Each task runs in a fresh git worktree of ~/repos/REPO (detached
# at the remote's default branch, removed afterwards); results go to ~/model-tests/results.csv, logs next to it.
# Compare models by running the same file with different --model/--provider (or after switching a model slot).
set -Euo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
FILE=$HOME/model-tests.txt PROFILE=local PROVIDER='' MODEL='' LABEL='' ONLY='' TIMEOUT=1800
while (($#)); do
  case $1 in
    --file) FILE=${2:?}; shift ;;
    --profile) PROFILE=${2:?}; shift ;;
    --provider) PROVIDER=${2:?}; shift ;;
    --model) MODEL=${2:?}; shift ;;
    --label) LABEL=${2:?}; shift ;;
    --only) ONLY=${2:?}; shift ;;
    --timeout) TIMEOUT=${2:?}; shift ;;
    *) common_flag "$1" || die "unknown option: $1" ;;
  esac
  shift
done
load_config
use_hermes_path
[[ $TIMEOUT =~ ^[0-9]+$ ]] || die "--timeout expects seconds"
[[ -f $FILE ]] || die "no task file $FILE: copy $HS_ROOT/config/model-tests.example there and write your own tasks"
need_cmd git
out=$HOME/model-tests
mkdir -p "$out"
results=$out/results.csv
[[ -s $results ]] || echo "date,label,profile,provider,model,task,result,seconds" >"$results"
label=${LABEL:-${MODEL:-$PROFILE}}
run_id=$(date +%Y%m%d-%H%M%S)
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
pass=0 total=0 secs_all=0
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
  IFS='|' read -r name repo check prompt <<<"$line"
  name=$(trim "$name") repo=$(trim "$repo") check=$(trim "$check") prompt=$(trim "${prompt:-}")
  [[ -n $name && -n $repo && -n $check && -n $prompt ]] || { warn "skipped a line without 4 fields: $line"; continue; }
  [[ -z $ONLY || $name == "$ONLY" ]] || continue
  src=$HOME/repos/$repo
  [[ -d $src/.git ]] || { warn "$name: skipped, $src is not a clone"; continue; }
  if [[ $DRY_RUN == 1 ]]; then log "[dry-run] $name: hermes -p $PROFILE chat${PROVIDER:+ --provider $PROVIDER}${MODEL:+ --model $MODEL} in a worktree of $repo, then: $check"; continue; fi
  git -C "$src" fetch -q origin || warn "$name: fetch failed, using the clone's last copy"
  ref=$(git -C "$src" symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/main)
  wt=$out/wt-$run_id-$name
  git -C "$src" worktree add -q --detach "$wt" "$ref" || { warn "$name: could not create a worktree"; continue; }
  logf=$out/$run_id-$name.log
  qf=$(mktemp); printf '%s\n' "$prompt" >"$qf"
  args=(-p "$PROFILE" chat --query-file "$qf")
  [[ -n $PROVIDER ]] && args+=(--provider "$PROVIDER")
  [[ -n $MODEL ]] && args+=(--model "$MODEL")
  start=$(date +%s)
  (cd "$wt" && timeout "$TIMEOUT" hermes "${args[@]}") >"$logf" 2>&1 || echo "(the agent run ended with an error or the timeout)" >>"$logf"
  if (cd "$wt" && timeout 900 bash -c "$check") >>"$logf" 2>&1; then result=pass; pass=$((pass + 1)); else result=fail; fi
  secs=$(($(date +%s) - start)); secs_all=$((secs_all + secs)); total=$((total + 1))
  echo "$(date -Is),$label,$PROFILE,$PROVIDER,$MODEL,$name,$result,$secs" >>"$results"
  printf '  %-4s %-32s %6ss\n' "$result" "$name" "$secs" >&2
  rm -f "$qf"
  git -C "$src" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
done <"$FILE"
[[ $DRY_RUN == 1 ]] && exit 0
((total > 0)) || die "no task ran (check the file and --only)"
ok "$label: $pass of $total passed in ${secs_all}s (results: $results, logs: $out/$run_id-*.log)"
((pass == total))
