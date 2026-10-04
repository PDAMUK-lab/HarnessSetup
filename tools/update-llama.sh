#!/usr/bin/env bash
# TITLE: Update llama.cpp on the laptop, and roll back automatically if the new build does not serve tool calls
# RUN-AS: admin
# GUIDE: Step 17 ("Updating"), with an undo
# NEEDS: LLM_PORT LAPTOP_MODEL_ALIAS
# Usage:  update-llama.sh              rebuild from the latest llama.cpp (stage 09), restart, test; on failure put the old build back
#         update-llama.sh --vulkan     the same with the Vulkan backend (as stage 09 --vulkan)
#         update-llama.sh --rollback   put the previous build back by hand
# The previous build is kept in /opt/llama.cpp/bin.prev.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
ACTION=update BACKEND=--cuda
for a in "$@"; do
  case $a in
    --rollback) ACTION=rollback ;;
    --vulkan) BACKEND=--vulkan ;;
    --cuda) BACKEND=--cuda ;;
    *) common_flag "$a" || die "unknown option: $a   (usage: update-llama.sh [--vulkan|--rollback])" ;;
  esac
done
load_config
prefix=${HS_LLAMA_PREFIX:-/opt/llama.cpp}   # test seams: HS_LLAMA_PREFIX, HS_LLAMA_BUILD (the build command)
bin=$prefix/bin prev=$prefix/bin.prev
base=http://127.0.0.1:$LLM_PORT
version() { "$1/llama-server" --version 2>&1 | grep -m1 -iE 'version|build' || echo unknown; }

healthy() { # the service answers, serves the right model and returns a tool call
  wait_http "$base/health" 180 || return 1
  local ids
  ids=$(curl -s -m 10 "$base/v1/models" | jq -r '.data[].id' 2>/dev/null || true)
  [[ $ids == "$LAPTOP_MODEL_ALIAS" ]] || return 1
  tool_call_smoke "$base" "$LAPTOP_MODEL_ALIAS"
}
restart() { sudo_run systemctl restart llama-server; }
restore_prev() {
  sudo_run test -d "$prev" || die "no previous build in $prev to go back to"
  sudo_run rm -rf "$bin.failed"
  sudo_run mv "$bin" "$bin.failed"
  sudo_run cp -a "$prev" "$bin"
  restart
}

if [[ $ACTION == rollback ]]; then
  restore_prev
  [[ $DRY_RUN == 1 ]] && exit 0
  if healthy; then ok "back on the previous build: $(version "$bin")"; else die "the previous build does not answer either: journalctl -u llama-server -n 50"; fi
  exit 0
fi

sudo_run test -x "$bin/llama-server" || die "no llama-server in $bin yet: run ./setup.sh run 09 first"
log "current build: $(version "$bin")"
sudo_run rm -rf "$prev"
sudo_run cp -a "$bin" "$prev"
if [[ -n ${HS_LLAMA_BUILD:-} ]]; then run bash -c "$HS_LLAMA_BUILD"
else run bash "$HS_ROOT/laptop/09-llama-cpp.sh" "$BACKEND" --yes; fi
restart
[[ $DRY_RUN == 1 ]] && exit 0
if healthy; then
  ok "updated: $(version "$bin") (the previous build stays in $prev; ./setup.sh tool update-llama --rollback goes back)"
else
  warn "the new build did not pass (health, model name or tool call): putting the previous one back"
  restore_prev
  if healthy; then die "rolled back to $(version "$bin"); the failed build is in $bin.failed (journalctl -u llama-server shows why)"; fi
  die "rolled back, but the previous build does not answer either: journalctl -u llama-server -n 50"
fi
