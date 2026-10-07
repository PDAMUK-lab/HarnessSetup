---
name: toolcall-check
description: Test whether a model can act as an agent - six tool-calling probes (single call, choosing the right tool, nested arguments, no call when none is needed, using a tool result, parallel calls) against a local endpoint or any OpenAI-compatible URL. Use after downloading, swapping or abliterating a model, before trusting it with real work.
---
# Tool-call check

Input: an endpoint and optionally a model. Endpoints are the provider names in ~/.hermes/config.yaml:
`laptop`, `desktop`, `desktop-v100`, `desktop-night`, or a base URL ending in `/v1`. With no input, check
`laptop` and `desktop`.

1. Run the probes (a named endpoint brings its own URL, model and API key):

       hermes-toolcall-check <endpoint> [--model <id>] [--json]

   Each request may take minutes on a large model; the default timeout is 300 seconds per probe
   (`--timeout` changes it). Run endpoints one after the other, never in parallel: each GPU has one slot.
2. Report the table as printed: PASS/FAIL per probe, the seconds, and the note. The five critical probes decide the
   verdict; "parallel calls" is a WARN only (Hermes works without it, just slower).
3. Verdict:
   - all critical probes pass: fit for agent work
   - "single call" fails with "answered in prose": the server is not using the model's chat template; it needs
     `--jinja` (the laptop's unit and the desktop's start scripts have it - check the model's `*_CHAT_KWARGS`)
   - "no tool when none is needed" or "uses a tool result" fails: the model loops on tools; do not use it as a
     planner, and at most as a worker on narrow tasks
   - "nested arguments" fails: it will break on real tools (file edits, gh); not fit
4. If the user is comparing models, add one line per model to ~/model-tests/toolcall.csv
   (`date,endpoint,model,critical_passed,all_passed`) so results stay comparable over time.

Never change a model, a server or the Hermes configuration in this skill: it only measures.
