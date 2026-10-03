#!/usr/bin/env bash
# TITLE: Laptop model service (Qwen3.5-9B, context cache in RAM)
# RUN-AS: admin
# GUIDE: Steps 18, 20
# NEEDS: LAPTOP_QUANT LAPTOP_MODEL_FILE LAPTOP_MODEL_URL LAPTOP_MODEL_ALIAS LAPTOP_CTX LLM_PORT
# Options: --bench (measure context cache in VRAM vs RAM first)  --no-start (install, don't start)
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
BENCH=0 START=1
for a in "$@"; do
  case $a in
    --bench) BENCH=1 ;;
    --no-start) START=0 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
stage_begin
[[ -x /opt/llama.cpp/bin/llama-server || $DRY_RUN == 1 ]] || die "llama-server is not installed - run stage 09 first"

if id llm >/dev/null 2>&1; then ok "user llm exists"; else sudo_run adduser --system --group --home /srv/llm llm; fi
sudo_run install -d -o llm -g llm /srv/models /srv/llm/slots

avail=$(df --output=avail -B1G /srv 2>/dev/null | tail -1 | tr -d ' ' || true)
[[ -z $avail || ${avail:-0} -ge 10 ]] || fail_or_warn "only ${avail}GB free under /srv; the model needs about 7GB plus working space"

download_gguf "$LAPTOP_MODEL_URL" "/srv/models/$LAPTOP_MODEL_FILE" llm

if [[ $BENCH == 1 ]]; then
  log "benchmark: cache in VRAM (-nkvo 0) vs RAM (-nkvo 1), empty and 32K deep. With Q5 the cache usually only fits in RAM."
  run /opt/llama.cpp/bin/llama-bench -m "/srv/models/$LAPTOP_MODEL_FILE" \
    -ngl 99 -fa 1 -ctk f16 -ctv q8_0 -nkvo 0,1 -d 0,32768 -p 2048 -n 128
fi

install_template "$HS_ROOT/templates/systemd/llama-server.service.tpl" /etc/systemd/system/llama-server.service 644
sudo_run systemctl daemon-reload
if [[ $START == 1 ]]; then
  sudo_run systemctl enable --now llama-server
  sudo_run systemctl restart llama-server
  if [[ $DRY_RUN != 1 ]]; then
    log "waiting for the model to load (up to 3 minutes)"
    if ! wait_http "http://127.0.0.1:$LLM_PORT/health" 180; then
      journalctl -u llama-server -n 25 --no-pager || true
      die "llama-server did not come up. If you see a CUDA out-of-memory error, switch LAPTOP_MODEL_FILE/URL to the UD-Q4_K_XL file in config/node.env and re-run this stage."
    fi
    ids=$(curl -s "http://127.0.0.1:$LLM_PORT/v1/models" | jq -r '.data[].id')
    [[ $ids == "$LAPTOP_MODEL_ALIAS" ]] || die "server reports model '$ids', expected '$LAPTOP_MODEL_ALIAS'"
    ok "serving $ids"
    log "tool-call smoke test (the model must answer with a get_weather call, not prose)"
    tool_call_smoke "http://127.0.0.1:$LLM_PORT" "$LAPTOP_MODEL_ALIAS" ||
      die "no tool call came back. Is the server running with --jinja? (journalctl -u llama-server)"
    ok "tool calls work"
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader || true
  fi
fi
stage_end
echo "nvidia-smi should show about 7GB used. Next: set up the desktop (desktop/windows/Install-Llama.ps1), then:  ./setup.sh run 11"
