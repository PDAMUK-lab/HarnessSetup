---
name: overnight
description: Turn a task into an overnight job for the desktop's big model - a self-contained prompt that ends in a draft PR, checked against the overnight rules, created paused in the local profile. Use when the user wants work done while the desktop is otherwise idle at night.
---
# Overnight job

The overnight tier swaps the desktop to @@NIGHT_MODEL_ALIAS@@ between @@NIGHT_START@@ and @@NIGHT_END@@. Jobs start a
quarter of an hour after the swap and must finish two hours before it ends. One job per night.

1. Check the tier is set up: `hermes -p local config get providers.desktop-night.default_model` must print
   @@NIGHT_MODEL_ALIAS@@. If it fails, stop: the admin runs `./setup.sh tool overnight-laptop` and, on the desktop,
   `Install-Overnight.ps1`.
2. Ask for the repo (one under ~/repos-cron/, the cron clones) and the task, then write the prompt. It must:
   - stand alone: nobody can answer questions at night, so name the files, the goal and how success is measured
   - start from a fresh `origin/main` and work on a branch `hermes/<short-topic>`
   - run the repo's tests (see its AGENTS.md) and include their output
   - end with a draft PR (`gh pr create --draft`) whose body has the test output; never merge, never touch `main`
   - stop and open the draft PR with what it has if it runs out of ideas, instead of looping
   - fit in the window: if it would take more than about three hours, split it into separate nights
3. Show the prompt to the user and wait for an OK.
4. Pick a name (`overnight-<topic>`), check it is free (`hermes -p local cron list`), and create it paused:

       hermes -p local cron create "daily at <start>" "<prompt>" --workdir ~/repos-cron/<repo> \
         --provider custom:desktop-night --model @@NIGHT_MODEL_ALIAS@@ --name overnight-<topic> --paused

   <start> is the swap time plus 15 minutes, in the form `hermes cron create` accepts. A job pinned to the night
   model never falls back, so it fails while the desktop is away (`hermes-desktop status`).
5. Tell the user how to test and start it: run it once by hand during the day with the 27B started
   (`hermes -p local cron run overnight-<topic>`), check `hermes -p local cron runs overnight-<topic>`, then
   `hermes -p local cron resume overnight-<topic>`. Pause it again after it has done its job.
