#!/usr/bin/env bash
# TITLE: Skills pack: Hermes's optional coding and model skills, and the kit's /toolcall-check /safe-run /audit /health /overnight
# RUN-AS: hermes
# GUIDE: extension (skills pack; docs/RUNBOOK.md)
# NEEDS: NIGHT_START NIGHT_END NIGHT_MODEL_ALIAS OFFLINE
# Run it last, on a node where every stage is done. It installs into every profile there is (default, local, and
# mixed when tools/mixed-mode.sh made it), so the skills work whichever mode is on:
#   * Hermes's optional skills (shipped with Hermes, off by default), installed with `hermes skills install`:
#     grill-me, subagent-driven-development, code-wiki, ast-grep, llama-cpp, huggingface-hub, evaluating-llms-harness.
#     Skipped with OFFLINE=1 (they are fetched) or --no-optional; --extra official/<category>/<name> adds more.
#   * The kit's own skills, from templates/skills: /toolcall-check, /safe-run, /audit, /health and /overnight, plus
#     their helpers hermes-toolcall-check and hermes-safe-run in ~/.local/bin.
# Re-running is safe: skills already installed are left alone, the kit's own are refreshed.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
OPTIONAL=(
  official/software-development/grill-me
  official/software-development/subagent-driven-development
  official/software-development/code-wiki
  official/software-development/ast-grep
  official/mlops/inference/llama-cpp
  official/mlops/models/huggingface-hub
  official/mlops/evaluation/evaluating-llms-harness
)
KIT_SKILLS=(toolcall-check safe-run audit health overnight)
WANT_OPTIONAL=1
while (($#)); do
  case $1 in
    --no-optional) WANT_OPTIONAL=0 ;;
    --extra)
      [[ ${2:-} =~ ^official/[a-z0-9/_-]+$ ]] || die "--extra takes an identifier like official/mlops/obliteratus"
      OPTIONAL+=("$2"); shift ;;
    *) common_flag "$1" || die "unknown option: $1" ;;
  esac
  shift
done
load_config
use_hermes_path
need_cmd hermes python3 setpriv
[[ -f $HOME/.hermes/config.yaml || $DRY_RUN == 1 ]] || die "Hermes is not set up yet ($HOME/.hermes/config.yaml is missing): finish the stages first"

# every profile there is: name|home
profiles=("default|$HOME/.hermes")
for p in local mixed; do
  if [[ -d $HOME/.hermes/profiles/$p ]]; then profiles+=("$p|$HOME/.hermes/profiles/$p"); fi
done
log "profiles: $(printf '%s ' "${profiles[@]%%|*}")"

# ---- the kit's helpers (one copy, used by every profile)
put_file "$HOME/.local/bin/hermes-toolcall-check" 755 self <"$HS_ROOT/templates/skills/toolcall-check/probe.py"
put_file "$HOME/.local/bin/hermes-safe-run" 755 self <"$HS_ROOT/templates/skills/safe-run/safe-run.sh"
ok "helpers: hermes-toolcall-check, hermes-safe-run in ~/.local/bin"

# ---- the kit's own skills, in every profile (the overnight one carries this node's night window)
for entry in "${profiles[@]}"; do
  home=${entry#*|}
  for s in "${KIT_SKILLS[@]}"; do
    render_template "$HS_ROOT/templates/skills/$s/SKILL.md"
    printf '%s' "$RENDERED" | put_file "$home/skills/$s/SKILL.md" 644 self
  done
  ok "kit skills in ${entry%%|*}: ${KIT_SKILLS[*]/#//}"
done

# ---- Hermes's optional skills, in every profile
failed=()
if [[ $WANT_OPTIONAL == 0 ]]; then
  log "--no-optional: leaving Hermes's optional skills out"
elif [[ ${OFFLINE:-0} == 1 ]]; then
  warn "OFFLINE=1: Hermes's optional skills are fetched, so they are left out (the kit's own skills are installed)"
else
  for entry in "${profiles[@]}"; do
    p=${entry%%|*}
    pflag=()
    [[ $p == default ]] || pflag=(-p "$p")
    have=''
    [[ $DRY_RUN == 1 ]] || have=$(hermes "${pflag[@]}" skills list 2>/dev/null || true)
    for id in "${OPTIONAL[@]}"; do
      name=${id##*/}
      if grep -qw -- "$name" <<<"$have"; then ok "$p: $name already installed"; continue; fi
      if run hermes "${pflag[@]}" skills install "$id" --yes; then
        [[ $DRY_RUN == 1 ]] || ok "$p: installed $name"
      else
        failed+=("$p:$name")
        warn "$p: could not install $id (see the message above; a scan block needs a human look, never --force here)"
      fi
    done
  done
fi

if [[ $DRY_RUN != 1 ]]; then
  for entry in "${profiles[@]}"; do
    for s in "${KIT_SKILLS[@]}"; do
      [[ -f ${entry#*|}/skills/$s/SKILL.md ]] || die "${entry#*|}/skills/$s/SKILL.md is missing after the install"
    done
  done
fi
((${#failed[@]} == 0)) || warn "not installed: ${failed[*]} - re-run this tool to retry"

cat <<MSG
Done. New slash commands in every profile (start a new session, or /reload-skills, to see them):
  /toolcall-check  six tool-calling probes against a local endpoint   (hermes-toolcall-check desktop)
  /safe-run        a task with an untrusted model: worktree, no sudo, no GitHub, report   (hermes-safe-run --help)
  /audit           what a session or cron run actually did, risky actions flagged
  /health          one-page check of Hermes, the model servers, GPU, disk, firewall, jobs and credit
  /overnight       a self-contained overnight job for the desktop's $NIGHT_MODEL_ALIAS, created paused
and Hermes's optional ones: $(printf '%s ' "${OPTIONAL[@]##*/}")
Their Python tools (lm-eval, llama-cpp-python, ast-grep) are not installed here: the agent installs them the first
time a skill needs them, and lists them in its PR as AGENTS.md asks.
MSG
