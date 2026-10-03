#!/usr/bin/env bash
# TITLE: Prove the fallback chain with the internet off
# RUN-AS: admin
# GUIDE: Step 29
# NEEDS: GITHUB_REPOS DESKTOP_MODEL_ALIAS LAPTOP_MODEL_ALIAS
# Cuts outbound 443 for a few minutes. A trap ALWAYS restores the firewall and resumes the schedules,
# even if you press Ctrl-C or a step fails.
# Options (asked when not given): --sleep | --skip-sleep (whether you will put the desktop to sleep for step 2)
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
DO_SLEEP=''
for a in "$@"; do
  case $a in
    --skip-sleep) DO_SLEEP=0 ;;
    --sleep) DO_SLEEP=1 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
need_cmd ufw
ask_flag DO_SLEEP "Will you put the desktop to sleep for step 2? (this proves the laptop takes over when the desktop is off)" y
skipped=()
if [[ $DO_SLEEP == 1 ]] && ! is_interactive && [[ $DRY_RUN != 1 ]]; then
  warn "step 2 needs you to put the desktop to sleep, and there is no terminal to ask you on: skipping it"
  DO_SLEEP=0
fi
if [[ $DO_SLEEP != 1 ]]; then skipped+=("step 2 (desktop asleep, laptop answers)"); fi

cut_done=0 paused=0
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if ((cut_done)); then sudo_run ufw delete deny out 443/tcp || warn "could not delete the 'deny out 443/tcp' rule - remove it: sudo ufw delete deny out 443/tcp"; fi
  if ((paused)); then run_agent 'hermes resume' || warn "could not resume schedules - run: hermes resume"; fi
  exit "$rc"
}
run_agent() { if [[ $DRY_RUN == 1 ]]; then run agent_exec "$1"; else agent_exec "$1"; fi; }
trap cleanup EXIT INT TERM

cat <<MSG
This turns the internet OFF for the laptop for a few minutes (ufw deny out 443) and asks Hermes questions.
Schedules are paused first and resumed at the end; the firewall rule is removed at the end.
MSG
confirm "Continue?" || die "not confirmed"

run_agent 'hermes pause'; paused=1
sudo_run ufw insert 1 deny out 443/tcp; cut_done=1

failures=0
indent() { local l; while IFS= read -r l; do printf '    %s\n' "$l"; done <<<"$1"; }
ask() { # ask "label" "expected alias" "command"
  local label=$1 want=$2 cmd=$3 ans
  log "$label (Hermes retries before it falls back, so this can take a while)"
  if [[ $DRY_RUN == 1 ]]; then run agent_exec "$cmd"; return 0; fi
  if ans=$(agent_exec "$cmd" 2>&1); then
    indent "$ans"
    if [[ -z $want ]]; then ok "$label: answered"
    elif grep -qi -- "$want" <<<"$ans"; then ok "$label: answered by $want"
    else warn "$label: answered, but not by '$want' (a model can misreport its own name - confirm in the llama-server logs)"; fi
  else
    indent "$ans"
    warn "$label: FAILED"; failures=$((failures + 1))
  fi
}

ask "1. desktop on: the default profile falls back to the desktop model" "$DESKTOP_MODEL_ALIAS" 'hermes chat -q "Which model are you? One line."'
if [[ $DO_SLEEP == 1 ]]; then
  echo "Now put the desktop to sleep, wait about 20 seconds, then press Enter."
  [[ $DRY_RUN == 1 ]] || read_answer "Ready? (press Enter) "
  ask "2. desktop asleep: falls back to the laptop model" "$LAPTOP_MODEL_ALIAS" 'hermes chat -q "Which model are you? One line."'
fi
ask "3. the local profile works offline" "" "hermes -p local chat -q \"List the files in ~/repos/$CRON_REPO\""

echo
if ((failures)); then
  echo "$failures check(s) failed. If answer 1 or 2 errored instead of falling back, your Hermes version stops after one fallback"
  echo "per turn, and with the internet off that one fallback is the second OpenRouter model, which also fails. Keep the chain for"
  echo "ordinary outages and switch with 'hermes-mode local' when you know the internet is out."
  exit 1
fi
if ((${#skipped[@]})); then
  warn "NOT tested: ${skipped[*]}. The checks that ran passed, but the laptop fallback is not proven yet."
  exit 0
fi
ok "fallback behaviour confirmed"
