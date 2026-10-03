#!/usr/bin/env bash
# TITLE: Overnight tier, laptop side (desktop-night endpoint, local gateway, first job)
# RUN-AS: hermes
# GUIDE: Step 31 (laptop half)
# Needs NIGHT_ENABLED=1 in config/node.env. The desktop half is desktop/windows/Install-Overnight.ps1.
# Options: --task "self-contained prompt"  create the job overnight-coverage (paused) with this prompt
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
use_hermes_path
[[ ${NIGHT_ENABLED:-0} == 1 ]] || die "set NIGHT_ENABLED=1 in config/node.env to use the overnight tier"
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
    run hermes -p local cron create "daily at 2am" "$TASK" \
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
  3. On the desktop (admin PowerShell): .\\Install-Overnight.ps1   (schedules the 01:00 / 07:00 swap)
  4. hermes -p local cron resume overnight-coverage
Rules: jobs run 01:15-05:00, one per night, self-contained prompts ending in a draft PR. Pinned jobs never fall back.
MSG
