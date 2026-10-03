#!/usr/bin/env bash
# TITLE: Local endpoints, fallback chain, the `local` profile, hermes-mode
# RUN-AS: hermes
# GUIDE: Steps 21-23
# NEEDS: OR_FALLBACK_MODEL DESKTOP_IP LLM_PORT DESKTOP_MODEL_ALIAS DESKTOP_CTX LAPTOP_CTX LAPTOP_MODEL_ALIAS V100_ENABLED
# Needs the desktop API key printed by Install-Llama.ps1 (prompted, or set DESKTOP_LLM_KEY in the environment).
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
stage_begin
use_hermes_path
need_cmd hermes python3
require_vars OR_FALLBACK_MODEL
cfg=$HOME/.hermes/config.yaml
pcfg=$HOME/.hermes/profiles/local/config.yaml
penv=$HOME/.hermes/profiles/local/.env
merge() { python3 "$HS_ROOT/lib/merge_yaml.py" "$@"; }
[[ -f $cfg ]] || fail_or_warn "$cfg is missing - finish stages 06 and 07 first"

# ---- Step 21: the key, the endpoints and the fallback chain
key=${DESKTOP_LLM_KEY:-}
if [[ -z $key ]]; then
  existing=$(grep -E '^DESKTOP_LLM_KEY=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2- || true)
  if [[ -n $existing ]]; then
    key=$existing; ok "using the DESKTOP_LLM_KEY already in ~/.hermes/.env"
  elif [[ $DRY_RUN == 1 ]]; then
    key=dry-run-key
  else
    [[ -r /dev/tty ]] || die "need a terminal to paste the desktop key (or export DESKTOP_LLM_KEY)"
    read -rs -p "Paste the desktop API key printed by Install-Llama.ps1 (input hidden): " key </dev/tty
    echo
  fi
fi
[[ -n $key && $key != *[[:space:]\'\"]* ]] || die "the key is empty or contains spaces or quotes"
set_env_var "$HOME/.hermes/.env" DESKTOP_LLM_KEY "$key"

render_template "$HS_ROOT/templates/hermes/providers.yaml.tpl"
frag=$(mktemp); printf '%s' "$RENDERED" >"$frag"
if [[ $DRY_RUN == 1 ]]; then log "[dry-run] would merge providers + fallback chain into $cfg"; sed 's/^/    | /' "$frag" >&2; else merge "$cfg" "$frag"; fi

# ---- Step 22: the local profile (cloned from the default one, then stripped of the cloud)
if hermes profile list 2>/dev/null | grep -qw local; then
  ok "profile 'local' already exists"
else
  run hermes profile create local --clone
fi
render_template "$HS_ROOT/templates/hermes/local-profile.yaml.tpl"
printf '%s' "$RENDERED" >"$frag"
if [[ $DRY_RUN == 1 ]]; then
  log "[dry-run] would merge into $pcfg (after deleting delegation.provider, auxiliary.review, auxiliary.compression):"
  sed 's/^/    | /' "$frag" >&2
else
  [[ -f $pcfg ]] || die "$pcfg does not exist after 'hermes profile create'. Check 'hermes profile list' for where profiles live."
  merge "$pcfg" "$frag" --delete delegation.provider --delete auxiliary.review --delete auxiliary.compression
  # nothing in this profile may reach the cloud
  touch "$penv" && chmod 600 "$penv"
  sed -i '/^OPENROUTER_API_KEY=/d' "$penv"
  set_env_var "$penv" DESKTOP_LLM_KEY "$key"
  if grep -qi openrouter "$pcfg"; then warn "the local profile config still mentions openrouter: $(grep -ni openrouter "$pcfg" | head -3 | tr '\n' ' ')"; fi
  if grep -q '^OPENROUTER' "$penv"; then die "OPENROUTER_API_KEY is still in $penv"; fi
fi
rm -f "$frag"

# ---- Step 23: one command to switch modes
install_template "$HS_ROOT/templates/bin/hermes-mode.tpl" "$HOME/.local/bin/hermes-mode" 755 self
# this stage rewrites the chain without the V100 tier; the tool puts it back (and registers its probe)
if [[ ${V100_ENABLED:-0} != 1 ]]; then run rm -f "$HOME/.hermes/hermes-mode.d/desktop-v100"; fi

if [[ $DRY_RUN != 1 ]]; then
  hermes fallback list || warn "'hermes fallback list' failed - check the fallback_providers block in $cfg"
fi
stage_end
cat <<MSG
Manual steps left in this phase:
  * Trim the local profile's tools (each toolset slows every prompt on these GPUs):
      hermes -p local tools      -> turn OFF browser, image generation, voice and web search
    (Use 'hermes -p local ...': a bare 'local' command is shadowed by the shell builtin of the same name.)
  * Try it:  hermes-mode local ; hermes chat -q "Which model are you?"   (expect $DESKTOP_MODEL_ALIAS)
    Turn the desktop off and ask again: expect $LAPTOP_MODEL_ALIAS after a short retry. Then: hermes-mode cloud
MSG
if [[ ${V100_ENABLED:-0} == 1 ]]; then
  echo "The V100 tier is on: run  ./setup.sh tool v100-laptop  to add the V100 endpoint to the chain again."
fi
echo "Next: ./setup.sh run 12"
