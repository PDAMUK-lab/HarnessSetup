#!/usr/bin/env bash
# TITLE: Install Hermes Agent
# RUN-AS: hermes
# GUIDE: Step 9
# NEEDS: AGENT_USER
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
stage_begin
use_hermes_path

if command -v hermes >/dev/null 2>&1; then
  ok "hermes already installed at $(command -v hermes)"
else
  run bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
fi

if [[ $DRY_RUN != 1 ]]; then
  # The installer puts hermes on PATH through ~/.bashrc, which a non-interactive shell skips.
  # Check the usual place first, then ask an interactive shell.
  use_hermes_path
  path=$(command -v hermes || bash -ic 'command -v hermes' 2>/dev/null | tail -1 || true)
  [[ -n $path ]] || die "hermes is not on PATH after the installer ran. Find it with: sudo machinectl shell $AGENT_USER@ then: command -v hermes"
  PATH="$(dirname "$path"):$PATH"
  export PATH
  ok "hermes is at $path"
  # Phase 4's dashboard service must use this exact path
  [[ $path == "$HERMES_BIN" ]] || warn "hermes is at $path, not $HERMES_BIN; stage 08 will use $path"
  hermes doctor || warn "hermes doctor reported problems (\"no provider configured\" is expected at this point)"
fi
stage_end
cat <<MSG

MANUAL STEP (needs your OpenRouter key, so it is not scripted):
  1. On openrouter.ai create a key just for this machine WITH A CREDIT LIMIT (about \$50/month to start),
     and block providers that train on your prompts in the privacy settings.
  2. In the agent's session:   sudo machinectl shell $AGENT_USER@     then:   hermes model
     Choose OpenRouter, paste the key, and pick the planner (main) model from the live list.
  3. Check it:   cd ~/repos/$CRON_REPO && hermes --tui   and ask it to summarise the repo and how to run its tests.
Then fill in the OR_* model IDs in config/node.env and run:  ./setup.sh run 07
MSG
