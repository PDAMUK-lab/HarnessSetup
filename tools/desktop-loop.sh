#!/usr/bin/env bash
# TITLE: Desktop in or out of the loop (use the desktop for something else, then bring it back)
# RUN-AS: hermes
# GUIDE: extension (desktop away mode; docs/RUNBOOK.md)
# NEEDS: OR_FALLBACK_MODEL DESKTOP_IP LLM_PORT V100_ENABLED V100_PRIMARY V100_MODEL_ALIAS V100_CTX V100_PORT
# Also installed as `hermes-desktop` (stage 11). Usage:
#   desktop-loop.sh status               is the desktop in the loop, and in which order are the endpoints used?
#   desktop-loop.sh off [--for 4h]       leave every desktop endpoint out of the fallback chain and the local profile
#   desktop-loop.sh on                   put them back
# Away only changes Hermes's configuration here on the laptop; stopping the models on the desktop (to free its GPU and
# memory) is desktop/windows/Desktop-Mode.ps1, which calls this command too.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
ACTION=status DUR=''
while (($#)); do
  case $1 in
    status | on | off) ACTION=$1 ;;
    --for) DUR=${2:?--for needs a duration like 90m, 4h or 1d}; shift ;;
    --for=*) DUR=${1#--for=} ;;
    *) common_flag "$1" || die "unknown option: $1   (usage: hermes-desktop [status|off|on] [--for 4h])" ;;
  esac
  shift
done
load_config
use_hermes_path
[[ -z $DUR || $ACTION == off ]] || die "--for only goes with 'off'"
[[ -z $DUR || $DUR =~ ^[0-9]{1,3}[mhd]$ ]] || die "--for expects a duration like 90m, 4h or 1d (got '$DUR')"
need_cmd python3
cfg=$HOME/.hermes/config.yaml
pcfg=$HOME/.hermes/profiles/local/config.yaml
flag=$(desktop_away_flag)
timer=hermes-desktop-return

user_bus_env   # reached through `sudo -u hermes` from the desktop: no login session, so find the user manager
cancel_timer() { if [[ $DRY_RUN != 1 ]]; then systemctl --user stop "$timer.timer" "$timer.service" >/dev/null 2>&1 || true; fi; }
show_order() {
  local p m n=0
  while IFS='|' read -r p m; do n=$((n + 1)); printf '  %d. %s  (%s)\n' "$n" "$p" "$m"; done < <(chain_entries)
}
need_configs() { [[ ( -f $cfg && -f $pcfg ) || $DRY_RUN == 1 ]] || die "run stages 07 and 11 first ($cfg and $pcfg must exist)"; }

case $ACTION in
  status)
    if desktop_away; then warn "the desktop is OUT of the loop: $(cat "$flag" 2>/dev/null)"; else ok "the desktop is in the loop"; fi
    echo "Local endpoints, in the order Hermes tries them after OpenRouter:" >&2
    show_order >&2
    ;;
  off)
    need_configs
    require_vars OR_FALLBACK_MODEL
    if [[ -n $DUR ]]; then need_user_session; fi   # before anything changes: a timer needs the user manager
    cancel_timer   # a new 'off' replaces an earlier timer
    since=$(date '+%F %H:%M')
    note="since $since"
    if [[ -n $DUR ]]; then
      case ${DUR: -1} in m) unit=minutes ;; h) unit=hours ;; *) unit=days ;; esac
      note="$note; comes back by itself at $(date -d "+${DUR%?} $unit" '+%F %H:%M')"
    fi
    if [[ $DRY_RUN == 1 ]]; then log "[dry-run] would write '$note' to $flag"; else mkdir -p "$(dirname "$flag")" && printf '%s\n' "$note" >"$flag"; fi
    chain_apply "$cfg" "$pcfg"
    if [[ -n $DUR ]]; then
      run systemd-run --user --on-active="$DUR" --unit="$timer" --description="Put the desktop back in Hermes's loop" "$HOME/.local/bin/hermes-desktop" on
    fi
    if [[ $DRY_RUN != 1 ]]; then
      jobs=$(hermes -p local cron list 2>/dev/null | grep -iE 'desktop-night|overnight' || true)
      if [[ -n $jobs ]]; then
        warn "jobs pinned to a desktop model never fall back, so they would fail while the desktop is away; pause them if they would run:"
        printf '    %s\n' "${jobs//$'\n'/$'\n'    }" >&2
      fi
    fi
    ok "the desktop is OUT of the loop ($note)"
    echo "Local endpoints now:" >&2
    show_order >&2
    echo "Bring it back with:  hermes-desktop on" >&2
    ;;
  on)
    need_configs
    require_vars OR_FALLBACK_MODEL
    cancel_timer
    was_away=0
    if desktop_away; then was_away=1; fi
    run rm -f "$flag"
    chain_apply "$cfg" "$pcfg"
    if ((was_away)); then ok "the desktop is back in the loop"; else ok "the desktop was already in the loop (the chain was rewritten to be sure)"; fi
    echo "Local endpoints now:" >&2
    show_order >&2
    if [[ $DRY_RUN != 1 ]]; then
      key=$(grep -E '^DESKTOP_LLM_KEY=' "$HOME/.hermes/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true)
      c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $key" "http://$DESKTOP_IP:$LLM_PORT/health" || true)
      if [[ $c == 200 ]]; then ok "the desktop model answers on $DESKTOP_IP:$LLM_PORT"
      else warn "the desktop model does not answer yet ('$c'). Hermes falls back to the next endpoint until it does; on the desktop: .\\Desktop-Mode.ps1 back"; fi
    fi
    ;;
esac
