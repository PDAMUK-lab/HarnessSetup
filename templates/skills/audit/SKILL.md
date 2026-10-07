---
name: audit
description: Review what a past session or cron run actually did - every command, file write, sudo use, network call and git push - and flag the risky ones. Use after a sandbox run, an overnight job, a run on a new model, or whenever something on the laptop changed unexpectedly.
---
# Audit a session

Input: a session ID (or prefix), a cron job name, or nothing (then the most recent session).

1. Find the session:
   - `hermes sessions list --limit 20` (add `-p local` or `-p mixed` for the other profiles)
   - for a cron job: `hermes cron runs <job>` names the run's session
2. Export it, with secrets redacted, and read it all:

       hermes sessions export - --format jsonl --redact --session-id <id>

3. List, in order, every tool call that changes something or reaches out: terminal commands, file writes and edits,
   delegation to sub-agents, git and gh commands, network requests. Skip pure reads unless they read secrets.
4. Flag each risky action with a short reason:
   - HIGH: sudo or root changes; writes outside the task's repo; anything touching ~/.ssh, ~/.config/gh, .env files,
     ~/.hermes config, systemd units, crontabs, the firewall (ufw), users or packages it was not asked to install;
     git push to main or force-push; tags moved or deleted; deleted files or branches; secrets printed or sent
   - MEDIUM: package installs (name them, so the PR lists them as AGENTS.md asks); network calls to hosts other than
     GitHub, OpenRouter, Hugging Face and package registries; very long or looping command sequences
   - LOW: everything else that changed state
5. Check the current state of anything flagged HIGH (for example `git -C <repo> log origin/main -3`,
   `sudo ufw status`, `ls -la ~/.ssh`) and say whether it still stands.
6. Report: a one-line verdict (clean / review needed / act now), the HIGH and MEDIUM items with the evidence line from
   the transcript, then a count of the LOW ones. Never undo anything yourself: propose the fix and let the user decide.
