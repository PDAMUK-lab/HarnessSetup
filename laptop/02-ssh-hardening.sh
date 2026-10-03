#!/usr/bin/env bash
# TITLE: Key-only SSH (disable passwords and root login)
# RUN-AS: admin
# GUIDE: Step 5
# Run this only AFTER you have logged in from the desktop with the key (Setup-LaptopAccess.ps1).
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
stage_begin

keys=$HOME/.ssh/authorized_keys
if [[ ! -s $keys ]]; then
  fail_or_warn "$keys is empty. Run desktop/windows/Setup-LaptopAccess.ps1 first, or you would lock yourself out."
fi
grep -qsE '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config ||
  fail_or_warn "/etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf', so the drop-in would be ignored"

echo "About to turn off SSH password logins and root login."
echo "Keep your current SSH session open, and confirm a NEW PowerShell window logs in with the key and no password."
confirm "Has a fresh key-only login from the desktop worked?" || die "not confirmed - nothing changed"

printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' |
  put_file /etc/ssh/sshd_config.d/10-hardening.conf 644
if [[ $DRY_RUN != 1 ]]; then
  "${SUDO[@]}" sshd -t || { "${SUDO[@]}" rm -f /etc/ssh/sshd_config.d/10-hardening.conf; die "sshd rejected the config; the drop-in was removed"; }
fi
sudo_run systemctl reload ssh

if [[ $DRY_RUN != 1 ]]; then
  eff=$("${SUDO[@]}" sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) ')
  echo "$eff"
  grep -qi '^passwordauthentication no' <<<"$eff" || die "password authentication is still enabled - another file in sshd_config.d wins"
fi
stage_end
echo "Verify: open a NEW PowerShell window: ssh $ADMIN_USER@$LAPTOP_IP  (no password prompt). Then:  ./setup.sh run 03"
