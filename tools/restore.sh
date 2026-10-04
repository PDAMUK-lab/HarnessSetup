#!/usr/bin/env bash
# TITLE: Restore the agent's state from a backup made by tools/backup.sh
# RUN-AS: admin
# GUIDE: extension (backups)
# NEEDS: AGENT_USER
# Usage:  restore.sh /var/backups/hermes-node/hermes-node-<date>.tar.gz   (asks first; --yes skips the question)
# Stops the gateway and dashboard, keeps the current ~/.hermes as ~/.hermes.before-restore-<date>, unpacks the backup,
# and starts the services again. The kit's settings file from the backup is saved beside the current one
# (node.env.from-backup-<date>) instead of replacing it.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
FILE=''
for a in "$@"; do
  case $a in
    -*) common_flag "$a" || die "unknown option: $a" ;;
    *) FILE=$a ;;
  esac
done
load_config
home=${HS_AGENT_HOME:-$AGENT_HOME}   # test seam
[[ -n $FILE ]] || die "usage: restore.sh FILE.tar.gz   (./setup.sh tool backup --list shows them)"
sudo_run test -r "$FILE" || die "cannot read $FILE"
sudo_run tar -tzf "$FILE" >/dev/null || die "$FILE is not a readable .tar.gz"
echo "This backup holds:" >&2
sudo_run tar -tzf "$FILE" | sed 's|^\./||' | cut -d/ -f1-5 | sort -u | grep -v '^$' | head -20 | sed 's/^/  \//' >&2
confirm "Stop Hermes's services and restore it over the current state (kept as ~/.hermes.before-restore-*)?" || die "not confirmed - nothing changed"
[[ $DRY_RUN == 1 ]] && { log "[dry-run] would stop the services, move ~/.hermes aside, unpack $FILE to /, start the services"; exit 0; }

ts=$(date +%Y%m%d-%H%M%S)
agent_exec "systemctl --user stop hermes-dashboard 'hermes-gateway*'" >/dev/null 2>&1 || true
if sudo_run test -e "$home/.hermes"; then sudo_run mv "$home/.hermes" "$home/.hermes.before-restore-$ts"; fi
settings=./${NODE_ENV_FILE#/}
sudo_run tar -C / -xzpf "$FILE" --exclude="$settings"
if sudo_run tar -tzf "$FILE" "$settings" >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # $1..$3 belong to the inner shell
  sudo_run bash -c 'tar -C / -xzOf "$1" "$2" >"$3"' _ "$FILE" "$settings" "$NODE_ENV_FILE.from-backup-$ts"
  log "the backed-up settings are in $NODE_ENV_FILE.from-backup-$ts (the current settings were kept)"
fi
agent_exec "systemctl --user daemon-reload; systemctl --user start hermes-dashboard 'hermes-gateway*'" >/dev/null 2>&1 ||
  warn "start the services by hand: sudo machinectl shell $AGENT_USER@  then  systemctl --user start hermes-dashboard; hermes gateway status"
ok "restored $FILE (the previous state is in $home/.hermes.before-restore-$ts)"
echo "Check it:  ./setup.sh tool verify" >&2
