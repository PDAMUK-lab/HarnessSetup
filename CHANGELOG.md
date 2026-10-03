# Changelog

## 0.1.0

First release: the whole guide as a setup kit.

- `setup.sh` dispatcher and 13 laptop stages (Debian base, SSH, agent user, tools, GitHub, Hermes, OpenRouter roles,
  services, llama.cpp, laptop model, local profile and fallback chain, skills and cron, firewall).
- Tools: `verify` (Step 33), `github-smoke-test`, `fallback-test`, `overnight-laptop`, `adopt-repo`.
- Windows scripts: SSH access and tunnel, llama.cpp server with firewall rule and logon task, overnight swap, status.
- Templates for every file the guide has you write by hand; a YAML merge tool for `~/.hermes/config.yaml`.
- Tests: ShellCheck, unit and dry-run tests, sandboxed real runs with stubbed externals, PowerShell tests.
