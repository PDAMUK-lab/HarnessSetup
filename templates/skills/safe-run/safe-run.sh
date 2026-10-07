#!/usr/bin/env bash
# hermes-safe-run - run one task with a model you do not trust yet (a new or uncensored model), contained, and report
# exactly what it did. Installed by ./setup.sh tool skills-pack; the /safe-run skill drives it.
#
#   hermes-safe-run --repo DIR --task "prompt" [--profile P] [--provider P --model M] [--minutes 30] [--max-turns 60]
#
# Containment (what the run cannot do):
#   * no root: it runs under no_new_privs, so sudo and every other setuid program fail for the agent and its tools
#   * no GitHub: gh and git pushes see an empty login (GH_CONFIG_DIR is a fresh empty directory)
#   * no time sink: killed after --minutes, and Hermes is told the same budget
#   * no edits to your checkout: it works in a fresh git worktree on its own branch (sandbox/<stamp>)
# Not contained: files the agent user owns (its home, ~/.hermes, other repos) and the network; the report lists
# every file changed outside the worktree, so nothing is silent.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
REPO='' TASK='' PROFILE='' PROVIDER='' MODEL='' MINUTES=30 MAXTURNS=60
die() { echo "hermes-safe-run: $*" >&2; exit 2; }
indent() { local l; while IFS= read -r l; do printf '    %s\n' "$l"; done; }
while (($#)); do
  case $1 in
    --repo) REPO=${2:?}; shift ;;
    --task) TASK=${2:?}; shift ;;
    --profile) PROFILE=${2:?}; shift ;;
    --provider) PROVIDER=${2:?}; shift ;;
    --model) MODEL=${2:?}; shift ;;
    --minutes) MINUTES=${2:?}; shift ;;
    --max-turns) MAXTURNS=${2:?}; shift ;;
    -h | --help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ -n $REPO && -n $TASK ]] || die "--repo and --task are required (see --help)"
[[ $MINUTES =~ ^[0-9]+$ && $MAXTURNS =~ ^[0-9]+$ ]] || die "--minutes and --max-turns take whole numbers"
REPO=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "$REPO is not a git repository"
command -v setpriv >/dev/null || die "setpriv is missing (util-linux)"

stamp=$(date +%Y%m%d-%H%M%S)
base=$HOME/sandbox/$stamp
wt=$base/worktree
report=$base/REPORT.md
mkdir -p "$base" "$base/gh-empty"
git -C "$REPO" worktree add -q -b "sandbox/$stamp" "$wt" HEAD || die "could not create the worktree"
start_sha=$(git -C "$wt" rev-parse HEAD)
marker=$base/.start
touch "$marker"
sleep 1   # mtime granularity: anything written from here on is newer than the marker

hargs=()
[[ -n $PROFILE ]] && hargs+=(-p "$PROFILE")
cargs=(chat -q "$TASK" -Q --max-turns "$MAXTURNS" --run-budget "$((MINUTES * 60))")
[[ -n $PROVIDER ]] && cargs+=(--provider "$PROVIDER")
[[ -n $MODEL ]] && cargs+=(--model "$MODEL")

echo "sandbox: $wt (branch sandbox/$stamp); up to $MINUTES minutes; no sudo, no GitHub" >&2
t0=$(date +%s)
(
  cd "$wt" || exit 1
  GH_CONFIG_DIR=$base/gh-empty GH_TOKEN='' GITHUB_TOKEN='' GIT_TERMINAL_PROMPT=0 \
    timeout --kill-after=30 "$((MINUTES * 60 + 60))" setpriv --no-new-privs hermes "${hargs[@]}" "${cargs[@]}"
) >"$base/answer.txt" 2>"$base/stderr.txt"
rc=$?
secs=$(($(date +%s) - t0))

# what changed outside the worktree (the agent user's own files; Hermes's own bookkeeping left out)
outside=$(find "$HOME" -xdev -newer "$marker" -type f \
  -not -path "$base/*" -not -path "$HOME/.hermes/sessions/*" -not -path "$HOME/.hermes/logs/*" \
  -not -path "$HOME/.hermes/cache/*" -not -path "$HOME/.hermes/*state.db*" -not -path "$HOME/.hermes/profiles/*/sessions/*" \
  -not -path "$HOME/.hermes/profiles/*/logs/*" -not -path "$HOME/.hermes/profiles/*/*state.db*" \
  -not -path "$HOME/.cache/*" -not -path "$REPO/.git/*" 2>/dev/null | head -200)
session=$(hermes "${hargs[@]}" sessions list --limit 1 2>/dev/null | head -5)

{
  echo "# Sandbox run $stamp"
  echo
  echo "- Repo: $REPO (worktree $wt, branch sandbox/$stamp)"
  echo "- Model: ${PROVIDER:-profile default}${MODEL:+ / $MODEL}${PROFILE:+ (profile $PROFILE)}"
  echo "- Exit: $rc after ${secs}s$( ((rc == 124 || rc == 137)) && echo ' (killed: out of time)')"
  echo
  echo "## Task"
  echo
  echo "$TASK"
  echo
  echo "## Answer"
  echo
  sed 's/^/    /' "$base/answer.txt"
  echo
  echo "## Changes in the worktree"
  echo
  git -C "$wt" log --oneline "$start_sha..HEAD" 2>/dev/null | sed 's/^/    commit /'
  git -C "$wt" status --short | sed 's/^/    /'
  git -C "$wt" diff --stat "$start_sha" | sed 's/^/    /'
  echo
  echo "## Files changed OUTSIDE the worktree"
  echo
  if [[ -n $outside ]]; then indent <<<"$outside"; else echo "    none"; fi
  echo
  echo "## Blocked or failed attempts (stderr, sudo and GitHub refusals)"
  echo
  grep -iE 'no new privileges|sudo|gh auth|authentication|permission denied|not permitted' "$base/stderr.txt" "$base/answer.txt" 2>/dev/null |
    head -40 | sed 's/^/    /' || true
  echo
  echo "## Session"
  echo
  indent <<<"$session"
  echo
  echo "Audit the full transcript with /audit. Remove the sandbox: git -C $REPO worktree remove --force $wt && git -C $REPO branch -D sandbox/$stamp"
} >"$report"
cat "$report"
exit "$rc"
