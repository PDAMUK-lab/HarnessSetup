#!/usr/bin/env bash
# HarnessSetup dispatcher: run the guide's phases as numbered, re-runnable stages.
#
#   ./setup.sh list                  show every stage and whether it has completed
#   ./setup.sh next [opts]           run the first stage that has not completed
#   ./setup.sh run <id> [opts]       run one stage, e.g. ./setup.sh run 01
#   ./setup.sh tool <name> [opts]    run a helper from tools/, e.g. verify
#   ./setup.sh configure [opts]      ask for your settings (addresses, accounts, models) and save them
#   ./setup.sh check                 validate config/node.env
#
# Options passed after the stage: --dry-run (print, change nothing), --yes (no prompts),
# plus any option the stage documents in its own header (see laptop/NN-*.sh).
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"

# --yes and --dry-run change how we ask, so read them before anything is asked
for a in "$@"; do
  case $a in
    --yes | -y) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
  esac
done

load_agent_user() {
  AGENT_USER=hermes
  if [[ -f ${NODE_ENV:-$HS_ROOT/config/node.env} ]]; then
    AGENT_USER=$(
      # shellcheck disable=SC1090
      source "${NODE_ENV:-$HS_ROOT/config/node.env}" && printf '%s' "${AGENT_USER:-hermes}")
  fi
}
load_agent_user

# need_settings KEYS  - make sure the settings file exists and KEYS are valid, asking the user for
# whatever is missing. KEYS comes from a script's "# NEEDS:" header; "-" means only that the file
# exists; empty means the script needs no settings at all.
need_settings() {
  local keys=$1 file=${NODE_ENV:-$HS_ROOT/config/node.env}
  [[ -n $keys ]] || return 0
  if [[ ! -f $file ]]; then
    if is_interactive; then
      log "no settings yet: let's create $file (about two minutes; nothing secret is asked)"
      configure_main
    else
      die "no settings yet ($file). Run ./setup.sh configure to be asked for them, or ./setup.sh configure --defaults --set KEY=VALUE ... for a scripted setup."
    fi
  fi
  if [[ $keys != - ]]; then
    # shellcheck disable=SC2086
    cfg_ensure $keys
  fi
  load_agent_user
}

meta() { sed -n "s/^# $2: *//p" "$1" | head -1; }

stages() { find "$HS_ROOT/laptop" -maxdepth 1 -name '[0-9][0-9]-*.sh' | sort; }

find_script() { # find_script KIND ID  (KIND: stage|tool)
  local f
  if [[ $1 == stage ]]; then
    f=$(find "$HS_ROOT/laptop" -maxdepth 1 -name "$2-*.sh" | sort | head -1)
  else
    f="$HS_ROOT/tools/$2.sh"
  fi
  [[ -f $f ]] || die "no such $1: $2 (try ./setup.sh list)"
  printf '%s\n' "$f"
}

is_done() { # is_done ID RUN-AS
  if [[ $2 == hermes ]]; then
    "${SUDO[@]}" test -f "${DESTDIR}/home/$AGENT_USER/.harness-setup/done/$1" 2>/dev/null
  else
    [[ -f ${DESTDIR}/var/lib/harness-setup/done/$1 ]]
  fi
}

cmd_list() {
  local f id who mark
  printf '%-3s %-7s %-13s %s\n' ID RUN-AS GUIDE TITLE
  for f in $(stages); do
    id=$(basename "$f" | cut -d- -f1); who=$(meta "$f" RUN-AS)
    mark=''
    if is_done "$id" "$who"; then mark='[done]'; fi
    printf '%-3s %-7s %-13s %s %s\n' "$id" "$who" "$(meta "$f" GUIDE)" "$(meta "$f" TITLE)" "$mark"
  done
  echo
  echo "Manual steps between stages are in docs/RUNBOOK.md. Helpers: $(find "$HS_ROOT/tools" -name '*.sh' -printf '%f ' | sed 's/\.sh//g')"
}

run_script() { # run_script FILE ARGS...
  local f=$1 who rel
  shift
  who=$(meta "$f" RUN-AS)
  if [[ $who == hermes && " $* " != *" --dry-run "* ]]; then
    publish_shared
    rel=${f#"$HS_ROOT"/}
    log "running $rel as '$AGENT_USER' (machinectl gives it a real login session)"
    "${SUDO[@]}" machinectl -q shell "$AGENT_USER@" /bin/bash "$HS_SHARED/$rel" "$@"
  else
    bash "$f" "$@"
  fi
  if [[ $f == */laptop/* && " $* " != *" --dry-run "* ]]; then
    local id; id=$(basename "$f" | cut -d- -f1)
    is_done "$id" "$who" || warn "stage $id did not report completion - scroll up for the reason, fix it and re-run"
  fi
}

cmd=${1:-help}
[[ $# -gt 0 ]] && shift
case $cmd in
  list | status) cmd_list ;;
  check)
    need_settings -
    load_config
    for v in OR_WORKER_MODEL OR_REVIEW_MODEL OR_COMPRESSION_MODEL OR_FALLBACK_MODEL; do
      [[ -n ${!v:-} ]] || warn "$v is empty (needed from stage 07 on)"
    done
    ok "config/node.env parsed"
    ;;
  run)
    [[ $# -ge 1 ]] || die "usage: ./setup.sh run <id> [options]"
    id=$1; shift
    script=$(find_script stage "$id")
    need_settings "$(meta "$script" NEEDS)"
    run_script "$script" "$@"
    ;;
  next)
    for f in $(stages); do
      id=$(basename "$f" | cut -d- -f1)
      if ! is_done "$id" "$(meta "$f" RUN-AS)"; then
        log "next stage: $id"
        need_settings "$(meta "$f" NEEDS)"
        run_script "$f" "$@"
        exit 0
      fi
    done
    ok "all stages are done - run: ./setup.sh tool verify"
    ;;
  tool)
    [[ $# -ge 1 ]] || die "usage: ./setup.sh tool <name> [options]"
    name=$1; shift
    script=$(find_script tool "$name")
    need_settings "$(meta "$script" NEEDS)"
    run_script "$script" "$@"
    ;;
  configure | config) configure_main "$@" ;;
  help | -h | --help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$cmd' (try ./setup.sh help)" ;;
esac
