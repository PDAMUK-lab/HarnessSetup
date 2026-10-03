#!/usr/bin/env bash
# TITLE: GitHub access for the agent (token login, git identity, clone repos)
# RUN-AS: hermes
# GUIDE: Step 8 (laptop side)
# Needs the machine account, rulesets and fine-grained token from docs/RUNBOOK.md (GitHub web steps).
# Options: --reauth (log in again even if gh is already logged in)
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
REAUTH=0
for a in "$@"; do
  case $a in
    --reauth) REAUTH=1 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
stage_begin
use_hermes_path
need_cmd gh git
require_vars GITHUB_ORG GITHUB_REPOS GITHUB_MACHINE_USER GITHUB_NOREPLY_EMAIL
[[ $GITHUB_ORG != yourorg && $GITHUB_REPOS != yourrepo ]] ||
  fail_or_warn "GITHUB_ORG / GITHUB_REPOS in config/node.env still hold the example values"
[[ $GITHUB_NOREPLY_EMAIL != 12345678+* ]] || fail_or_warn "GITHUB_NOREPLY_EMAIL still holds the example value (machine account > Settings > Emails)"

who=$(gh api user -q .login 2>/dev/null || true)
if [[ $who == "$GITHUB_MACHINE_USER" && $REAUTH == 0 ]]; then
  ok "gh is already logged in as $who"
elif [[ $DRY_RUN == 1 ]]; then
  log "[dry-run] would prompt for the machine account's fine-grained token and run: gh auth login --with-token"
else
  [[ -r /dev/tty ]] || die "need a terminal to paste the token"
  read -rs -p "Paste the machine account's fine-grained token (input hidden): " TOKEN </dev/tty
  echo
  [[ -n $TOKEN ]] || die "empty token"
  printf '%s\n' "$TOKEN" | gh auth login --with-token
  unset TOKEN
  who=$(gh api user -q .login 2>/dev/null || true)
  [[ $who == "$GITHUB_MACHINE_USER" ]] || die "the token belongs to '${who:-nobody}', expected '$GITHUB_MACHINE_USER'"
fi

run gh auth setup-git
run git config --global user.name "$GITHUB_MACHINE_USER"
run git config --global user.email "$GITHUB_NOREPLY_EMAIL"

run mkdir -p "$HOME/repos"
for repo in $GITHUB_REPOS; do
  if [[ -d $HOME/repos/$repo/.git ]]; then
    ok "$repo already cloned"
  else
    (cd "$HOME/repos" && run gh repo clone "$GITHUB_ORG/$repo")
  fi
  # keeps the subagents' git worktrees (Phase 3) out of commits
  if [[ $DRY_RUN != 1 ]]; then
    grep -qxF '.worktrees/' "$HOME/repos/$repo/.git/info/exclude" 2>/dev/null ||
      echo '.worktrees/' >>"$HOME/repos/$repo/.git/info/exclude"
  fi
done

[[ $DRY_RUN == 1 ]] || gh auth status
stage_end
cat <<MSG
Prove the guard rails BEFORE adding any release workflow (the test pushes a tag):
  ./setup.sh tool github-smoke-test
Then:  ./setup.sh run 06
MSG
