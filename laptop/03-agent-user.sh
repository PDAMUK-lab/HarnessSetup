#!/usr/bin/env bash
# TITLE: Agent user with passwordless sudo
# RUN-AS: admin
# GUIDE: Step 6
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
stage_begin

cat <<MSG
This creates '$AGENT_USER' with passwordless sudo: the agent gets FULL CONTROL of this laptop,
by design (guide, Phase 2). The limits that remain sit outside the machine: the scoped GitHub token,
protected branches and tags, the OpenRouter credit limit, and your router.
MSG
confirm "Create '$AGENT_USER' with passwordless root?" || die "not confirmed - nothing changed"

sudo_run env DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-container
if id "$AGENT_USER" >/dev/null 2>&1; then
  ok "user $AGENT_USER already exists"
else
  sudo_run adduser --disabled-password --comment "" "$AGENT_USER"
fi
sudo_run loginctl enable-linger "$AGENT_USER"

# Validate the sudoers file BEFORE installing it: a bad file in sudoers.d breaks sudo for everyone.
tmp=$(mktemp)
echo "$AGENT_USER ALL=(ALL:ALL) NOPASSWD: ALL" >"$tmp"
if [[ $DRY_RUN != 1 ]] && ! "${SUDO[@]}" visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; die "generated sudoers line did not parse"; fi
put_file "/etc/sudoers.d/90-$AGENT_USER" 440 <"$tmp"
rm -f "$tmp"

publish_shared

if [[ $DRY_RUN != 1 ]]; then
  if sudo -u "$AGENT_USER" sudo -n true; then ok "ROOT-OK: $AGENT_USER has passwordless sudo"; else die "sudo -n failed for $AGENT_USER"; fi
  if loginctl show-user "$AGENT_USER" -p Linger | grep -q 'Linger=yes'; then ok "Linger=yes"; else die "linger is not enabled"; fi
fi
stage_end
cat <<MSG
Always enter the agent user with:  sudo machinectl shell $AGENT_USER@
(not 'sudo -iu', which has no login session and breaks 'systemctl --user').
Next:  ./setup.sh run 04
MSG
