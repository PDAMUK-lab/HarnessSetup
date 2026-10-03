#!/usr/bin/env bash
# TITLE: V100 GPU tier, laptop side (desktop-v100 endpoint, local profile, fallback chain)
# RUN-AS: hermes
# GUIDE: extension (optional V100 tier; docs/V100.md)
# NEEDS: V100_ENABLED=1 DESKTOP_IP LLM_PORT V100_PORT V100_MODEL_ALIAS V100_CTX V100_PRIMARY DESKTOP_MODEL_ALIAS LAPTOP_MODEL_ALIAS OR_FALLBACK_MODEL
# The tier must be switched on in the settings (the dispatcher offers to do that). The desktop half is
# desktop/windows/Install-V100.ps1. Run this after stage 11 (it reuses the desktop API key stored there).
# Re-running is safe: it rewrites the V100 endpoint, the fallback chain and the local profile's model, nothing else.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
stage_begin() { :; } # a tool, not a numbered stage
use_hermes_path
[[ ${V100_ENABLED:-0} == 1 ]] || die "the V100 tier is off. Run it through the dispatcher, which offers to turn it on: ./setup.sh tool v100-laptop"
[[ $V100_PORT != "$LLM_PORT" ]] || die "V100_PORT and LLM_PORT are both $LLM_PORT: the two desktop servers need different ports (./setup.sh configure --only V100_PORT)"
need_cmd hermes python3
cfg=$HOME/.hermes/config.yaml
pcfg=$HOME/.hermes/profiles/local/config.yaml
merge() { python3 "$HS_ROOT/lib/merge_yaml.py" "$@"; }
[[ -f $cfg && -f $pcfg || $DRY_RUN == 1 ]] || die "run stages 07 and 11 first ($cfg and $pcfg must exist)"
if [[ $DRY_RUN != 1 ]] && ! grep -q '^DESKTOP_LLM_KEY=' "$HOME/.hermes/.env" 2>/dev/null; then
  die "no DESKTOP_LLM_KEY in ~/.hermes/.env: run stage 11 first (the V100 server uses the same API key as the desktop's other server)"
fi

# V100_PRIMARY picks the order of the two desktop endpoints: V100 first, or the day model first
if [[ ${V100_PRIMARY:-1} == 1 ]]; then
  CHAIN1_PROVIDER=custom:desktop-v100 CHAIN1_MODEL=$V100_MODEL_ALIAS
  CHAIN2_PROVIDER=custom:desktop CHAIN2_MODEL=$DESKTOP_MODEL_ALIAS
else
  CHAIN1_PROVIDER=custom:desktop CHAIN1_MODEL=$DESKTOP_MODEL_ALIAS
  CHAIN2_PROVIDER=custom:desktop-v100 CHAIN2_MODEL=$V100_MODEL_ALIAS
fi
export CHAIN1_PROVIDER CHAIN1_MODEL CHAIN2_PROVIDER CHAIN2_MODEL

frag=$(mktemp)
trap 'rm -f "$frag"' EXIT
merge_into() { # merge_into TARGET TEMPLATE  - render the template and deep-merge it (or show it on a dry run)
  render_template "$2"
  printf '%s' "$RENDERED" >"$frag"
  if [[ $DRY_RUN == 1 ]]; then
    log "[dry-run] would merge $(basename "$2") into $1"
    sed 's/^/    | /' "$frag" >&2
  else
    merge "$1" "$frag"
  fi
}
merge_into "$cfg" "$HS_ROOT/templates/hermes/v100-provider.yaml.tpl"
merge_into "$cfg" "$HS_ROOT/templates/hermes/v100-chain.yaml.tpl"
merge_into "$pcfg" "$HS_ROOT/templates/hermes/v100-provider.yaml.tpl"
merge_into "$pcfg" "$HS_ROOT/templates/hermes/v100-local-profile.yaml.tpl"

# hermes-mode shows the extra endpoint (the template reads ~/.hermes/hermes-mode.d/*)
install_template "$HS_ROOT/templates/bin/hermes-mode.tpl" "$HOME/.local/bin/hermes-mode" 755 self
printf '%s\n' "desktop-v100 $V100_MODEL_ALIAS|http://$DESKTOP_IP:$V100_PORT/health" | put_file "$HOME/.hermes/hermes-mode.d/desktop-v100" 644 self

if [[ $DRY_RUN != 1 ]]; then
  hermes fallback list || warn "'hermes fallback list' failed - check the fallback_providers block in $cfg"
  key=$(grep -E '^DESKTOP_LLM_KEY=' "$HOME/.hermes/.env" | head -1 | cut -d= -f2- | tr -d "'\"")
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $key" "http://$DESKTOP_IP:$V100_PORT/health" || true)
  if [[ $c == 200 ]]; then ok "the V100 server answers on $DESKTOP_IP:$V100_PORT"
  else warn "the V100 server returned '$c' on $DESKTOP_IP:$V100_PORT (on the desktop: run Install-V100.ps1, then start the 'llama-v100' task)"; fi
  # the firewall (stage 13) only lets the laptop reach ports it knows about
  if sudo -n ufw status 2>/dev/null | grep -q '^Status: active' && ! sudo -n ufw status 2>/dev/null | grep -qE "(^|[^0-9])$V100_PORT(/tcp)?[[:space:]]"; then
    warn "the laptop firewall is on and has no rule for port $V100_PORT: re-run ./setup.sh run 13 so it can reach the V100 server"
  fi
fi

cat <<MSG
Done. The V100 endpoint is 'desktop-v100' ($V100_MODEL_ALIAS at $DESKTOP_IP:$V100_PORT).
  * Order of local endpoints: $CHAIN1_PROVIDER, then $CHAIN2_PROVIDER, then custom:laptop (change it with ./setup.sh configure --only V100_PRIMARY, then re-run this tool).
  * Try it:  hermes-mode local ; hermes chat -q "Which model are you?"   (expect $CHAIN1_MODEL)
  * Re-running stage 11 puts the chain back without the V100: run this tool again afterwards.
MSG
