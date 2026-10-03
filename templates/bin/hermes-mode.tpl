#!/usr/bin/env bash
# hermes-mode [cloud|local|status] - switch the default Hermes profile and show what is reachable
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
KEY=$(grep -E '^DESKTOP_LLM_KEY=' ~/.hermes/.env 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
probe() { curl -s -m 3 -o /dev/null -w '%{http_code}' "$@" || true; }
case "${1:-status}" in
  cloud) hermes profile use default ;;
  local) hermes profile use local ;;
  status) ;;
  *) echo "usage: hermes-mode [cloud|local|status]"; exit 2 ;;
esac
echo "laptop  @@LAPTOP_MODEL_ALIAS@@      : $(probe http://127.0.0.1:@@LLM_PORT@@/health)"
echo "desktop @@DESKTOP_MODEL_ALIAS@@ : $(probe -H "Authorization: Bearer $KEY" http://@@DESKTOP_IP@@:@@LLM_PORT@@/health)"
# extra local endpoints (for example the V100 tier) register a "label|health url" file here
for f in "$HOME"/.hermes/hermes-mode.d/*; do
  [[ -f $f ]] || continue
  IFS='|' read -r label url <"$f" || true
  [[ -n ${url:-} ]] || continue
  printf '%-30s: %s\n' "$label" "$(probe -H "Authorization: Bearer $KEY" "$url")"
done
echo "openrouter              : $(probe https://openrouter.ai/api/v1/models)"
hermes profile list
