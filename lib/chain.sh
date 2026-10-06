#!/usr/bin/env bash
# The order of Hermes's local endpoints (V100 tier, the desktop's day model, the laptop), in one place.
# Stage 11, tools/v100-laptop.sh and tools/desktop-loop.sh all call chain_apply, so they always agree.
# Sourced by lib/common.sh; needs the settings loaded (load_config).

# The "desktop away" flag: while this file exists every desktop endpoint is left out of the chain.
desktop_away_flag() { printf '%s' "$HOME/.hermes/desktop-away"; }
desktop_away() { [[ -e $(desktop_away_flag) ]]; }

# chain_entries  - the local endpoints in order, one "provider|model" per line
chain_entries() {
  local v100=0 first=0
  [[ ${V100_ENABLED:-0} == 1 ]] && v100=1
  [[ ${V100_PRIMARY:-1} == 1 ]] && first=1
  if ! desktop_away; then
    if ((v100 && first)); then printf 'custom:desktop-v100|%s\n' "$V100_MODEL_ALIAS"; fi
    printf 'custom:desktop|%s\n' "$DESKTOP_MODEL_ALIAS"
    if ((v100 && !first)); then printf 'custom:desktop-v100|%s\n' "$V100_MODEL_ALIAS"; fi
  fi
  printf 'custom:laptop|%s\n' "$LAPTOP_MODEL_ALIAS"
}

# chain_main_yaml  - the default profile: OpenRouter first, then the local endpoints (offline: no OpenRouter, local only)
chain_main_yaml() {
  local p m list first=''
  if [[ ${OFFLINE:-0} == 1 ]]; then
    # no internet: the cloud is nowhere in the chain, and the default profile itself runs on the first local endpoint
    first=$(chain_entries | head -1)
    list=$(while IFS='|' read -r p m; do printf '  - provider: %s\n    model: %s\n' "$p" "$m"; done < <(chain_entries))
    printf 'model:\n  provider: %s\n  default: %s\n\n' "${first%%|*}" "${first#*|}"
    printf 'fallback_providers:\n%s\n' "$list"
  else
    list=$(printf '  - provider: openrouter\n    model: "%s"\n' "$OR_FALLBACK_MODEL"
      while IFS='|' read -r p m; do printf '  - provider: %s\n    model: %s\n' "$p" "$m"; done < <(chain_entries))
    printf 'fallback_providers:\n%s\n' "$list"
  fi
  # Sub-agents pinned to a provider (delegation.provider) get NO fallback unless delegation.fallback_providers says so
  # (Hermes config_defaults: "A child pinned by provider, endpoint, or model gets no fallback unless this setting
  # declares one explicitly"), so without this an OpenRouter outage fails every sub-agent while the planner falls back.
  printf '\ndelegation:\n  fallback_providers:\n  %s\n' "${list//$'\n'/$'\n'  }"
}

# chain_local_yaml  - the `local` profile: the first endpoint is its model, the rest are its fallbacks (never OpenRouter)
chain_local_yaml() {
  local p m n=0
  local -a rest=()
  while IFS='|' read -r p m; do
    if ((n == 0)); then printf 'model:\n  provider: %s\n  default: %s\n\n' "$p" "$m"; else rest+=("$p|$m"); fi
    n=$((n + 1))
  done < <(chain_entries)
  if ((${#rest[@]} == 0)); then
    printf 'fallback_providers: []\n'
  else
    printf 'fallback_providers:\n'
    for p in "${rest[@]}"; do printf '  - provider: %s\n    model: %s\n' "${p%%|*}" "${p#*|}"; done
  fi
  # This profile's sub-agents are pinned to the laptop endpoint (delegation.base_url), so they too need an explicit
  # fallback: the desktop endpoints (the planner waits for its sub-agent, so the desktop's single slot is free).
  printf '\ndelegation:\n'
  local any=0
  while IFS='|' read -r p m; do
    [[ $p == custom:laptop ]] && continue
    ((any)) || printf '  fallback_providers:\n'
    any=1
    printf '    - provider: %s\n      model: %s\n' "$p" "$m"
  done < <(chain_entries)
  ((any)) || printf '  fallback_providers: []\n'
}

# chain_merge TARGET  - deep-merge the YAML on stdin into TARGET (or just show it on a dry run / when TARGET is not there yet)
chain_merge() {
  local target=$1 frag
  frag=$(mktemp)
  cat >"$frag"
  if [[ $DRY_RUN == 1 ]]; then
    log "[dry-run] would merge into $target:"
    sed 's/^/    | /' "$frag" >&2
  else
    python3 "$HS_ROOT/lib/merge_yaml.py" "$target" "$frag"
  fi
  rm -f "$frag"
}

# chain_apply MAIN_CONFIG LOCAL_CONFIG  - write the V100 endpoint (when the tier is on) and the chain into both configs
chain_apply() {
  local main=$1 localcfg=$2
  if [[ ${V100_ENABLED:-0} == 1 ]]; then
    render_template "$HS_ROOT/templates/hermes/v100-provider.yaml.tpl"
    printf '%s' "$RENDERED" | chain_merge "$main"
    if [[ -f $localcfg || $DRY_RUN == 1 ]]; then printf '%s' "$RENDERED" | chain_merge "$localcfg"; fi
  fi
  chain_main_yaml | chain_merge "$main"
  if [[ -f $localcfg || $DRY_RUN == 1 ]]; then chain_local_yaml | chain_merge "$localcfg"; fi
}

# chain_probes  - the extra line `hermes-mode status` shows for the V100 endpoint (present only while the tier is on)
chain_probes() {
  local f=$HOME/.hermes/hermes-mode.d/desktop-v100
  if [[ ${V100_ENABLED:-0} == 1 ]]; then
    printf '%s\n' "desktop-v100 $V100_MODEL_ALIAS|http://$DESKTOP_IP:$V100_PORT/health" | put_file "$f" 644 self
  else
    run rm -f "$f"
  fi
}
