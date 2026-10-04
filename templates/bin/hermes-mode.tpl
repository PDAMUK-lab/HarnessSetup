#!/usr/bin/env bash
# hermes-mode [cloud|local|status] - switch the default Hermes profile and show what is reachable
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
KEY=$(grep -E '^DESKTOP_LLM_KEY=' ~/.hermes/.env 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
probe() { curl -s -m 3 -o /dev/null -w '%{http_code}' "$@" || true; }
# served URL [curl args] - the model id the server is actually serving (the alias), so a wrong model shows up here
served() {
  local url=$1; shift
  curl -s -m 3 "$@" "$url" 2>/dev/null |
    python3 -c 'import json,sys; print(",".join(m["id"] for m in json.load(sys.stdin)["data"]))' 2>/dev/null || true
}
show() { # show LABEL HEALTH_URL MODELS_URL [curl args]
  local label=$1 health=$2 models=$3 code id=''; shift 3
  code=$(probe "$@" "$health")
  if [[ $code == 200 ]]; then id=$(served "$models" "$@"); fi
  printf '%-30s: %s%s\n' "$label" "$code" "${id:+  serving $id}"
}
case "${1:-status}" in
  cloud) hermes profile use default ;;
  local) hermes profile use local ;;
  status) ;;
  *) echo "usage: hermes-mode [cloud|local|status]"; exit 2 ;;
esac
if [[ -e $HOME/.hermes/desktop-away ]]; then
  echo "*** the desktop is OUT of the loop since $(cat "$HOME/.hermes/desktop-away" 2>/dev/null) - 'hermes-desktop on' brings it back ***"
fi
show "laptop  (expects @@LAPTOP_MODEL_ALIAS@@)" http://127.0.0.1:@@LLM_PORT@@/health http://127.0.0.1:@@LLM_PORT@@/v1/models
show "desktop (day model @@DESKTOP_MODEL_ALIAS@@)" http://@@DESKTOP_IP@@:@@LLM_PORT@@/health http://@@DESKTOP_IP@@:@@LLM_PORT@@/v1/models -H "Authorization: Bearer $KEY"
# extra local endpoints (for example the V100 tier) register a "label|health url" file here
for f in "$HOME"/.hermes/hermes-mode.d/*; do
  [[ -f $f ]] || continue
  IFS='|' read -r label url <"$f" || true
  [[ -n ${url:-} ]] || continue
  show "$label" "$url" "${url%/health}/v1/models" -H "Authorization: Bearer $KEY"
done
echo "openrouter              : $(probe https://openrouter.ai/api/v1/models)"
hermes profile list
