#!/usr/bin/env bash
# TITLE: Firewall and file permissions
# RUN-AS: admin
# GUIDE: Step 28
# NEEDS: ROUTER_IP LAN_CIDR DESKTOP_IP SSH_ALLOWED_FROM LLM_PORT V100_ENABLED V100_PORT DASHBOARD_FROM DASHBOARD_PORT SMB_SHARE
# Options: --force (apply even if this SSH session does not come from SSH_ALLOWED_FROM)
# NOTE: the agent has root, so it can change these rules. They guard against mistakes, not against the agent.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
FORCE=0
for a in "$@"; do
  case $a in
    --force) FORCE=1 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
stage_begin
require_vars ROUTER_IP LAN_CIDR SSH_ALLOWED_FROM
need_cmd ufw

# ---- lock-out guards
client=${SSH_CLIENT:-}
client=${client%% *}
if [[ -n $client && $client != "$SSH_ALLOWED_FROM" && $FORCE == 0 ]]; then
  fail_or_warn "you are connected over SSH from $client, but the firewall will only allow SSH from $SSH_ALLOWED_FROM (this would cut you off). Reconnect from there, or pass --force."
fi
dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | head -1 || true)
case ${dns:-} in
  '' | 127.* | "$ROUTER_IP") ;;
  *) warn "DNS server is $dns but the firewall only allows DNS to the router ($ROUTER_IP). Point /etc/resolv.conf (or DHCP) at the router, or name resolution will stop."
     confirm "Apply anyway?" || die "not applied" ;;
esac

echo "Current rules (--force reset deletes all of them):"
"${SUDO[@]}" ufw status numbered 2>/dev/null || true
confirm "Reset ufw and apply the guide's rule set?" || die "not confirmed - nothing changed"

# Order matters: the allow rules for DNS, NTP and the desktop come before the LAN deny.
sudo_run ufw --force reset
sudo_run ufw default deny incoming
sudo_run ufw default deny outgoing
sudo_run ufw allow in from "$SSH_ALLOWED_FROM" to any port 22 proto tcp comment 'SSH from desktop'
sudo_run ufw allow out to "$ROUTER_IP" port 53 comment 'DNS'
sudo_run ufw allow out 123/udp comment 'NTP'
sudo_run ufw allow out 67/udp comment 'DHCP renewals'
sudo_run ufw allow out to "$DESKTOP_IP" port "$LLM_PORT" proto tcp comment 'desktop model'
if [[ ${V100_ENABLED:-0} == 1 ]]; then
  sudo_run ufw allow out to "$DESKTOP_IP" port "$V100_PORT" proto tcp comment 'desktop V100 model'
fi
if [[ ${DASHBOARD_FROM:-none} != none ]]; then
  IFS=',' read -ra devs <<<"$DASHBOARD_FROM"
  for d in "${devs[@]}"; do sudo_run ufw allow in from "$d" to any port "$DASHBOARD_PORT" proto tcp comment 'dashboard from a browser'; done
fi
if [[ ${SMB_SHARE:-none} != none ]]; then
  smb_host=${SMB_SHARE#//}; smb_host=${smb_host%%/*}
  smb_ip=$(getent ahostsv4 "$smb_host" 2>/dev/null | awk 'NR == 1 {print $1}' || true)   # ufw takes addresses only
  if [[ -n $smb_ip ]]; then sudo_run ufw allow out to "$smb_ip" port 445 proto tcp comment 'SMB share for finished work'
  else warn "cannot resolve $smb_host: no firewall rule for the SMB share (use its IP address in SMB_SHARE)"; fi
fi
sudo_run ufw deny out to "$LAN_CIDR" comment 'nothing else on the LAN'
sudo_run ufw allow out 80/tcp
sudo_run ufw allow out 443/tcp
sudo_run ufw --force enable
sudo_run ufw status numbered

for f in "$AGENT_HOME/.hermes/.env" "$AGENT_HOME/.hermes/profiles/local/.env"; do
  if [[ -f $f || $DRY_RUN == 1 ]]; then sudo_run chmod 600 "$f"; fi
done

if [[ $DRY_RUN != 1 ]]; then
  log "checking the result"
  c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://openrouter.ai/api/v1/models || true)
  if [[ $c == 200 ]]; then ok "openrouter reachable (200)"; else warn "openrouter returned '$c'"; fi
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$DESKTOP_IP:$LLM_PORT/health" || true)
  if [[ $c == 200 || $c == 401 ]]; then ok "desktop model port answers ($c)"; else warn "desktop model returned '$c' (is the desktop on?)"; fi
  if [[ ${V100_ENABLED:-0} == 1 ]]; then
    c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$DESKTOP_IP:$V100_PORT/health" || true)
    if [[ $c == 200 || $c == 401 ]]; then ok "desktop V100 model port answers ($c)"; else warn "desktop V100 model returned '$c' (is the desktop on, and the V100 server started?)"; fi
  fi
  if timeout 3 bash -c "(exec 3<>/dev/tcp/$DESKTOP_IP/445)" 2>/dev/null; then
    warn "desktop port 445 is REACHABLE - the LAN deny rule is not working"
  else
    ok "desktop port 445 BLOCKED"
  fi
  if getent hosts deb.debian.org >/dev/null; then ok "DNS resolves"; else warn "DNS does not resolve"; fi
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  if [[ $ntp == yes ]]; then ok "NTP synchronized"; else warn "NTP not synchronized yet ($ntp)"; fi
fi
stage_end
cat <<MSG
Know the limits: with root the agent can change this firewall. For a boundary it cannot remove, put the
laptop on your router's guest network or its own VLAN with only the desktop allowed through.
Next: ./setup.sh tool verify   and   ./setup.sh tool fallback-test
MSG
