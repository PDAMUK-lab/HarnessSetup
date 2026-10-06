#!/usr/bin/env bash
# TITLE: Mount a network (SMB) share for the agent's finished work at /srv/share
# RUN-AS: admin
# GUIDE: extension (finished work on a NAS or Windows share, also when working offline)
# NEEDS: SMB_SHARE AGENT_USER
# Usage:  smb-share.sh   asks for the share's user name and password (kept in /etc/hermes-smb.cred, root only), mounts
#         SMB_SHARE at /srv/share on first use (systemd automount, owned by the agent) and checks the agent can write there.
#         The firewall (stage 13) lets the laptop reach the share; this also adds that rule when the firewall is already on.
#         Then tell the agent where finished work goes, e.g. "save the result to /srv/share/<project>/".
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
[[ ${SMB_SHARE:-none} != none ]] || die "SMB_SHARE is none: set it first (./setup.sh configure --only SMB_SHARE)"
where=/srv/share cred=/etc/hermes-smb.cred
host=${SMB_SHARE#//}; host=${host%%/*}

smb_user='' smb_pw=''
read -rp "User name for $SMB_SHARE (DOMAIN\\user is fine): " smb_user || true
[[ -n $smb_user && $smb_user != *[$'\n'=]* ]] || die "a user name is needed"
read -rsp "Password: " smb_pw || true; echo >&2

sudo_run env DEBIAN_FRONTEND=noninteractive apt-get install -y cifs-utils
dom=''
if [[ $smb_user == *\\* ]]; then dom=${smb_user%%\\*}; smb_user=${smb_user#*\\}; fi
{
  printf 'username=%s\npassword=%s\n' "$smb_user" "$smb_pw"
  if [[ -n $dom ]]; then printf 'domain=%s\n' "$dom"; fi
} | put_file "$cred" 600
uid=$(id -u "$AGENT_USER" 2>/dev/null || echo 1001) gid=$(id -g "$AGENT_USER" 2>/dev/null || echo 1001)
printf '[Unit]\nDescription=Network share for the agent'"'"'s finished work (HarnessSetup)\nAfter=network-online.target\nWants=network-online.target\n\n[Mount]\nWhat=%s\nWhere=%s\nType=cifs\nOptions=credentials=%s,uid=%s,gid=%s,file_mode=0640,dir_mode=0750,vers=3.0,_netdev,nofail\nTimeoutSec=30\n' \
  "$SMB_SHARE" "$where" "$cred" "$uid" "$gid" | put_file /etc/systemd/system/srv-share.mount 644
printf '[Unit]\nDescription=Mount the network share on first use\n\n[Automount]\nWhere=%s\nTimeoutIdleSec=600\n\n[Install]\nWantedBy=multi-user.target\n' \
  "$where" | put_file /etc/systemd/system/srv-share.automount 644
sudo_run install -d -m 755 "$where"
# a firewall that is already on denies the LAN: let the laptop reach the share (stage 13 writes the same rule)
if [[ $DRY_RUN != 1 ]] && "${SUDO[@]}" ufw status 2>/dev/null | grep -q '^Status: active'; then
  ip=$(getent ahostsv4 "$host" | awk 'NR == 1 {print $1}' || true)
  if [[ -n $ip ]]; then sudo_run ufw insert 1 allow out to "$ip" port 445 proto tcp comment 'SMB share for finished work'
  else warn "cannot resolve $host: add a firewall rule by hand, or use its IP address in SMB_SHARE"; fi
fi
sudo_run systemctl daemon-reload
sudo_run systemctl enable --now srv-share.automount
[[ $DRY_RUN == 1 ]] && exit 0
if agent_exec "touch $where/.hermes-write-test && rm -f $where/.hermes-write-test" >/dev/null 2>&1; then
  ok "$SMB_SHARE is mounted at $where and $AGENT_USER can write there"
else
  die "$AGENT_USER cannot write to $where: check the share's user and password (run this again), and journalctl -u srv-share.mount"
fi
echo "Tell the agent where finished work goes, e.g.: \"save the result to $where/<project>/\"" >&2
