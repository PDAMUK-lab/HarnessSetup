---
name: health
description: One-page health check of this AI node - Hermes and its profiles, the fallback chain, the local model servers, GPU memory, disk, the firewall, scheduled jobs and OpenRouter credit. Use after a model test, an update, a reboot, or when anything behaves oddly.
---
# Node health

Run each check, keep going when one fails, and finish with one table: check, result, OK/WARN/FAIL, and the fix for
anything not OK. Read-only: never restart, reinstall or reconfigure anything in this skill; propose the command.

1. Hermes: `hermes doctor`, then `hermes -p local doctor` (and `hermes -p mixed doctor` if `hermes profile list`
   shows mixed). Any error is FAIL.
2. Mode and endpoints: `hermes-mode status` (laptop 200, desktop 200 unless it is away or off, OpenRouter 200 unless
   OFFLINE). Each line also shows the model the server really serves: a wrong alias is FAIL.
3. Desktop in or out of the loop: `hermes-desktop status`. Out is WARN, with the time it comes back if one is set.
4. Fallback chain: `hermes fallback list` (OpenRouter, then the local endpoints in that order).
5. Services: `systemctl is-active llama-server` (the laptop model), `systemctl --user is-active hermes-dashboard`,
   `hermes gateway status`.
6. Scheduled jobs: `hermes cron status` and `hermes cron doctor` (exits 0), plus `hermes -p local cron status`.
   A job whose last run failed is WARN; name it and offer /audit on that run.
7. GPU: `nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv`. Memory near the total
   with nothing running is WARN (a stuck process; `nvidia-smi` lists it).
8. Disk: `df -h / /srv`. Under 15% free is WARN, under 5% FAIL (models and sessions fill it).
9. Memory: `free -h`; swap heavily used while idle is WARN.
10. Firewall: `sudo ufw status verbose` - active, default deny outgoing, and a `deny out` rule for the LAN.
    Inactive is FAIL.
11. Credit: `bash /opt/harness-setup/tools/spend.sh` (skip when OFFLINE=1).
12. Backups: `ls -t /var/backups/hermes-node | head -3` - the newest should be from today or yesterday.

End with the full kit checklist for the user to run as the admin user when anything failed:
`./setup.sh tool verify`.
