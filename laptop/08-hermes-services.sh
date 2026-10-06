#!/usr/bin/env bash
# TITLE: Gateway and dashboard as services
# RUN-AS: hermes
# GUIDE: Steps 13-14
# NEEDS: DASHBOARD_PORT LAPTOP_IP DASHBOARD_FROM
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
# browsers on the LAN (DASHBOARD_FROM): Hermes refuses a non-loopback bind without a login, so set one first
if [[ $DASHBOARD_BIND != 127.0.0.1 && $DRY_RUN != 1 ]] &&
  ! python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; sys.exit(0 if ((d.get("dashboard") or {}).get("basic_auth") or {}).get("username") else 1)' "$HOME/.hermes/config.yaml" 2>/dev/null; then
  log "DASHBOARD_FROM lets browsers in from $DASHBOARD_FROM: the dashboard needs a user name and password first"
  bash "$HS_ROOT/tools/dashboard-login.sh" --yes || die "no dashboard login set: run ./setup.sh tool dashboard-login, then this stage again"
fi
install_template "$HS_ROOT/templates/systemd/hermes-dashboard.service.tpl" \
  "$HOME/.config/systemd/user/hermes-dashboard.service" 644 self
run systemctl --user daemon-reload
run systemctl --user enable --now hermes-dashboard
# restart even when it is already running: a re-run must apply a changed unit (DASHBOARD_FROM moves the bind)
run systemctl --user restart hermes-dashboard

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
  if [[ $DASHBOARD_BIND == 127.0.0.1 ]]; then
    [[ $auth_req == false ]] || warn "auth_required is '$auth_req' (guide expects false on loopback)"
  else
    [[ $auth_req == true ]] || die "the dashboard listens on the LAN but auth_required is '$auth_req': stop it (systemctl --user stop hermes-dashboard)"
  fi
  binds=$(ss -tln | awk -v p=":$DASHBOARD_PORT" '$4 ~ p"$" {print $4}')
  [[ -n $binds ]] || die "nothing is listening on port $DASHBOARD_PORT"
  if [[ $DASHBOARD_BIND == 127.0.0.1 ]] && grep -qvE '^127\.0\.0\.1:' <<<"$binds"; then
    die "the dashboard listens on a non-loopback address ($binds). Anyone who reaches it controls an agent with root. Stop it: systemctl --user stop hermes-dashboard"
  fi
  ok "dashboard listens on $binds only"
fi
stage_end
cat <<MSG
Open it from the desktop with desktop/windows/hermes-tunnel.cmd, then browse to http://localhost:$DASHBOARD_PORT
(use $DASHBOARD_PORT on BOTH ends of the tunnel). $(if [[ $DASHBOARD_BIND == 127.0.0.1 ]]; then echo "From a phone, http://$LAPTOP_IP:$DASHBOARD_PORT must NOT load."; else echo "From the devices in DASHBOARD_FROM ($DASHBOARD_FROM): http://$LAPTOP_IP:$DASHBOARD_PORT asks for the login (stage 13 keeps every other device out)."; fi)
The approval mode was set by stage 07 (APPROVAL_MODE); the dashboard's Config page shows it. Next: local models (./setup.sh run 09).
MSG
