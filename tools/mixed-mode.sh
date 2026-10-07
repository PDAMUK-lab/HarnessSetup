#!/usr/bin/env bash
# TITLE: Mixed mode (cloud planner and reviewer, sub-agents on the local GPUs) as a third profile
# RUN-AS: hermes
# GUIDE: extension (mixed mode; docs/RUNBOOK.md)
# NEEDS: OR_FALLBACK_MODEL OR_WORKER_MODEL DESKTOP_IP LLM_PORT DESKTOP_MODEL_ALIAS DESKTOP_CTX LAPTOP_MODEL_ALIAS LAPTOP_CTX V100_ENABLED V100_PRIMARY V100_MODEL_ALIAS V100_CTX V100_PORT OFFLINE
# Run it last, on a node where every stage is done (it needs the cloud profile from stage 07 and the desktop key and
# the local profile from stage 11). It clones the cloud profile into `mixed` and points only the sub-agents at the
# local endpoints: the first one in the chain (the desktop, or the V100 tier), then the others, then OpenRouter's
# worker model as a last resort. hermes-desktop, stage 11 and v100-laptop keep it in step from then on.
# Re-running is safe: it refreshes the endpoints and the chain, and keeps everything else in the profile.
# Options: --use   make `mixed` the default profile afterwards (the same as: hermes-mode mixed)
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
USE=0
for a in "$@"; do
  case $a in
    --use) USE=1 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
use_hermes_path
require_vars OR_FALLBACK_MODEL OR_WORKER_MODEL
[[ ${OFFLINE:-0} != 1 ]] || die "OFFLINE=1: mixed mode plans on OpenRouter, which an offline node cannot reach. Use the local profile (hermes-mode local)."
need_cmd hermes python3
cfg=$HOME/.hermes/config.yaml
pcfg=$HOME/.hermes/profiles/local/config.yaml
mdir=$HOME/.hermes/profiles/mixed
mcfg=$mdir/config.yaml
menv=$mdir/.env
[[ ( -f $cfg && -f $pcfg ) || $DRY_RUN == 1 ]] || die "run stages 07 and 11 first ($cfg and $pcfg must exist)"
key=$(grep -E '^DESKTOP_LLM_KEY=' "$HOME/.hermes/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
orkey=$(grep -E '^OPENROUTER_API_KEY=' "$HOME/.hermes/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
if [[ $DRY_RUN != 1 ]]; then
  [[ -n $key ]] || die "no DESKTOP_LLM_KEY in ~/.hermes/.env: run stage 11 first"
  [[ -n $orkey ]] || die "no OPENROUTER_API_KEY in ~/.hermes/.env: the planner needs it (hermes model, guide Step 10)"
fi

# ---- the profile: a clone of the cloud (default) one, so the planner, reviewer, tools and approvals match it
if hermes profile list 2>/dev/null | grep -qw mixed; then
  ok "profile 'mixed' already exists"
else
  run hermes profile create mixed --clone
fi
[[ -f $mcfg || $DRY_RUN == 1 ]] || die "$mcfg does not exist after 'hermes profile create'. Check 'hermes profile list' for where profiles live."

# both keys: OpenRouter for the planner, the desktop's for the sub-agents (the clone copies them; make sure)
if [[ $DRY_RUN != 1 ]]; then
  set_env_var "$menv" OPENROUTER_API_KEY "$orkey"
  set_env_var "$menv" DESKTOP_LLM_KEY "$key"
else
  log "[dry-run] would set OPENROUTER_API_KEY and DESKTOP_LLM_KEY in $menv"
fi

# the local endpoints (current aliases and context sizes) and the sub-agent limits; a sub-agent endpoint set by hand
# (base_url, api_key) would win over the chain's provider, so it goes
render_template "$HS_ROOT/templates/hermes/providers.yaml.tpl"
pfrag=$(mktemp); printf '%s' "$RENDERED" >"$pfrag"
render_template "$HS_ROOT/templates/hermes/mixed-profile.yaml.tpl"
frag=$(mktemp); printf '%s' "$RENDERED" >"$frag"
if [[ $DRY_RUN == 1 ]]; then
  log "[dry-run] would merge into $mcfg (after deleting delegation.base_url and delegation.api_key):"
  sed 's/^/    | /' "$pfrag" "$frag" >&2
else
  python3 "$HS_ROOT/lib/merge_yaml.py" "$mcfg" "$frag" --delete delegation.base_url --delete delegation.api_key
  python3 "$HS_ROOT/lib/merge_yaml.py" "$mcfg" "$pfrag"
fi
rm -f "$frag" "$pfrag"

# the planner's chain and the sub-agents' endpoint and fallbacks (V100 tier and "desktop away" included): lib/chain.sh
chain_apply "$cfg" "$pcfg" "$mcfg"
if desktop_away; then warn "the desktop is OUT of the loop right now: the sub-agents run on the laptop until 'hermes-desktop on'"; fi

# hermes-mode learns 'mixed'
install_template "$HS_ROOT/templates/bin/hermes-mode.tpl" "$HOME/.local/bin/hermes-mode" 755 self
chain_probes

if ((USE)); then run hermes profile use mixed; fi
if [[ $DRY_RUN != 1 ]]; then
  if grep -qE '^ *(base_url|api_key):' <(sed -n '/^delegation:/,/^[^ ]/p' "$mcfg"); then
    warn "delegation in $mcfg still has a base_url or api_key - it would override the local endpoint"
  fi
  hermes -p mixed fallback list || warn "'hermes -p mixed fallback list' failed - check the fallback_providers block in $mcfg"
fi

IFS='|' read -r first_p first_model < <(chain_entries)
cat <<MSG
Done. The 'mixed' profile plans and reviews on OpenRouter (as the cloud profile does) and runs its sub-agents on
$first_model ($first_p), one at a time; the other local endpoints, then OpenRouter's worker model, are their fallbacks.
  * Switch:  hermes-mode mixed      (hermes-mode cloud / hermes-mode local switch back; new sessions follow)
    or one session only:  hermes -p mixed --tui
  * Try it in a repo: ask for two sub-agents in parallel, press Ctrl+T, and watch the desktop's console work.
  * Desktop away (hermes-desktop off) moves the sub-agents to the laptop; hermes-desktop on moves them back.
  * Scheduled jobs stay in their own profiles: this profile has no cron jobs of its own.
MSG
