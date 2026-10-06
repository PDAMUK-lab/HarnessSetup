# Changelog

## 0.6.1

Fixes found while making 0.6.0's changes apply to existing nodes, and the documents to match.

- **Stage 08 on an existing node.** Re-running it (how `DASHBOARD_FROM` and a dashboard login are applied) only
  rewrote the unit file: `enable --now` leaves a running service alone, so the dashboard kept its old bind, and the
  stage's checks then failed against the stale process. It now restarts the dashboard — the pattern stage 10 uses for
  llama-server — so a changed bind, a new login and a switch back to `none` all take effect on a re-run.
- **`verify` on an offline node.** Check 10 expected "OpenRouter, then desktop, then laptop", so with `OFFLINE=1`
  (whose chain is the local endpoints only, by design) it failed and `./setup.sh tool verify` exited 1. It now expects
  the local endpoints only when offline, and points at `./setup.sh run 11` when the chain still has an OpenRouter entry.
- **Docs.** The README gains an upgrade note and links its offline section to the runbook, and lists the new modes
  under "What this kit could not verify"; the RUNBOOK gains "11b. Working offline (no internet)" and an upkeep bullet
  for upgrading the kit or finishing a half-installed node; the CHECKLIST's dashboard, fallback, hermes-mode and
  firewall rows carry their offline expectations, and its Extras table gains the browser-access, SMB-share and offline
  checks.

Upgrading from 0.6.0: `git pull` — nothing needs re-running; stage 08's fix applies the next time you run it, and
`verify` is the fixed tool itself.

## 0.6.0

Browser access, a share for finished work, and an offline mode.

- **The dashboard from a phone or another laptop.** `DASHBOARD_FROM` (type `iplist`, default `none`) lists the devices
  whose browsers may reach the dashboard. When set, stage 08 binds the dashboard to the LAN behind Hermes's own login
  (setting one with `./setup.sh tool dashboard-login` when there is none) and stage 13 admits only those devices;
  `verify`'s check 6 then checks the login and the LAN bind instead of loopback-only. `none` keeps the loopback-only
  behaviour, reached from the desktop through the SSH tunnel.
- **Finished work on a network share.** `SMB_SHARE` (type `smbpath`, default `none`) is a share like
  `//192.168.1.20/work`. `./setup.sh tool smb-share` mounts it at `/srv/share` for the agent (systemd automount,
  credentials root-only) and lets the laptop reach port 445; stage 11 tells the agent itself, through Hermes's
  `agent.coding_instructions`, to save finished results to `/srv/share/<project>/`; `verify` writes a test file there
  (a warning, not a failure, when the NAS is off).
- **Working offline.** `OFFLINE` (basic, default no): the node still needs the internet once to install, then runs with
  none. Stages 05 (GitHub), 07 (OpenRouter) and 12 (cron/release) are marked `# ONLINE: yes`; with `OFFLINE=1` the
  dispatcher skips them in `next`, marks them `[skipped: offline]` in `list` and refuses to run them, the wizard hides
  their settings, the fallback chain keeps no OpenRouter entry and the node ends in the local profile, stage 13 keeps
  80/443 closed, and `verify` skips the cloud checks (said once). See the README's "Working offline".
- **Fixes.** `Install-Llama.ps1` searches up to 200 llama.cpp releases (following the API's pagination) so a run of
  newer releases without a Windows build cannot hide the newest usable one, and takes a by-hand `-ZipUrl`;
  `Common.ps1`'s `iplist` validator parses again (a braced loop body); the SMB firewall rule takes an address
  `SMB_SHARE` host as it is instead of resolving it; stage 08 restarts the dashboard on a re-run, so `DASHBOARD_FROM`'s
  LAN bind and the login apply on a node that already had the dashboard running; `verify`'s fallback-chain check expects
  the local endpoints only when `OFFLINE=1`, instead of failing the run.

Upgrading from 0.5.0: run `./setup.sh configure` (the new settings get their defaults), then re-run stages 08, 11 and 13.
A node that stays online is unchanged otherwise. Finishing a node that is still half-installed with 0.5.0: re-run stage 08
if it had already completed (the dashboard changes live there), then continue with `./setup.sh next` — the stages you have
not reached yet run with the new code.

## 0.5.0

Guard rails, backups and upkeep.

- **Guard rails.** `AGENT_SUDO=full|limited|none` (stage 03, checked by `verify`): full is the guide's passwordless root,
  limited allows apt, apt-get, systemctl and journalctl only, none removes sudo. `APPROVAL_DENY` (on by default) writes
  Hermes's `approvals.deny` list for both profiles: deleting or archiving a repo, wiping a disk, removing the agent's state
  or its clones and turning the firewall off are refused even with approvals off.
- **Backups.** `tools/backup.sh` saves the agent's state (Hermes config, memory, sessions with consistent SQLite snapshots,
  cron jobs, keys, user services, GitHub login) and the kit's settings; `--install` runs it daily at `BACKUP_TIME` and keeps
  `BACKUP_KEEP`. `tools/restore.sh` puts one back (the current state is kept aside). `Backup-Laptop.ps1 -Register` copies the
  newest one to the desktop every day.
- **Spend check.** `tools/spend.sh` and `verify` read the OpenRouter key's limit and usage: a warning without a limit, with
  a limit that does not reset monthly, or at `SPEND_WARN_PCT` of it; a failure when it is used up.
- **Model test set.** `tools/model-test.sh` runs your own tasks (`config/model-tests.example`) against a profile, provider
  or model in throw-away worktrees, checks each with your command and appends to `~/model-tests/results.csv`.
- **llama.cpp updates with an undo.** `tools/update-llama.sh` and `Update-Llama.ps1` keep the current build, install the
  newest, test health, model name and a tool call, and put the old build back when that fails (`--rollback` / `-Rollback`
  by hand). `Compare-LlamaBackends.ps1` benchmarks llama.cpp's ROCm build (`win-rocm-10.0`, compiled for gfx1032)
  against the Vulkan build on the desktop's card, each pinned to the card (C:\llama untouched; the advice is to switch only
  for 10% at every depth), and `Update-Llama.ps1 -Backend rocm|vulkan` switches. The ROCm zip lacks hipBLAS/rocBLAS: both
  scripts check for them on PATH and say how to install AMD's ROCm 10 libraries, and a switch that does not list the card
  as a GPU is undone (it would otherwise run on the CPU). The build installer clears old binaries first, so two backends'
  DLLs never load together.
- **Automatic desktop away.** `Auto-Away.ps1 -Register` watches the GPU use of other programs and runs
  `Desktop-Mode.ps1 away` / `back` by itself (`AUTO_AWAY_GPU_PCT`, `AUTO_AWAY_AFTER_MIN`, `AUTO_BACK_AFTER_MIN`); a manual
  away is left alone. Stage 03 lets the admin user run `hermes-desktop` as the agent without a password, so telling the
  laptop needs nobody at the keyboard (re-run stage 03 on an existing laptop).
- **Sub-agent reasoning effort.** `WORKER_EFFORT` sets `delegation.reasoning_effort` (default `inherit`).
- **Log size.** Stage 01 caps the systemd journal at `JOURNAL_MAX_MB` (default 500MB), keeps 2GB free and a month at most.

Upgrading from 0.4.0: run `./setup.sh configure` (the new settings get their defaults), then re-run stages 01, 03, 07 and 11.

## 0.4.0

Other models, sub-agents that survive an outage, and a release workflow.

- **Any model family per slot.** The chat-template switches and sampling were hard-coded for Qwen. They are now
  settings per slot (`LAPTOP_/DESKTOP_/NIGHT_/V100_CHAT_KWARGS` as `key=value` pairs, `*_SAMPLING` as allow-listed
  llama-server flags, `auto`/`none`), plus `NIGHT_MTP` for models without an MTP head; validated alike in bash and
  PowerShell. `NIGHT_NGL` now defaults to 16 (the guide's value).
- **[docs/MODELS.md](docs/MODELS.md):** other model families per slot (Ornith 1.5, MiMo distill, Gemma 4, Granite 4.2,
  Mellum2, Laguna XS/S, North Mini Code, Muse Glimmer) and uncensored drop-ins, every file checked on Hugging Face and
  every architecture in llama.cpp; an assessment of RAM/SSD offload engines (keep llama.cpp; a ROCm A/B is worth a try);
  how the agent's sub-agents are set up.
- **Sub-agents** (checked against Hermes's source): a sub-agent pinned to a provider got no fallback, so an OpenRouter
  outage failed every sub-agent while the planner fell back; `lib/chain.sh` now writes `delegation.fallback_providers`
  for both profiles. The approval mode was a manual dashboard step, and under Hermes's default sub-agents and cron jobs
  refuse risky commands; it is now the setting `APPROVAL_MODE` (default `off`), applied to both profiles by stages 07 and 11
  and checked by `verify`. A sub-agent with no progress for 30 minutes is stopped. Stage 11 also keeps the already-cloned
  `local` profile's endpoints (aliases, context sizes) current.
- **Guide findings applied:** the GitHub smoke test also proves that the agent cannot merge its own PR without your
  approval; `hermes-mode status` shows which model each endpoint actually serves; the laptop's CUDA build compiles the
  FlashAttention kernel for its f16/q8_0 context cache.
- `Configure.ps1 -Set` keeps commas inside a switch list; the desktop installers validate the new settings before
  writing start scripts, and `Install-Overnight.ps1` leaves MTP off for a model without an MTP head.
- The smoke test tags its own throw-away commit (closing the PR switched the clone back to `main`, so a release
  workflow would have published the smoke tag) and accepts the refused merge only when GitHub says an approval is missing.
- **Releases:** `.github/workflows/release.yml` tags and publishes a release (notes from this file, `.tar.gz`/`.zip`
  of the kit, checksums) when a new `VERSION` lands on `main`.

## 0.3.1

The guide was checked line by line against the real tools; the guide and the kit were corrected where they disagreed.

- **Lid and sleep first.** Ignoring the lid and masking sleep moved from Step 4 to Step 1 (stage 01 does it before any `apt` run), so a
  closed lid can no longer kill SSH during the upgrade or the driver build.
- **Root password.** The guide now says that an empty root password locks root: `su` fails, use `sudo -i` (and what to do if you
  want a root password instead).
- **Fixes in the kit:** zram swap is switched on (`systemctl start /dev/zram0`; the setup service only creates the device); stage 01
  warns about a 6.16+ (backports) kernel, which the 550 module does not build on; the Vulkan fallback installs `spirv-headers`; stage 09
  checks the GPU with `--list-devices` (`--version` never lists it); the Hermes installer runs with `--skip-setup`; the release watcher
  searches `Release in:title` and accepts only `Release vX.Y.Z` titles; the release skill polls the run instead of `gh run watch`; the
  release workflow refuses a tag that is not on `main`; `actions/checkout@v7`; the overnight swap tasks run elevated like the day
  server, and the PC stays awake after a timer wake; the overnight 27B uses `reasoning_effort` `medium` (`high` is an alias of the
  default); the dashboard tunnel script pauses on error.
- **Guide corrections:** the dkms module is `nvidia-current`; Debian's 550 driver is end-of-life; GitHub ruleset setup (organisation
  member, Active enforcement, required approvals, private-repo plan); direct pushes go through a PR; sudoers is validated before it is
  installed; `hermes config set` instead of pasted YAML; `hermes -p local` instead of the shadowed `local`; model downloads with `curl -f`
  and a GGUF check; a crypto-random API key; scheduled-task time limit removed; firewall lock-out guard; and more (see the git log).

## 0.3.0

Two additions, both optional, and a fix.

- **Desktop away.** `hermes-desktop on|off|status [--for 4h]` on the laptop and `Desktop-Mode.ps1 away|back|status [-For 4h]` on the
  desktop take every desktop model out of Hermes's loop (fallback chain and `local` profile) and stop the desktop's servers so the
  GPU and memory are free, then put everything back. `lib/chain.sh` now writes the order of the local endpoints in one place.
- **Optional V100 tier** (two Tesla V100 SXM2 on PCIe adapters, added later): `V100_*` settings, `Check-V100.ps1` (read-only
  readiness check), `Install-V100.ps1` (driver check, TCC mode, CUDA 12 llama.cpp in its own folder, memory-fit estimate before the
  download, MTP, start script, firewall, task, smoke test), `tools/v100-laptop.sh`, a laptop firewall rule, `verify` checks and
  [docs/V100.md](docs/V100.md). Dormant while `V100_ENABLED=0`.
- **Fix:** `Install-Llama.ps1` looked for the Vulkan zip in GitHub's "latest" release, which is now a source-only tag, so it could
  not find a build. It picks the newest release that has the zip. The overnight swap stops the server by folder, not by program name.

## 0.2.0

Settings and options are asked for instead of edited or guessed.

- `config/settings.schema` describes every setting once (prompt, explanation, type, default, who asks); bash and
  PowerShell both read it. `./setup.sh configure` / `Configure.ps1` run the wizard (`--advanced`, `--only`,
  `--set`, `--defaults`, `--print`), with validation, detected defaults and derived defaults (the quantization
  chooses the model file and URL).
- Any stage or tool starts the wizard when no settings exist, and asks just-in-time for the settings its
  `# NEEDS:` header lists. The Windows installers do the same and can import the laptop's settings over SSH.
- Stage options are asked when no flag was given (NVIDIA, Docker, CUDA or Vulkan, benchmark, start, release
  watcher, fallback-test sleep step, verify's model tests, overnight task, which repo, adopt-repo's commands with
  project detection; on Windows: sleep, replace llama.cpp, start now, tunnel shortcut, active hours).
  `--yes` and no-terminal runs take the safe default (never an unattended reboot, never auto-enabling the overnight tier).
- `load_config` applies schema defaults, so a short settings file is enough; the dispatcher always validates the
  addresses and admin account, and a `# NEEDS:` entry `KEY=VALUE` (the overnight tier) offers to change a setting
  instead of telling you to edit a file.
- A multi-agent review of this work found and we fixed: settings-file rewrites that could turn an inert value into
  code (quote escaping, round-trip parser on both platforms), dropped `export` lines, CRLF files, glob and octal
  edge cases, unusable values offered as defaults, silent adoption of detected addresses, stale done-markers after a
  failed re-run, `NODE_ENV` not reaching the agent's copy, npm/cargo/go package defaults that did not write `dist/`,
  hard-coded overnight times, and a fallback test that claimed more than it tested.
- Fixes found by the new tests: `CRON_REPO` unbound before GitHub settings exist; Windows option handling with
  `$PSBoundParameters`.

## 0.1.0

First release: the whole guide as a setup kit.

- `setup.sh` dispatcher and 13 laptop stages (Debian base, SSH, agent user, tools, GitHub, Hermes, OpenRouter roles,
  services, llama.cpp, laptop model, local profile and fallback chain, skills and cron, firewall).
- Tools: `verify` (Step 33), `github-smoke-test`, `fallback-test`, `overnight-laptop`, `adopt-repo`.
- Windows scripts: SSH access and tunnel, llama.cpp server with firewall rule and logon task, overnight swap, status.
- Templates for every file the guide has you write by hand; a YAML merge tool for `~/.hermes/config.yaml`.
- Tests: ShellCheck, unit and dry-run tests, sandboxed real runs with stubbed externals, PowerShell tests.
