#!/usr/bin/env bash
# TITLE: Overnight tier, laptop side (desktop-night endpoint, local gateway, first job)
# RUN-AS: hermes
# GUIDE: Step 31 (laptop half)
# NEEDS: NIGHT_ENABLED=1 NIGHT_START NIGHT_END NIGHT_MODEL_ALIAS GITHUB_REPOS DESKTOP_CTX LLM_PORT
# The tier must be switched on in the settings (the dispatcher offers to do that). The desktop half is
# desktop/windows/Install-Overnight.ps1.
# Options (asked when not given): --task "self-contained prompt"  create the job overnight-coverage (paused) with it
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
TASK=''
while (($#)); do
  case $1 in
    --task) TASK=${2:?--task needs a prompt}; shift ;;
    *) common_flag "$1" || die "unknown option: $1" ;;
  esac
  shift
done
load_config
stage_begin() { :; } # a tool, not a numbered stage
ask_text TASK "Overnight task: a self-contained prompt that ends in a draft PR (leave empty to create no job yet)" ""
use_hermes_path
[[ ${NIGHT_ENABLED:-0} == 1 ]] || die "the overnight tier is off. Run it through the dispatcher, which offers to turn it on: ./setup.sh tool overnight-laptop"
# jobs start a quarter of an hour after the swap and must be done two hours before it ends
job_start=$(cfg_time_add "$NIGHT_START" 15)
job_latest=$(cfg_time_add "$NIGHT_END" -120)
need_cmd hermes python3
pcfg=$HOME/.hermes/profiles/local/config.yaml
[[ -f $pcfg || $DRY_RUN == 1 ]] || die "the local profile does not exist yet - run stage 11 first"

render_template "$HS_ROOT/templates/hermes/night-provider.yaml.tpl"
frag=$(mktemp); printf '%s' "$RENDERED" >"$frag"
if [[ $DRY_RUN == 1 ]]; then log "[dry-run] would add the desktop-night endpoint to $pcfg"; sed 's/^/    | /' "$frag" >&2; else python3 "$HS_ROOT/lib/merge_yaml.py" "$pcfg" "$frag"; fi
rm -f "$frag"

need_user_session
run hermes -p local gateway install

if [[ -n $TASK ]]; then
  if hermes -p local cron list 2>/dev/null | grep -qw overnight-coverage; then
    ok "job overnight-coverage already exists"
  else
    run hermes -p local cron create "daily at $(cfg_time_words "$job_start")" "$TASK" \
      --workdir "$AGENT_HOME/repos-cron/$CRON_REPO" \
      --provider custom:desktop-night --model "$NIGHT_MODEL_ALIAS" --name overnight-coverage --paused
  fi
fi
cat <<MSG
Manual steps left (in this order):
  1. hermes -p local tools      -> select the "cron" platform; enable file, terminal, delegation
  2. On the desktop: start the 27B by hand (C:\\llama\\start-llama-27b.cmd) and test:
       hermes -p local cron run overnight-coverage ; hermes -p local cron runs overnight-coverage
     then close the 27B window and run C:\\llama\\start-llama.cmd again.
  3. On the desktop (admin PowerShell): .\\Install-Overnight.ps1   (schedules the $NIGHT_START / $NIGHT_END swap)
  4. hermes -p local cron resume overnight-coverage
Rules: jobs run $job_start-$job_latest, one per night, self-contained prompts ending in a draft PR. Pinned jobs never fall back.
MSG
