# Changelog

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
