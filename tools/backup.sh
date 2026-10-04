#!/usr/bin/env bash
# TITLE: Back up the agent's state (Hermes config, memory, sessions, cron jobs, keys) and the kit's settings
# RUN-AS: admin
# GUIDE: extension (backups; restore with tools/restore.sh)
# NEEDS: AGENT_USER ADMIN_USER BACKUP_KEEP BACKUP_TIME
# Usage:  backup.sh             make one now: /var/backups/hermes-node/hermes-node-<date>.tar.gz (the newest BACKUP_KEEP kept)
#         backup.sh --install   also every day at BACKUP_TIME (systemd timer hermes-backup)
#         backup.sh --list      show the backups
# The archives hold the agent's API keys and GitHub token: they are readable by root and the admin user only.
# desktop/windows/Backup-Laptop.ps1 copies the newest one to the desktop, so a copy survives the laptop.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
ACTION=backup
for a in "$@"; do
  case $a in
    --install) ACTION=install ;;
    --list) ACTION=list ;;
    *) common_flag "$a" || die "unknown option: $a   (usage: backup.sh [--install|--list])" ;;
  esac
done
load_config
dir=${HS_BACKUP_DIR:-/var/backups/hermes-node}   # HS_BACKUP_DIR / HS_AGENT_HOME: test seams
home=${HS_AGENT_HOME:-$AGENT_HOME}

if [[ $ACTION == list ]]; then
  sudo_run ls -lht "$dir" 2>/dev/null || warn "no backups yet in $dir"
  exit 0
fi

if [[ $ACTION == install ]]; then
  printf '[Unit]\nDescription=Back up the Hermes agent state (HarnessSetup)\n\n[Service]\nType=oneshot\nEnvironment=NODE_ENV=%s\nExecStart=/bin/bash %s/tools/backup.sh --yes\n' \
    "$NODE_ENV_FILE" "$HS_ROOT" | put_file /etc/systemd/system/hermes-backup.service 644
  printf '[Unit]\nDescription=Daily backup of the Hermes agent state\n\n[Timer]\nOnCalendar=*-*-* %s:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' \
    "$BACKUP_TIME" | put_file /etc/systemd/system/hermes-backup.timer 644
  sudo_run systemctl daemon-reload
  sudo_run systemctl enable --now hermes-backup.timer
  ok "daily backup at $BACKUP_TIME (systemctl list-timers hermes-backup); making the first one now"
fi

[[ -d $home ]] || die "$home does not exist (is AGENT_USER right?)"
ts=$(date +%Y%m%d-%H%M%S)
out=$dir/hermes-node-$ts.tar.gz
n=1
while [[ -e $out ]]; do out=$dir/hermes-node-$ts-$n.tar.gz; n=$((n + 1)); done
items=()
for p in "$home/.hermes" "$home/.config/systemd/user" "$home/.config/gh" "$home/.gitconfig" "$NODE_ENV_FILE"; do
  if sudo_run test -e "$p" 2>/dev/null; then items+=("${p#/}"); fi
done
((${#items[@]})) || die "nothing to back up under $home"
if [[ $DRY_RUN == 1 ]]; then log "[dry-run] would write $out with: ${items[*]}"; exit 0; fi

stage=$(sudo_run mktemp -d)
trap 'sudo_run rm -rf "$stage"' EXIT
# copy without the reinstallable parts (Hermes's own checkout, caches, logs)
# shellcheck disable=SC2016  # $1 and $@ belong to the inner shell
sudo_run bash -c 'tar -C / --exclude="*/.hermes/hermes-agent" --exclude="*/.hermes/cache" --exclude="*/.hermes/logs" \
  -cf - "${@:2}" | tar -C "$1" -xpf -' _ "$stage" "${items[@]}"
# Hermes keeps sessions and memory in SQLite while it runs: replace each copy with a consistent snapshot
sudo_run python3 - "$stage" <<'PY'
import os, sqlite3, sys
stage = sys.argv[1]
for root, _, files in os.walk(stage):
    for f in files:
        if f.endswith(".db"):
            copy = os.path.join(root, f)
            live = "/" + os.path.relpath(copy, stage)
            try:
                src = sqlite3.connect(f"file:{live}?mode=ro", uri=True)
                os.remove(copy)
                dst = sqlite3.connect(copy)
                src.backup(dst)
                dst.close(); src.close()
            except sqlite3.Error as e:
                print(f"warning: {live}: {e} (kept the plain copy)", file=sys.stderr)
            for side in ("-wal", "-shm"):
                if os.path.exists(copy + side):
                    os.remove(copy + side)
PY
sudo_run install -d -m 750 "$dir"
sudo_run tar -C "$stage" -czf "$out.part" .
sudo_run chmod 640 "$out.part"
if [[ -z ${HS_BACKUP_DIR:-} ]]; then sudo_run chown root:"$ADMIN_USER" "$dir" "$out.part"; fi   # the desktop copies it as the admin user
sudo_run mv "$out.part" "$out"
ok "backup: $out ($(sudo_run du -h "$out" | cut -f1))"

# keep the newest BACKUP_KEEP
mapfile -t old < <(sudo_run ls -1t "$dir" | grep -E '^hermes-node-.*\.tar\.gz$' | tail -n +$((BACKUP_KEEP + 1)))
for f in "${old[@]}"; do sudo_run rm -f "$dir/$f"; done
((${#old[@]} == 0)) || log "removed ${#old[@]} older backup(s); keeping $BACKUP_KEEP"
