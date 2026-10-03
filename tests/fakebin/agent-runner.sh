#!/usr/bin/env bash
# HS_AGENT_RUNNER for tests: run the command string in the fake agent environment (current user, fake HOME)
export PATH="$HOME/.local/bin:$PATH"
bash -c "$1"
