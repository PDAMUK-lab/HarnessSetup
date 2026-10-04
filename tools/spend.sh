#!/usr/bin/env bash
# TITLE: OpenRouter credit: how much of the key's limit is used (warns at SPEND_WARN_PCT)
# RUN-AS: hermes
# GUIDE: Step 10 (the credit limit is the hard stop)
# NEEDS: SPEND_WARN_PCT AGENT_USER
# Exit status: 0 fine, 1 warning (near the limit, no limit, or a limit that never resets), 2 used up or unknown.
set -Euo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
key=$(grep -m1 '^OPENROUTER_API_KEY=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
[[ -n $key ]] || die "no OPENROUTER_API_KEY in ~/.hermes/.env (run 'hermes model' as $AGENT_USER first)"
json=$(curl -s -m 15 -H "Authorization: Bearer $key" https://openrouter.ai/api/v1/key || true)
IFS='|' read -r level msg < <(or_spend "$json")
case $level in
  ok) ok "OpenRouter: $msg"; exit 0 ;;
  warn) warn "OpenRouter: $msg"; exit 1 ;;
  *) echo "OpenRouter: $msg" >&2; exit 2 ;;
esac
