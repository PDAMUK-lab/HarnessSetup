#!/usr/bin/env bash
# TITLE: V100 GPU tier, laptop side (desktop-v100 endpoint, local profile, fallback chain)
# RUN-AS: hermes
# GUIDE: extension (optional V100 tier; docs/V100.md)
# NEEDS: V100_ENABLED=1 DESKTOP_IP LLM_PORT V100_PORT V100_MODEL_ALIAS V100_CTX V100_PRIMARY DESKTOP_MODEL_ALIAS LAPTOP_MODEL_ALIAS OR_FALLBACK_MODEL
# The tier must be switched on in the settings (the dispatcher offers to do that). The desktop half is
# desktop/windows/Install-V100.ps1. Run this after stage 11 (it reuses the desktop API key stored there).
# Re-running is safe: it rewrites the V100 endpoint, the fallback chain and the local profile's model, nothing else.
# (Stage 11 does the same when the tier is on, so a fresh install needs no separate run.)
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
use_hermes_path
require_vars OR_FALLBACK_MODEL
[[ ${V100_ENABLED:-0} == 1 ]] || die "the V100 tier is off. Run it through the dispatcher, which offers to turn it on: ./setup.sh tool v100-laptop"
[[ $V100_PORT != "$LLM_PORT" ]] || die "V100_PORT and LLM_PORT are both $LLM_PORT: the two desktop servers need different ports (./setup.sh configure --only V100_PORT)"
need_cmd hermes python3
cfg=$HOME/.hermes/config.yaml
pcfg=$HOME/.hermes/profiles/local/config.yaml
[[ -f $cfg && -f $pcfg || $DRY_RUN == 1 ]] || die "run stages 07 and 11 first ($cfg and $pcfg must exist)"
if [[ $DRY_RUN != 1 ]] && ! grep -q '^DESKTOP_LLM_KEY=' "$HOME/.hermes/.env" 2>/dev/null; then
  die "no DESKTOP_LLM_KEY in ~/.hermes/.env: run stage 11 first (the V100 server uses the same API key as the desktop's other server)"
fi

# the V100 endpoint, the fallback chain and the local profile's model (V100_PRIMARY decides the order; lib/chain.sh)
chain_apply "$cfg" "$pcfg"
if desktop_away; then warn "the desktop is OUT of the loop right now: the chain leaves out every desktop endpoint, the V100 included (hermes-desktop on)"; fi

# hermes-mode shows the extra endpoint (the template reads ~/.hermes/hermes-mode.d/*)
install_template "$HS_ROOT/templates/bin/hermes-mode.tpl" "$HOME/.local/bin/hermes-mode" 755 self
chain_probes

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

IFS='|' read -r _ first_model < <(chain_entries)
cat <<MSG
Done. The V100 endpoint is 'desktop-v100' ($V100_MODEL_ALIAS at $DESKTOP_IP:$V100_PORT).
  * Local endpoints are tried in this order after OpenRouter:  hermes-desktop status
  * Try it:  hermes-mode local ; hermes chat -q "Which model are you?"   (expect $first_model)
  * Change the order with ./setup.sh configure --only V100_PRIMARY, then re-run this tool.
MSG
