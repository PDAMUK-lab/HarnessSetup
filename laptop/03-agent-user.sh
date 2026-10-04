#!/usr/bin/env bash
# TITLE: Agent user (passwordless sudo: full, limited or none - setting AGENT_SUDO)
# RUN-AS: admin
# GUIDE: Step 6
# NEEDS: AGENT_USER AGENT_SUDO ADMIN_USER
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
stage_begin

mode=${AGENT_SUDO:-full}
sudoers=/etc/sudoers.d/90-$AGENT_USER
desktop_rule=/etc/sudoers.d/91-hermes-desktop
case $mode in
  full)
    cat <<MSG
This creates '$AGENT_USER' with passwordless sudo: the agent gets FULL CONTROL of this laptop,
by design (guide, Phase 2). The limits that remain sit outside the machine: the scoped GitHub token,
protected branches and tags, the OpenRouter credit limit, and your router.
MSG
    confirm "Create '$AGENT_USER' with passwordless root?" || die "not confirmed - nothing changed" ;;
  limited)
    cat <<MSG
This creates '$AGENT_USER' with passwordless sudo for apt, apt-get, systemctl and journalctl only (AGENT_SUDO=limited).
That prevents accidents, not a determined agent: a package install runs scripts as root.
MSG
    confirm "Create '$AGENT_USER' with limited sudo?" || die "not confirmed - nothing changed" ;;
  none) echo "This creates '$AGENT_USER' without sudo (AGENT_SUDO=none): it cannot install packages or manage services." >&2 ;;
  *) die "AGENT_SUDO must be full, limited or none (got '$mode')" ;;
esac

sudo_run env DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-container
if id "$AGENT_USER" >/dev/null 2>&1; then
  ok "user $AGENT_USER already exists"
else
  sudo_run adduser --disabled-password --comment "" "$AGENT_USER"
fi
sudo_run loginctl enable-linger "$AGENT_USER"

if [[ $mode == none ]]; then
  sudo_run rm -f "$sudoers"
else
  # Validate the sudoers file BEFORE installing it: a bad file in sudoers.d breaks sudo for everyone.
  tmp=$(mktemp)
  if [[ $mode == full ]]; then
    echo "$AGENT_USER ALL=(ALL:ALL) NOPASSWD: ALL" >"$tmp"
  else
    echo "$AGENT_USER ALL=(root) NOPASSWD: /usr/bin/apt, /usr/bin/apt-get, /usr/bin/systemctl, /usr/bin/journalctl" >"$tmp"
  fi
  if [[ $DRY_RUN != 1 ]] && ! "${SUDO[@]}" visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; die "generated sudoers line did not parse"; fi
  put_file "$sudoers" 440 <"$tmp"
  rm -f "$tmp"
fi
# The desktop's Desktop-Mode.ps1 / Auto-Away.ps1 log in as the admin user and run hermes-desktop as the agent: allow
# exactly that without a password, so an automatic away needs nobody at the keyboard. (It runs as the agent, not root.)
tmp=$(mktemp)
echo "$ADMIN_USER ALL=($AGENT_USER) NOPASSWD: $AGENT_HOME/.local/bin/hermes-desktop" >"$tmp"
if [[ $DRY_RUN != 1 ]] && ! "${SUDO[@]}" visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; die "generated sudoers line did not parse"; fi
put_file "$desktop_rule" 440 <"$tmp"
rm -f "$tmp"

publish_shared

if [[ $DRY_RUN != 1 ]]; then
  case $mode in
    full) if sudo -u "$AGENT_USER" sudo -n true; then ok "ROOT-OK: $AGENT_USER has passwordless sudo"; else die "sudo -n failed for $AGENT_USER"; fi ;;
    limited)
      if sudo -u "$AGENT_USER" sudo -n true 2>/dev/null; then die "$AGENT_USER still has full sudo (another file in /etc/sudoers.d?)"; fi
      if sudo -u "$AGENT_USER" sudo -n -l /usr/bin/apt-get >/dev/null 2>&1; then ok "$AGENT_USER may run apt, apt-get, systemctl and journalctl as root"; else die "limited sudo is not in effect for $AGENT_USER"; fi ;;
    none) if sudo -u "$AGENT_USER" sudo -n true 2>/dev/null; then die "$AGENT_USER still has sudo (another file in /etc/sudoers.d, or the sudo group?)"; else ok "$AGENT_USER has no sudo"; fi ;;
  esac
  linger=$(loginctl show-user "$AGENT_USER" -p Linger || true)
  if [[ $linger == 'Linger=yes' ]]; then ok "Linger=yes"; else die "linger is not enabled"; fi
fi
stage_end
cat <<MSG
Always enter the agent user with:  sudo machinectl shell $AGENT_USER@
(not 'sudo -iu', which has no login session and breaks 'systemctl --user').
Next:  ./setup.sh run 04
MSG
