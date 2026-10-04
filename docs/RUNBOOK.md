# Runbook

The order of everything, with the steps that need you marked **MANUAL**. Step numbers match
[GUIDE.md](GUIDE.md). Every `./setup.sh run NN` accepts `--dry-run` (show, change nothing) and `--yes` (take the
default for every question), and is safe to run again. `./setup.sh list` shows what has completed.

Anything a stage needs to know, it asks: settings it cannot guess (accounts, model IDs) and options you can decide
(Docker? CUDA or Vulkan? start the service now?). Pass the flag the stage's header documents to skip a question.

Two machines: the **laptop** (`ai-node`, Debian 13, GTX 1070) and the **desktop** (Windows, RX 6600 XT).
Commands are for the laptop unless the heading says **desktop**.

---

## 0. Before the stages (MANUAL)

1. **Router.** Create DHCP reservations: laptop `192.168.1.150`, desktop `192.168.1.100` (or your own addresses).
2. **Laptop firmware.** Disable Secure Boot (otherwise see guide Step 3, MOK enrolment). Enable "power on after AC
   loss" if it exists.
3. **Install Debian 13** from the netinst image. Leave the root password **empty**. User `ai-node`, hostname
   `ai-node`. Software selection: only *SSH server* and *standard system utilities*.
   With no root password, root is locked: `su` fails ("Authentication failure") and root cannot SSH in; use `sudo -i` for a
   root shell. (Set a root password instead and the installer skips `sudo`, which every stage needs.) Keep the lid open until
   stage 01 has run: it is the first thing the stage does, and a closed lid suspends the laptop and drops SSH.
4. **Windows desktop.** Freshly reset, then the current AMD Adrenalin driver. Install the Microsoft Visual C++
   Redistributable (x64) if `llama-server.exe` later reports a missing DLL.
5. **Get this kit onto both machines.** On the laptop, over SSH from the desktop:

   ```bash
   sudo apt install -y git            # the laptop firewall is not on yet
   git clone https://github.com/PDAMUK/HarnessSetup.git ~/HarnessSetup && cd ~/HarnessSetup
   ```

   (Or copy the folder with `scp -r HarnessSetup ai-node@192.168.1.150:`.) On the desktop, clone or unzip it too and
   open PowerShell with `Set-ExecutionPolicy -Scope Process Bypass` for the session.
6. **Settings.** You do not edit a file: the first `./setup.sh` stage you run (or `./setup.sh configure`) asks for
   them, with explanations, detected defaults and validation. Have these ready: the laptop's and desktop's IP
   addresses and the router's, the admin account name from the Debian install, and (later, when asked) your GitHub
   organisation and repos and the OpenRouter model IDs. The desktop scripts ask the shared questions too; on its
   first run `Setup-LaptopAccess.ps1` offers to copy the laptop's settings over SSH so you type them once.

```bash
./setup.sh configure      # optional now: asks for the settings (--advanced adds ports, context sizes, model files)
./setup.sh check          # validates what was saved
```

**Verify:** `ssh ai-node@192.168.1.150` works from the desktop, and `sudo -v` on the laptop accepts your password.

## 1. Laptop operating system (Steps 2-5)

```bash
./setup.sh run 01 --skip-nvidia --dry-run   # optional: see what it does
./setup.sh run 01                           # no sleep (lid ignored), non-free sources, NVIDIA 550 for Pascal, zram, auto-updates
sudo reboot
nvidia-smi                                  # GeForce GTX 1070, 8192MiB, 550.x
```

If `nvidia-smi` fails: `dkms status` should show `nvidia-current/550...: installed` for `uname -r` (build log: `/var/lib/dkms/nvidia-current/550.163.01/build/make.log`). The script refuses to
continue if it sees `nvidia-open-kernel-dkms`, an NVIDIA apt repo, a non-550 candidate, or a backports kernel (6.16+): those drop or break Pascal.

**Desktop (PowerShell):**

```powershell
.\desktop\windows\Setup-LaptopAccess.ps1    # key, install on laptop (laptop password once), proves key login, writes hermes-tunnel.cmd
```

Then on the laptop (keep your session open):

```bash
./setup.sh run 02                           # password and root SSH logins off (asks you to confirm the key login worked)
```

**Verify:** open a **new** PowerShell window: `ssh ai-node@192.168.1.150` logs in without a password.

## 2. Agent user, tools, GitHub (Steps 6-8)

```bash
./setup.sh run 03        # user 'hermes' with passwordless sudo (asks first; AGENT_SUDO=limited|none for less), linger, copies the kit to /opt/harness-setup
./setup.sh run 04        # build tools, Node 22, gh.   Add --docker if your projects build in containers.
```

Install the toolchains your projects need (language runtimes, compilers, test databases) now.

How much the agent may do is three advanced settings (`./setup.sh configure --only KEY`): `AGENT_SUDO` (`full`, the
guide's design; `limited` = passwordless `apt`, `apt-get`, `systemctl`, `journalctl` only, which stops accidents but is
no security boundary; `none`), `APPROVAL_MODE` (default `off`) and `APPROVAL_DENY` (default on: Hermes refuses a few
destructive command patterns in every mode, sub-agents and cron included: `gh repo delete`/`archive`, `mkfs`, `wipefs`,
`dd` onto a disk, `rm -rf` of `~/.hermes` or `~/repos`, `ufw disable` or `ufw --force reset`). Re-run stage 03, or 07 and
11, after changing them.
From here on, enter the agent's account with `sudo machinectl shell hermes@`, never `sudo -iu hermes`.

### GitHub on the web (MANUAL, Step 8)

0. Rulesets are enforced on public repos (GitHub Free); private repos need a Pro or Team plan, otherwise steps 2 and 3 protect nothing.
1. **Machine account** (for example `yourorg-hermes`, own email). Put the repos in a GitHub **organization** (free is enough), invite
   the machine account as an org **member** (not an outside collaborator: fine-grained tokens do not work for those), give it
   **Write** on each repo (via a team, org base permission None), sign in as it and accept the invitation.
2. **Protect `main`:** Settings > Rules > Rulesets > New branch ruleset, **Enforcement status: Active** (new rulesets start as
   Disabled), target the default branch: require a pull request with **Required approvals = 1**, dismiss stale approvals, require
   approval of the most recent push (otherwise the agent can merge its own PR), block force pushes, restrict deletions. Do not
   add the machine account as a bypass actor. Add "require status checks" after `test` has run once (stage 12 / `adopt-repo.sh`).
3. **Protect release tags:** New tag ruleset, **Active**, target tags `v*`: restrict updates and deletions, leave creation
   allowed. Add yourself (or repo admins) as a **bypass actor**, or the ruleset blocks you too.
4. **Token**, created *as the machine account*: Settings > Developer settings > Fine-grained tokens, **resource owner = the
   organization**, only the selected repositories, 90-day expiry (**put the expiry in your calendar**). If the organization
   requires approval for tokens, approve it as an owner (Organization settings > Personal access tokens) or the token sees no
   private repos.

   | Permission | Access |
   | --- | --- |
   | Contents | Read and write |
   | Pull requests | Read and write |
   | Issues | Read and write |
   | Actions | Read |
   | Commit statuses | Read |
   | Metadata | Read |

   **Do not grant** Workflows, Administration, Secrets or Environments.
5. Note the machine account's noreply address (Settings > Emails). Stage 05 asks for the organisation, repos,
   account name and that address, and refreshes the agent's copy of the kit in `/opt/harness-setup` by itself.

```bash
./setup.sh run 05                  # asks for the token (hidden), sets git identity, clones your repos
./setup.sh tool github-smoke-test  # branch push and PR work; push to main, unapproved merge, tag delete and workflow edits are REJECTED
```

Then delete the smoke branch and tag in the GitHub web UI. **If a push that should fail succeeds, stop** and fix the
ruleset before going on. Run the smoke test *before* you add `release.yml` (it pushes a tag).

## 3. Hermes on OpenRouter (Steps 9-12)

```bash
./setup.sh run 06
```

**MANUAL (Step 10).** On openrouter.ai create a key for this machine with a **credit limit** (start around $50 a
month) and block providers that train on your prompts. Then:

```bash
sudo machinectl shell hermes@
hermes model          # choose OpenRouter, paste the key, pick the planner from the live list
cd ~/repos/yourrepo && hermes --tui     # "Summarise this repo in five bullets and tell me how to run its tests."
exit
```

Stage 07 asks for the worker, reviewer and summariser model IDs (workers: strong mid-tier coder; reviewer: frontier
model from a **different family** than the planner; copy the exact IDs from the list in `hermes model`):

```bash
./setup.sh run 07      # asks for those three, then merges the roles into ~/.hermes/config.yaml (a timestamped backup is kept)
```

Check the credit any time with `./setup.sh tool spend` (as `hermes`): it warns at `SPEND_WARN_PCT` (80%) of the key's
limit, and when the key has no limit or a limit that never resets. `verify` shows the same line.

**MANUAL (Step 12).** In a test repo ask Hermes to use two subagents in parallel (add a `--version` flag; add a
config-loader test), merge them into `hermes/demo` and push; press Ctrl+T to watch; then `/review`. Expect two
`hermes-subagent/...` branches, the main checkout clean, `hermes/demo` on GitHub and nothing on `main`.

## 4. Web control (Steps 13-15)

```bash
./setup.sh run 08      # gateway + dashboard as user services, bound to 127.0.0.1:9119 only
```

On the desktop run the `hermes-tunnel.cmd` that `Setup-LaptopAccess.ps1` put on your Desktop (to pin it: right-click > Create shortcut, Target `cmd.exe /c "<path>"`, pin the shortcut), then browse
to `http://localhost:9119`. Stage 07 already set the dangerous-command approval mode from `APPROVAL_MODE` (default
**off**, the guide's design: unattended jobs and sub-agents never stall or refuse on a prompt); the dashboard's **Config**
page shows it. Browse to `localhost` or `127.0.0.1` only (the dashboard rejects other hostnames).

**Verify:** Status shows the gateway running; Chat opens a session in `~/repos/yourrepo`; from a phone,
`http://192.168.1.150:9119` does **not** load.

## 5. Local models (Steps 16-20)

```bash
./setup.sh run 09      # llama.cpp with CUDA 12.4 (Pascal). If CUDA will not build:  ./setup.sh run 09 --vulkan
./setup.sh run 10      # laptop model: user llm, ~7GB download, systemd service, tool-call smoke test
./setup.sh run 10 --bench      # optional first: context cache in VRAM vs RAM
```

If the service reports CUDA out of memory, choose the smaller file with `./setup.sh configure --only LAPTOP_QUANT`
(the file name and download URL follow it) and re-run stage 10.

**Desktop (administrator PowerShell):**

```powershell
.\desktop\windows\Install-Llama.ps1          # llama.cpp Vulkan build, ~27GB model, API key, firewall rule, logon task, smoke test
.\desktop\windows\Check-Desktop.ps1 -ToolCall
```

It prints the API key once (`-ShowKey` shows it again). **Tune the expert split** as in guide Step 19: lower
`DESKTOP_N_CPU_MOE` (`.\Configure.ps1 -Only DESKTOP_N_CPU_MOE`) and re-run `Install-Llama.ps1` until Task Manager
shows about 7.3GB dedicated GPU memory; keep Windows memory under ~90% (otherwise choose `UD-Q4_K_XL` with
`.\Configure.ps1 -Only DESKTOP_QUANT`). The installer asks whether Windows should never sleep on mains power
(`-NeverSleepOnAC` / `-Yes` answer it without asking).

From the laptop: `curl -s -H "Authorization: Bearer <key>" http://192.168.1.100:8080/v1/models` should list the model.

## 6. Switching between cloud and local (Steps 21-23)

```bash
./setup.sh run 11      # asks for the desktop key; endpoints, 3-entry fallback chain, `local` profile, hermes-mode
```

**MANUAL:** `sudo machinectl shell hermes@`, then `hermes -p local tools` and turn **off** browser, image
generation, voice and web search for the local profile.

Try it: `hermes-mode local`, `hermes chat -q "Which model are you?"` (expect the 35B), turn the desktop off and ask
again (expect the 9B after a retry), then `hermes-mode cloud`. Mid-session: `/model custom:laptop:qwen3.5-9b`.

### Taking the desktop away (when you need the PC for something else)

Hermes treats the desktop as a long-lived worker. When you want the GPU and memory for something else (a game, a render), take
it out of the loop and put it back afterwards. From the desktop, in an administrator PowerShell:

```powershell
.\desktop\windows\Desktop-Mode.ps1 away            # tells the laptop, then stops the model servers and keeps them from restarting
.\desktop\windows\Desktop-Mode.ps1 away -For 4h    # the same; everything comes back by itself after 4 hours (90m, 4h, 1d)
.\desktop\windows\Desktop-Mode.ps1 back            # starts the servers, waits until they answer, then tells the laptop
.\desktop\windows\Desktop-Mode.ps1 status
```

"Tells the laptop" runs `hermes-desktop` there over SSH, as the agent user (stage 03 allows the admin user exactly that
without a password; a laptop set up before kit 0.5.0 asks for the sudo password until stage 03 is re-run). It rewrites Hermes's fallback chain and the
`local` profile without any desktop endpoint (OpenRouter, then the laptop's 9B), and `hermes-desktop on` writes it back.
You can run it on the laptop yourself, as the agent user:

**Automatically:** `.\desktop\windows\Auto-Away.ps1 -Register` (administrator PowerShell) starts a hidden task at every
logon that watches the GPU. When other programs keep it at least `AUTO_AWAY_GPU_PCT` (25%) busy for `AUTO_AWAY_AFTER_MIN`
(2) minutes it runs `Desktop-Mode.ps1 away`; after `AUTO_BACK_AFTER_MIN` (15) quiet minutes it runs `back`. A manual `away`
is left alone. `-Once` prints the current reading and what it would do; `-Unregister` turns it off; the log is
`C:\llama\auto-away.log`. Browsing and video playback stay well under the threshold; raise it if something you leave
running keeps the GPU busy.

```bash
hermes-desktop status        # in or out of the loop, and the order of the endpoints
hermes-desktop off --for 3h  # leave the desktop out; a timer puts it back
hermes-desktop on
```

While the desktop is away: the `local` profile plans on the laptop's 9B, `hermes-mode status` says so, jobs pinned to a desktop
model (the overnight job) cannot fall back and would fail, so pause them; `./setup.sh tool verify` reports the shorter chain as a
warning; `fallback-test` refuses to run. Re-running stage 11 keeps the desktop out while the flag is set.

## 7. Build, test and release (Steps 24-27)

Once per repo, with **your own** account (the agent's token cannot push workflow files):

```bash
./tools/adopt-repo.sh ~/path/to/yourrepo --install 'npm ci' --test 'npm test' --lint 'npm run lint' \
    --package 'npm pack' --version-file package.json
cd ~/path/to/yourrepo && git switch -c add-agent-rules && git add AGENTS.md .github && git commit -m "Add agent rules and CI" && git push -u origin HEAD
```

Merge it, then on GitHub add the `test` job as a required check on the `main` ruleset. (`adopt-repo.sh` also runs
in Git Bash on the desktop.)

```bash
./setup.sh run 12      # /release skill (both profiles), cron clones, nightly-tests, release-watcher (both paused)
```

**MANUAL:** `hermes tools` > select the **cron** platform > enable file, terminal and delegation. Then
`hermes cron run nightly-tests`, `hermes cron runs nightly-tests`, `hermes cron doctor`, and
`hermes cron resume nightly-tests`. Resume `release-watcher` once `release.yml` is on `main`.

**Verify the release flow:** `/release 0.0.1` in a test repo, merge the PR, run `/release 0.0.1` again: a `v0.0.1`
release appears with the artifacts from `dist/`.

## 8. Lock it down (Steps 28-29)

```bash
./setup.sh run 13                  # firewall: default-deny out, desktop model port, LAN deny. Asks first.
./setup.sh tool fallback-test      # internet off: desktop answers, then (desktop asleep) laptop; always restores the firewall
./setup.sh tool verify             # the final checklist, automated where possible
```

Run stage 13 from the desktop (the only address SSH is allowed from afterwards). The agent has root and can change
the firewall: for a boundary it cannot remove, put the laptop on a guest network or VLAN at the router.

## 8b. Backups of the agent's state

The agent has root and can damage its own setup. Back up its state (Hermes's config, memory, sessions, cron jobs,
API keys, the GitHub login and the kit's settings) every day, and keep a copy off the laptop:

```bash
./setup.sh tool backup --install   # every day at BACKUP_TIME (07:15) into /var/backups/hermes-node, the newest BACKUP_KEEP (14) kept
./setup.sh tool backup --list
```

**Desktop (PowerShell):** `.\desktop\windows\Backup-Laptop.ps1 -Register` copies the newest backup into
`DESKTOP_BACKUP_DIR` (`C:\hermes-backups`) half an hour later every day. The backups hold API keys and the GitHub
token, so both folders are readable by you and administrators only.

To restore, on the laptop: `./setup.sh tool restore /var/backups/hermes-node/hermes-node-<date>.tar.gz` (copy a desktop
copy back with `scp` first). It stops Hermes's services, keeps the current state as `~/.hermes.before-restore-<date>`,
unpacks the backup and starts the services; your current settings stay, the backed-up ones are saved beside them.

## 9. Optional: overnight quality tier (Step 31)

`Install-Overnight.ps1` asks whether to turn the tier on and for the start and end times (the laptop side asks too):

```powershell
.\desktop\windows\Install-Overnight.ps1      # 27B model, start-llama-27b.cmd, llama-night / llama-day tasks, wake timers
```

```bash
./setup.sh tool overnight-laptop --task "<self-contained task ending in a draft PR>"   # desktop-night endpoint, local gateway, paused job
```

It prints the remaining order: enable the cron toolsets for the local profile, try the job by hand against the 27B,
restore the day server, resume the job. Jobs run between 01:15 and about 05:00, one per night.

## 9b. Optional: the V100 tier (extra, added later)

Two Tesla V100 SXM2 cards on SXM2-to-PCIe adapters in the desktop, running a second CUDA `llama-server` with Qwen3.8-27B entirely in
graphics memory. Dormant until `V100_ENABLED=1`; you can build the hardware later. The whole path (what to buy, building, BIOS,
the driver, the order, tuning, troubleshooting) is in **[V100.md](V100.md)**. The short version, once the cards are installed:

```powershell
.\desktop\windows\Check-V100.ps1            # does Windows see the cards? no settings needed
.\desktop\windows\Install-V100.ps1          # driver mode TCC (reboot, run again), CUDA 12 llama.cpp, model, firewall, task, smoke test
```

```bash
./setup.sh run 13                             # opens the V100 port for the laptop
./setup.sh tool v100-laptop                   # adds the desktop-v100 endpoint to Hermes, V100 first
```

## 10. Tuning (Step 30)

Build a test set first: 10 to 20 real tasks, each judged by passing tests, run as one-shot cron jobs in the `local`
profile; every change below must improve the pass rate or you undo it. Setting-driven changes
(`./setup.sh configure --only KEY`, then re-run stage 10 or `Install-Llama.ps1`): quantizations, `DESKTOP_N_CPU_MOE`,
`REASONING_EFFORT` and `MAX_CONCURRENT_CHILDREN` (the last two are `--advanced` settings that stage 07 applies: re-run `./setup.sh run 07`).
Another model (the MiMo distill, Ornith, Gemma 4, an uncensored drop-in) is a settings change too: file, URL, alias,
`*_CHAT_KWARGS` and `*_SAMPLING`; [MODELS.md](MODELS.md) gives the values per model. For `-ctk bf16 -ctv bf16` edit the unit or
`start-llama.cmd` by hand as the guide's table says. Server logs show tokens per second:
`journalctl -u llama-server -f` on the laptop, the console window on the desktop.

### Updating llama.cpp (with an undo)

```bash
./setup.sh tool update-llama              # laptop: keeps the current build in /opt/llama.cpp/bin.prev, rebuilds (stage 09),
                                          # restarts and runs the tool-call test; a failing build is replaced by the old one
./setup.sh tool update-llama --rollback   # back to the previous build by hand (add --vulkan to the update for a Vulkan build)
```

**Desktop (administrator PowerShell, during the day):** `.\desktop\windows\Update-Llama.ps1` does the same for the
Vulkan build (`-Rollback` to go back); the start scripts, the key and the models are kept.

**Vulkan or ROCm on the desktop?** llama.cpp publishes a Windows ROCm build (`llama-bNNNN-bin-win-rocm-10.0-x64.zip`)
compiled for the RX 6600 XT's gfx1032. It ships the HIP runtime but not hipBLAS/rocBLAS, which it needs: install AMD's
ROCm 10 libraries once (the source llama.cpp's own build uses), in a Python virtual environment:

```powershell
pip install --index-url https://stable.repo.amd.com/rocm/whl-next/ "rocm[libraries]==10.0.0"
rocm-sdk path --bin      # add the folder it prints to the SYSTEM PATH, then restart Windows (the server task must see it)
```

Then `.\desktop\windows\Compare-LlamaBackends.ps1` downloads the ROCm build into `C:\llama-rocm`, checks both builds list
the card (ROCm0, Vulkan0), runs the same `llama-bench` line on each (the day model, its expert split, empty and 32K deep,
pinned to the card) and says which is faster. The day server is stopped for the ~15 minutes it takes; `C:\llama` is not
changed (`-RocmLibDir <folder>` tries the libraries before they are on the system PATH). Switch only when ROCm generates
more than 10% faster at every depth: `.\desktop\windows\Update-Llama.ps1 -Backend rocm`. It refuses without the libraries,
and puts the Vulkan build back when the new one does not list the card or fails the tool-call test (without hipBLAS/rocBLAS
a ROCm build would quietly run on the CPU). `-Backend vulkan` goes back. Untested on this card so far: the comparison is
the test.


**Measure with the test set runner** (as `hermes`): copy `config/model-tests.example` to `~/model-tests.txt` and write
10 to 20 real tasks (`NAME | REPO | CHECK COMMAND | PROMPT`). Then:

```bash
./setup.sh tool model-test                                   # the local profile's models
./setup.sh tool model-test --provider custom:laptop --model qwen3.5-9b --label 9b-base
./setup.sh tool model-test --provider custom:desktop --model ornith-35b --label ornith    # after switching a slot
```

Each task runs in a throw-away worktree; the pass rate and times go to `~/model-tests/results.csv`. Keep a model or a
setting only if it passes more tasks.

## 11. Final checks and upkeep (Step 33)

Run [CHECKLIST.md](CHECKLIST.md). **Check 18 matters most**: reboot the laptop, do not log in as `hermes`, and repeat
checks 5, 11 and 16.

- **Back up:** `hermes backup` before every `hermes update` (confirm it includes the `local` profile). Keep
  `/etc/systemd/system/llama-server.service`, the dashboard unit, `~/.local/bin/hermes-mode`, and
  `C:\llama\start-llama*.cmd` (all regenerated by re-running the stages).
- **Renew the GitHub token** before its 90 days are up; every push fails after that.
- **Update llama.cpp:** `./setup.sh run 09`, then `sudo systemctl restart llama-server`; on Windows
  `.\Install-Llama.ps1 -UpdateLlama` (and `.\Install-V100.ps1 -UpdateLlama` for the V100 tier). The installers pick the newest
  release that really has the zip: GitHub's "latest" release is a source-only tag.
- **Change a model:** `./setup.sh configure --only LAPTOP_QUANT` (or `.\Configure.ps1 -Only DESKTOP_QUANT`), then re-run stage 10 (laptop) or `Install-Llama.ps1` (desktop).

## If something goes wrong

The guide's troubleshooting table applies as written (see [GUIDE.md](GUIDE.md), "If something goes wrong"). Quick
pointers: `hermes doctor` and the dashboard's Logs page for Hermes; `journalctl -u llama-server -f` for the laptop
model; `.\Check-Desktop.ps1` for the desktop; `./setup.sh tool verify` for the whole node. Every stage stops with a
message that names the fix, and can be re-run once it is applied.
