# HarnessSetup

A runnable setup kit for the **Autonomous AI Node** guide ([docs/GUIDE.md](docs/GUIDE.md)): a headless Debian 13
laptop running Hermes Agent that builds, tests and releases your code on GitHub, controlled from a web page on a
Windows desktop. OpenRouter is the default brain; Qwen models on the desktop and the laptop back it up.

The guide is the source of truth for *what* and *why*. This repo turns its *do* steps into numbered, re-runnable
scripts, config templates and checks, and keeps the steps that need a human (router, GitHub web UI, OpenRouter key)
as short, explicit prompts in [docs/RUNBOOK.md](docs/RUNBOOK.md).

## Quick start

```bash
# On the laptop (fresh Debian 13, user ai-node), after the manual steps in the runbook's section 0:
git clone https://github.com/PDAMUK/HarnessSetup.git ~/HarnessSetup && cd ~/HarnessSetup
./setup.sh next                      # asks for your settings first, then runs the first stage
./setup.sh list                      # every stage, and whether it has completed
./setup.sh run 01 --dry-run          # see exactly what a stage would do
./setup.sh run 02                    # do a specific one (or keep using: ./setup.sh next)
```

```powershell
# On the Windows desktop (administrator PowerShell, repo copied or cloned there):
.\desktop\windows\Setup-LaptopAccess.ps1     # SSH key + tunnel shortcut (asks for what it needs)
.\desktop\windows\Install-Llama.ps1          # the desktop model server
```

The [runbook](docs/RUNBOOK.md) gives the exact order and the manual steps between stages.

## Everything is asked, nothing needs editing

- **Settings** (IP addresses, accounts, GitHub org and repos, OpenRouter model IDs, quantizations, overnight times ...)
  are asked one question at a time, each with a short explanation and a default in `[brackets]`. Addresses are
  detected where possible (the laptop's own address and gateway; the desktop's address from your SSH session). Every
  answer is validated before anything is written: an IP must look like an IP, a model ID like `vendor/model`, a
  GitHub name like a GitHub name. The first stage you run starts the wizard by itself when there are no settings yet;
  `./setup.sh configure` runs it on demand (`--advanced` for ports, context sizes, model files and folders;
  `--only KEY` to change one setting; `--set KEY=VALUE --defaults` for scripted installs).
- **Just in time.** A stage asks only for the settings it needs and that are still missing: stage 05 asks for your
  GitHub account, stage 07 for the OpenRouter models, and so on. Nothing is asked twice.
- **Options** (install Docker? NVIDIA driver? CUDA or Vulkan? benchmark first? start the release watcher? never sleep
  on mains power?) are asked when you did not give the flag. Flags still work and skip the question. `--yes` (or
  running without a terminal) takes each question's default and answers *yes* to confirmations, like `apt -y`; it
  never reboots on its own and never switches a setting on, and the safety checks (SSH source address, DNS server,
  a valid key login) still run.
- **Windows** asks the same way (`Configure.ps1`, or any installer on its first run), and can copy the laptop's
  settings over SSH so the shared answers are typed once.
- The settings file is plain text (`config/node.env`, git-ignored, no secrets). Editing it by hand still works;
  `config/node.env.example` shows every setting.

## What is automated

| Guide step | Where | |
| --- | --- | --- |
| 1 Install Debian, router reservations | [runbook §0](docs/RUNBOOK.md) | manual |
| 2-4 non-free, NVIDIA 550, server behaviour | `laptop/01-base-os.sh` | script |
| 5 key-only SSH | `desktop/windows/Setup-LaptopAccess.ps1`, `laptop/02-ssh-hardening.sh` | script |
| 6 agent user | `laptop/03-agent-user.sh` | script |
| 7 build tools, Node 22, `gh` | `laptop/04-dev-tools.sh` | script |
| 8 GitHub machine account, rulesets, token | [runbook §2](docs/RUNBOOK.md) | manual |
| 8 laptop login, clones, proof of the guard rails | `laptop/05-github-access.sh`, `tools/github-smoke-test.sh` | script |
| 9 install Hermes | `laptop/06-hermes-install.sh` | script |
| 10 OpenRouter key and planner | `hermes model` | manual |
| 11 planner / workers / reviewer | `laptop/07-hermes-cloud-config.sh` | script |
| 12 prove subagents and review | [checklist](docs/CHECKLIST.md) | manual |
| 13-14 gateway and dashboard services | `laptop/08-hermes-services.sh` | script |
| 15 tunnel | `Setup-LaptopAccess.ps1` writes `hermes-tunnel.cmd` | script |
| 16-18 llama.cpp, laptop model | `laptop/09-llama-cpp.sh`, `laptop/10-laptop-model.sh` | script |
| 19-20 desktop model, endpoint checks | `desktop/windows/Install-Llama.ps1`, `Check-Desktop.ps1` | script |
| 21-23 fallback chain, `local` profile, `hermes-mode` | `laptop/11-hermes-local-config.sh` | script |
| 24, 26 `AGENTS.md`, CI workflows | `tools/adopt-repo.sh` | script |
| 25, 27 `/release` skill, cron jobs | `laptop/12-skills-and-cron.sh` | script |
| 28 firewall | `laptop/13-firewall.sh` | script |
| 29 fallback with the internet off | `tools/fallback-test.sh` | script |
| 30 tuning | `./setup.sh configure --only KEY`, then re-run the stage | manual |
| 31 overnight 27B tier | `desktop/windows/Install-Overnight.ps1`, `tools/overnight-laptop.sh` | script |
| 32 fine-tuning | not automated (optional in the guide) | - |
| 33 final checks | `tools/verify.sh`, [checklist](docs/CHECKLIST.md) | script + manual |

## How it behaves

- **Re-runnable.** Every stage skips what is already in place. Stage completion is recorded
  (`/var/lib/harness-setup/done`, and `~/.harness-setup/done` for the agent user); `./setup.sh list` shows it.
- **Dry run first.** `--dry-run` prints every command and every file it would write and changes nothing on the
  machine. It still asks for, and saves, your settings (`config/node.env` is not a system change), so the preview
  reflects your answers. Windows scripts take `-DryRun`.
- **No secrets in the repo.** `config/node.env` holds addresses and model names only (and is git-ignored). The
  GitHub token and OpenRouter key are typed into prompts or `hermes model`; the desktop key is generated on
  Windows, kept in `C:\llama\api-key.txt` (ACL-restricted) and pasted once into the laptop's `~/.hermes/.env`
  (mode 600).
- **Lock-out guards.** The SSH stage refuses without an authorised key; the firewall stage refuses to cut off
  an SSH session from the wrong address and warns about a DNS server it would block; sudoers is validated
  before install; the fallback test always restores the firewall, even on Ctrl-C.
- **The guide's rules stay rules.** The scripts refuse to install the NVIDIA packages that drop Pascal support,
  refuse to start a dashboard that is not loopback-only, and never grant the GitHub token Workflows access.
- **The agent has root, by design.** `laptop/03-agent-user.sh` asks you to confirm that. The safeguards that remain
  are outside the laptop: GitHub rulesets, the OpenRouter credit limit, your router (guide, Phase 8).

## Layout

```
setup.sh                 dispatcher: list | run <id> | next | tool <name> | check
config/settings.schema   every setting: what to ask, how to explain it, how to validate it, the default
config/node.env.example  a reference copy of the settings file (the wizard writes the real one)
laptop/NN-*.sh           stages, run as the admin user or (via machinectl) as the agent user
tools/                   verify, github-smoke-test, fallback-test, overnight-laptop, adopt-repo
desktop/windows/         PowerShell for the desktop (llama.cpp server, SSH, overnight swap, status)
templates/               systemd units, Hermes config fragments, hermes-mode, release skill, AGENTS.md, workflows
lib/                     common.sh (helpers), config.sh (settings wizard and validation), merge_yaml.py (merge into ~/.hermes/config.yaml)
tests/                   run-tests.sh and the suites it runs
docs/                    GUIDE.md (the source guide), RUNBOOK.md, CHECKLIST.md
```

## Tests

```bash
bash tests/run-tests.sh      # ShellCheck, unit tests, dry runs of every stage, sandboxed real runs, PowerShell
```

The sandboxed runs execute the hermes-user stages for real against stubbed `hermes`, `gh`, `systemctl` and a
local git repo whose pre-receive hook emulates the GitHub rulesets. PowerShell 7 (`pwsh`) is needed for the
Windows tests (`STRICT=1` makes a missing `pwsh` or `shellcheck` a failure).

## What this kit could not verify

It was built and tested without your hardware and without a Hermes install. The things below come from the
guide and its sources, not from a test run, so check them on the first pass. The guide's own "Not verified on
this hardware" list also still applies.

- Hermes CLI behaviour: `hermes profile create local --clone` and the profile directory layout, the
  `providers:` / `fallback_providers:` config keys, `hermes cron create` flags, `hermes fallback list`,
  `hermes gateway install`. If a name differs in your version, the stage stops with a message instead of guessing.
- The scripts call `hermes -p local ...` where the guide writes bare `local ...`: in bash, `local` is a builtin and
  would shadow a command of that name.
- `llama-server --api-key-file` (used instead of putting the key on the command line) exists in current llama.cpp
  builds; if your Vulkan build lacks it, put `--api-key <key>` in `start-llama.cmd`.
- `machinectl -q shell hermes@ ...` runs commands in a real login session; `-q` only hides the banner.
- Windows: the `llama-server` task is created with no execution time limit. `schtasks /create` (the guide's
  command) defaults to 72 hours, which would stop the server every third day.

## Changing the guide's choices

Model files, quant, context size, expert split, overnight times and the OpenRouter model IDs are all settings:
change one with `./setup.sh configure --only LAPTOP_QUANT` (or `.\Configure.ps1 -Only DESKTOP_QUANT` on the desktop)
and re-run the stage (for example `./setup.sh run 10` after switching to `UD-Q4_K_XL`). Version: see [VERSION](VERSION) and [CHANGELOG.md](CHANGELOG.md).
