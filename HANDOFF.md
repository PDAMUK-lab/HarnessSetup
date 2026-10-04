# Handoff notes for the next agent

State on 2026-10-04, branch `claude/confident-bohr-xju95x`. `main` is the released v0.5.0 (merge 49c5095); keep it releasable.

## Unfinished: needs testing, docs, then a PR

The WIP commit 00570ae is **untested**. The last test run had 4 failures; fixes for all four are in the commit but were not re-run.

1. **Dashboard from browsers on the LAN (phones, other laptops).** The user wants phone access by **browser**, not SSH apps.
   - Setting `DASHBOARD_FROM` (type `iplist`, default `none`). When it is not `none`:
     - `lib/common.sh` sets `DASHBOARD_BIND=0.0.0.0`, which `templates/systemd/hermes-dashboard.service.tpl` uses (otherwise it stays 127.0.0.1).
     - Stage 08 runs `tools/dashboard-login.sh` when there is no `dashboard.basic_auth`.
     - Stage 13 admits only the listed devices to `DASHBOARD_PORT`.
   - Hermes refuses a non-loopback bind without auth (`hermes_cli/web_server.py` `should_require_auth`). Its basic-auth plugin takes `dashboard.basic_auth.{username,password_hash,secret}`. The hash format is `scrypt$16384$8$1$<salt_b64>$<dk_b64>` (`plugins/dashboard_auth/basic`).
   - To do:
     - Note in the RUNBOOK and README that the login goes over plain HTTP on the LAN.
     - `verify` should check the bind and `auth_required` when `DASHBOARD_FROM` is set.
2. **SMB share for finished work.**
   - Setting `SMB_SHARE` (type `smbpath`, `none` or `//host/share[/dir]`).
   - `tools/smb-share.sh`:
     - asks for the share's user and password (into `/etc/hermes-smb.cred`, mode 600);
     - mounts the share at `/srv/share` with a systemd mount unit and an automount unit (uid/gid of the agent);
     - adds the firewall rule if ufw is already active.
   - Stage 13 resolves the host (ufw takes IP addresses only) and allows port 445 before the LAN deny.
   - To do:
     - docs (RUNBOOK and README);
     - tell the agent where finished work goes (for example a line in the `local` profile or in AGENTS.md).
3. **Offline mode: not started.** The user may work entirely offline, so no GitHub and no OpenRouter, with finished work saved to the SMB share. A sketch:
   - a setting `OFFLINE=1`;
   - `setup.sh next`/`list` skip stages 05, 07 and 12;
   - schema `WHEN` conditions hide the GitHub and OpenRouter settings. `WHEN` supports only `KEY=value`;
   - stage 11 makes the `local` profile the default (`hermes-mode local`);
   - stage 13 stops allowing 80/443 out;
   - `verify` skips the cloud checks.
   - First check whether stage 11 depends on stage 07 (the `local` profile is cloned from the default profile).
   - Setup itself still needs internet once: apt, Hermes, models.

## How to verify (what the user expects at every step)

```bash
SP=<scratchpad>; export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 SHELLCHECK=<shellcheck 0.9+> PWSH=<pwsh 7> STRICT=1
bash tests/run-tests.sh </dev/null > $SP/full.log 2>&1; grep -E '^FAIL:|ALL TESTS|TESTS FAILED' $SP/full.log
```

- **Expected output:** the line `FAIL   #9   laptop answers with a tool call` in `test-tools` is expected output from the verify tests. It is not a failure.
- **Run as root here, CI as a normal user:** this container runs as root, but CI runs as a normal user, and some failures only show up there (the backup/restore bug did). Check CI on the PR before merging.
- **Never extract a test archive over `/`:** a restore test with an archive that holds `./` changed `/` and `/tmp` modes here. That is fixed in `backup.sh` and `restore.sh`. If `/` is ever left at mode 700 or `/tmp` loses its sticky bit, run `chmod 755 /; chmod 1777 /tmp`.
- **Releasing:** a release happens when a new `VERSION` lands on `main` (`.github/workflows/release.yml`). Merge with a merge commit.

## User's working rules

- Develop step by step, and run the full suite, then commit and push, after each step.
- Keep messages to the user short. The user's usage limits are tight: avoid sub-agents and workflows unless asked.
- Do not create a PR or merge unless asked ("build and release" means: PR, green CI, merge).
- Untested on real hardware: the Windows scripts are only tested by dry runs under pwsh on Linux.
