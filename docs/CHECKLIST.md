# Final checklist (Step 33)

`./setup.sh tool verify` runs what a machine can judge. Tick the rest by hand. Checks 1-19 are the guide's numbering;
19 applies only if you set up the overnight tier.

| # | Check | Expected | How |
| --- | --- | --- | --- |
| 1 | `nvidia-smi` on the laptop | GTX 1070, 550-series driver | verify |
| 2 | `sudo -u hermes sudo -n true` | works without a password; approval mode **off** on the dashboard's Config page | verify + manual |
| 3 | As `hermes`: push to `main`, merge its own PR without approval, delete a `v*` tag, change `.github/workflows` | all rejected | `./setup.sh tool github-smoke-test` |
| 4 | `hermes doctor` and `hermes -p local doctor` | no errors | verify |
| 5 | Tunnel, then `http://localhost:9119` | dashboard loads, gateway running | verify (laptop side) + manual (browser) |
| 6 | Dashboard URL from a phone using the laptop's IP | does **not** load | verify (loopback bind) + manual (phone) |
| 7 | Parallel subagent task (Step 12) | separate `hermes-subagent/*` branches; main checkout clean | manual |
| 8 | A PR opened by the agent | body has the test output and the review subagent's summary | manual |
| 9 | Tool-call smoke test on both models | a `get_weather` tool call from each | verify |
| 10 | `hermes fallback list` | OpenRouter, then desktop, then laptop | verify |
| 11 | `hermes-mode status` | laptop 200, desktop 200 (when on), OpenRouter 200 | verify |
| 12 | `hermes-mode local`, ask, then `hermes-mode cloud` | answer from `qwen3.6-35b-a3b`; cloud restored | manual |
| 13 | `/model custom:laptop:qwen3.5-9b` mid-session | next answer from the laptop model | manual |
| 14 | Internet off (Step 29) | desktop answers, then laptop with the desktop asleep | `./setup.sh tool fallback-test` |
| 15 | `/release` round trip in a test repo | release PR, then tag, CI run, published release | manual |
| 16 | `hermes cron status`, `hermes cron doctor` (and `hermes -p local ...` if Step 31) | recent ticks; doctor exits 0 | verify |
| 17 | Firewall checks (Step 28) | 200, 200, BLOCKED, resolves, NTP synced | verify |
| 18 | Reboot the laptop, log in to the desktop, **do not** log in as `hermes`; repeat 5, 11, 16 | all pass: gateways, dashboard and both model servers came up on their own | verify (readiness) + manual (the reboot) |
| 19 | The morning after an overnight job | completed run, a draft PR, desktop back on `qwen3.6-35b-a3b` | manual |

If check 18 fails on the dashboard or gateway, linger is off or a unit is not enabled:
`loginctl show-user hermes -p Linger`, then as `hermes`: `systemctl --user is-enabled hermes-dashboard` and
`hermes gateway status`. If the desktop model is down, check the `llama-server` task in Task Scheduler
(`.\desktop\windows\Check-Desktop.ps1`).

## Per-phase proofs from the guide

- [ ] Step 1: SSH works, `sudo -v` accepts the password
- [ ] Step 3: `nvidia-smi`; `dkms status` shows `nvidia-current/550...: installed`
- [ ] Step 1: closing the lid keeps SSH alive (lid and sleep settings done before Step 2); `sudo -i` gives a root shell (`su` does not work without a root password)
- [ ] Step 4: `swapon --show` lists `/dev/zram0`
- [ ] Step 5: a **new** PowerShell window logs in without a password
- [ ] Step 6: `ROOT-OK`; `Linger=yes`
- [ ] Step 8: smoke test green; test branch and tag removed in the web UI
- [ ] Step 10: Hermes opens files with tools and `hermes -c` resumes the session
- [ ] Step 12: subagent branches, `hermes/demo` pushed, `/review` refers to the real diff
- [ ] Step 14: `curl -s http://127.0.0.1:9119/api/status | jq .auth_required` is `false`; `ss -tlnp | grep 9119` shows `127.0.0.1` only
- [ ] Step 17: `llama-server --list-devices` shows `GTX 1070, compute capability 6.1`
- [ ] Step 18: `nvidia-smi` shows ~7GB used
- [ ] Step 19: Task Manager GPU ~7.3GB and Memory < 90% while generating
- [ ] Step 24: a new session answers "What are your rules for releasing this repo?" without opening the file
- [ ] Step 25: `/release` proposes a version and asks before doing anything
- [ ] Step 26: `/release 0.0.1` twice (merge in between) publishes `v0.0.1`
- [ ] Step 27: `hermes cron runs nightly-tests` completed; `hermes cron doctor` exits 0
- [ ] Step 31: manual run against the 27B completed; both desktop tasks ran overnight

## Extras

| Check | How | Pass |
| --- | --- | --- |
| Desktop away works | `.\Desktop-Mode.ps1 away` on the desktop; `hermes-desktop status` on the laptop; `hermes chat -q "Which model are you?"` | the laptop's 9B answers; the desktop's GPU and memory are free |
| Desktop back works | `.\Desktop-Mode.ps1 back`; `hermes-mode status` | the desktop endpoint answers 200 and is back in the chain |
| V100 cards visible (optional tier) | `.\Check-V100.ps1` | no FAIL; both cards listed, driver 582.x, TCC |
| V100 server (optional tier) | `./setup.sh tool verify` | the V100 port answers and returns a tool call |
