#!/usr/bin/env bash
# TITLE: Gateway and dashboard as services
# RUN-AS: hermes
# GUIDE: Steps 13-14
# NEEDS: DASHBOARD_PORT LAPTOP_IP
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
stage_begin
use_hermes_path
need_user_session
need_cmd hermes curl jq ss

log "Step 13: the gateway fires cron jobs and runs unattended work"
run hermes gateway install
run hermes gateway status
run hermes cron status

log "Step 14: the dashboard, bound to loopback only"
[[ $DRY_RUN == 1 ]] || HERMES_BIN=$(command -v hermes)
export HERMES_BIN
install_template "$HS_ROOT/templates/systemd/hermes-dashboard.service.tpl" \
  "$HOME/.config/systemd/user/hermes-dashboard.service" 644 self
run systemctl --user daemon-reload
run systemctl --user enable --now hermes-dashboard

if [[ $DRY_RUN != 1 ]]; then
  log "waiting for the dashboard (the first start builds the web frontend and can take a minute or two)"
  up=0
  st=$(mktemp)
  for _ in $(seq 1 60); do
    if curl -fsS -m 3 "http://127.0.0.1:$DASHBOARD_PORT/api/status" >"$st" 2>/dev/null; then up=1; break; fi
    sleep 3
  done
  [[ $up == 1 ]] || die "dashboard did not answer on 127.0.0.1:$DASHBOARD_PORT. See: journalctl --user -u hermes-dashboard"
  auth_req=$(jq -r '.auth_required' "$st")
  rm -f "$st"
  [[ $auth_req == false ]] || warn "auth_required is '$auth_req' (guide expects false on loopback)"
  binds=$(ss -tln | awk -v p=":$DASHBOARD_PORT" '$4 ~ p"$" {print $4}')
  [[ -n $binds ]] || die "nothing is listening on port $DASHBOARD_PORT"
  if grep -qvE '^127\.0\.0\.1:' <<<"$binds"; then
    die "the dashboard listens on a non-loopback address ($binds). Anyone who reaches it controls an agent with root. Stop it: systemctl --user stop hermes-dashboard"
  fi
  ok "dashboard listens on $binds only"
fi
stage_end
cat <<MSG
Open it from the desktop with desktop/windows/hermes-tunnel.cmd, then browse to http://localhost:$DASHBOARD_PORT
(use $DASHBOARD_PORT on BOTH ends of the tunnel). From a phone, http://$LAPTOP_IP:$DASHBOARD_PORT must NOT load.
Set approval mode to off on the dashboard's Config page. Next: local models (./setup.sh run 09).
MSG
