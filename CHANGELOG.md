# Changelog

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
