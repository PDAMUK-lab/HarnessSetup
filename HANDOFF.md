# Handoff: finish 0.6.0 (dashboard from browsers, SMB share, offline mode)

This file is a self-contained task for the **HarnessSetup v0.5.0 node's own agent** (Hermes on the laptop). A Claude Code
session will review the result afterwards, so record what you did and why in the PR.

## For the human: how to start it

1. **Give the machine account access to this repo:**
   - Add `PDAMUK/HarnessSetup` to the GitHub organization the machine account works in (or give it Write on this repo).
   - Add the repo to the fine-grained token's repositories.
   - Add it to `GITHUB_REPOS` (`./setup.sh configure --only GITHUB_REPOS`), then re-run stage 05 so it is cloned to `~/repos/HarnessSetup`.
2. **Install the test tools on the laptop:** `sudo apt install -y shellcheck jq python3-yaml`. PowerShell is optional; CI runs those tests.
3. **Give the agent the task.** As `hermes`, in the dashboard chat or `hermes chat`, with the cloud profile (best results), or `hermes -p local chat` for the local models:

   > Work in ~/repos/HarnessSetup. Fetch origin, check out the branch `claude/confident-bohr-xju95x`, read HANDOFF.md and
   > carry out the task in it exactly, step by step, ending with a draft pull request into main. Do not merge.

   For an overnight run, give the same text to `./setup.sh tool overnight-laptop --task "..."` (see the RUNBOOK).
4. **Do not merge the PR yourself.** Leave it for the Claude Code review, then approve and merge. The merge releases 0.6.0.

---

## For the agent: the task

### Ground rules (read first)

- **Never run the kit for real on this machine.** You are running *on* a node this kit built: `./setup.sh run ...` and
  `./setup.sh tool ...` would reconfigure the live laptop (firewall, services, sudoers). Only run the test suite (it uses
  dry runs, a fake root and stub commands) and `bash -n` / `shellcheck` on files.
- **Branches.** Create `hermes/finish-0.6.0` from `origin/claude/confident-bohr-xju95x`. Commit in small steps and push the
  branch. At the end, open a **draft PR into `main`**. Never push to `main` or to `claude/*`, never force-push, never merge.
- **Do not edit `.github/workflows/`.** Your token cannot push those files anyway.
- **Tests.** Never skip, disable or loosen a test to get green. Add tests for every new behaviour, in the style of the
  neighbouring tests.
- **Style.** Match the surrounding code: short comments, plain English, the existing helpers (`sudo_run`, `put_file`,
  `install_template`, `agent_exec`, `confirm`, `log/ok/warn/die`), and the `# TITLE/RUN-AS/GUIDE/NEEDS` headers.
  - Every setting a script reads must be in its `NEEDS:` line; `tests/test-needs.sh` checks this.
  - New settings go in `config/settings.schema` *and* `config/node.env.example`.
  - A new setting type needs both validators: bash `lib/config.sh` `cfg_validate`, PowerShell `desktop/windows/Common.ps1`
    `Test-SettingValue`, plus cases in `tests/validator-cases.psv`.
- **After every step:** run the suite, commit only when it passes, and push.
- **When unsure:** read the code, or Hermes's source in `~/.hermes/hermes-agent`. Choose the least invasive option and
  write the choice down in the PR. Do not stop to ask.

### Verify (after every step)

```bash
cd ~/repos/HarnessSetup
bash tests/run-tests.sh </dev/null > /tmp/hs-tests.log 2>&1; grep -E '^FAIL:|ALL TESTS|TESTS FAILED|skipped' /tmp/hs-tests.log
```

- **Pass:** `ALL TESTS PASSED`.
- **Expected FAIL line:** `FAIL   #9   laptop answers with a tool call` in the tools suite is expected output from the
  verify tests, not a failure.
- **Missing PowerShell:** without `pwsh` the PowerShell suite reports "skipped". After opening the PR, wait for its CI
  (which has `pwsh`) and fix anything it reports.

### Step 1: make the WIP commit 00570ae pass

That commit is untested. It adds:
- **`DASHBOARD_FROM`** (type `iplist`, default `none`). When set:
  - `lib/common.sh` sets `DASHBOARD_BIND=0.0.0.0` for `templates/systemd/hermes-dashboard.service.tpl`;
  - stage 08 runs `tools/dashboard-login.sh` when there is no `dashboard.basic_auth` in `~/.hermes/config.yaml`;
  - stage 13 admits only the listed devices to `DASHBOARD_PORT`.
- **`SMB_SHARE`** (type `smbpath`, default `none`):
  - `tools/smb-share.sh` mounts the share at `/srv/share` for the agent, with credentials in `/etc/hermes-smb.cred` (mode 600);
  - stage 13 allows port 445 to the share's resolved address before the LAN deny.

Run the suite and fix what fails. The test changes are in `tests/test-stages.sh` (the stage 13 and 08 block after
`13: env files locked to 600`), `tests/test-tools.sh` (dashboard-login, smb-share) and `tests/validator-cases.psv`
(iplist, smbpath).

**Done when:**
- The suite passes.
- `shellcheck` is clean (the lint suite).
- With both settings at `none`, nothing behaves differently from v0.5.0.

### Step 2: finish browser access (phone, another laptop)

The user reaches the node from a **phone browser**, not an SSH app. Hermes refuses a non-loopback bind without a login
(`hermes_cli/web_server.py`, `should_require_auth`). Its basic-auth plugin reads
`dashboard.basic_auth.{username,password_hash,secret}`, and `tools/dashboard-login.sh` writes these in Hermes's own scrypt format.

1. **`tools/verify.sh`:** when `DASHBOARD_FROM` is not `none`, check that the dashboard listens and that
   `/api/status` reports `auth_required: true`. Otherwise keep today's loopback check. Add tests.
2. **Docs:** a RUNBOOK section "The dashboard from a phone or another laptop" and a README row:
   - give the devices DHCP reservations;
   - set `DASHBOARD_FROM`;
   - re-run stages 08 and 13;
   - browse to `http://<laptop>:<port>`.
   Say plainly that this is plain HTTP on the LAN: use a strong, unique password, and only listed devices get through.

**Done when:** tests pass and the docs say how to do it.

### Step 3: finish the SMB share for finished work

1. **Tell the agent itself where finished work goes** when `SMB_SHARE` is set: "save finished results to
   `/srv/share/<project>/`". Find the least invasive persistent place Hermes offers, in this order of preference:
   - a line the kit already writes (for example the `local` profile config written by stage 11);
   - a Hermes skill or memory file under `~/.hermes`. Check Hermes's source for a persistent system prompt, persona or
     memory file.

   Implement it in the stage that owns that file, add a test, and explain the choice in the PR.
2. **`tools/verify.sh`:** when `SMB_SHARE` is set, check `/srv/share` is mounted and writable by the agent. Report a warning, not a failure, when the NAS is off.
3. **Docs:** RUNBOOK section and README row (`SMB_SHARE`, `./setup.sh tool smb-share`, re-run stage 13).

### Step 4: offline mode (`OFFLINE=1`)

The node must be able to work with **no internet at all**: no GitHub, no OpenRouter, finished work goes to the SMB share.
Setup still needs the internet once (apt, Hermes, llama.cpp, models); offline is about running afterwards.

1. **The setting:** `OFFLINE|laptop|basic|bool01|0` "Work without the internet (no GitHub, no OpenRouter)".
2. **Stages:**
   - Mark stages 05, 07 and 12 with a new header line `# ONLINE: yes`.
   - In `setup.sh`, with `OFFLINE=1`:
     - `next` skips them and logs that it did;
     - `list` shows them as skipped (offline);
     - `run` on one refuses, with the reason.
   - `tests/test-needs.sh` and the dispatcher tests must still pass. Extend them for the new header.
3. **Settings:** hide the settings only stages 05, 07 and 12 use with `WHEN` = `OFFLINE=0` in the schema. `WHEN`
   supports a single `KEY=value`; check none of these settings already has a `WHEN`.
4. **Stage 11:** first find out whether it depends on stage 07's output (the `local` profile is cloned from the default
   profile, which stage 07 and `hermes model` configure for OpenRouter). With `OFFLINE=1`:
   - the fallback chain (`lib/chain.sh`) must contain no OpenRouter entry;
   - the node must end in local mode (`hermes-mode local`, i.e. `hermes profile use local`).

   If the default profile needs a non-OpenRouter model for this to work, configure it to the desktop endpoint with the
   laptop as fallback. Explain the approach in the PR.
5. **Stage 13:** with `OFFLINE=1`, do not allow 80/443 out (DNS, NTP, the desktop and the SMB share stay allowed).
6. **`tools/verify.sh`:** with `OFFLINE=1`, skip the GitHub, OpenRouter credit and cloud-profile checks, and say once that they were skipped.
7. **Tests** for each point above, and docs: a README section "Working offline" (what works, what does not, how to
   switch back: set `OFFLINE=0`, re-run 05, 07, 11, 12 and 13).

### Step 5: version, changelog, PR

1. Set `VERSION` to `0.6.0`. Add a `## 0.6.0` section at the top of `CHANGELOG.md`, in the style of 0.5.0, with an
   "Upgrading from 0.5.0" line: which stages to re-run.
2. Update the README layout and tool lists for the new tools.
3. Delete this `HANDOFF.md` in the last commit.
4. Open a **draft PR** from `hermes/finish-0.6.0` into `main`, titled "HarnessSetup 0.6.0: browser access, SMB share,
   offline mode". The body has:
   - what each step did;
   - the design choices you made (steps 3.1 and 4.4 especially);
   - the last test summary;
   - anything not done, and why.

Then stop.

## Background (for the reviewer)

- **Release:** `main` is the released v0.5.0 (merge 49c5095). A release happens when a new `VERSION` lands on `main`
  (`.github/workflows/release.yml`). Merge with a merge commit.
- **Run as root, CI as a normal user:** CI runs the suite as a normal user; a root container hides permission bugs (the
  backup/restore one was found that way). If a test ever leaves `/` at mode 700 or `/tmp` without its sticky bit:
  `chmod 755 /; chmod 1777 /tmp`.
- **Real hardware:** the Windows scripts are tested only by dry runs under pwsh on Linux.
