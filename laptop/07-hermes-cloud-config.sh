#!/usr/bin/env bash
# TITLE: Roles on OpenRouter: workers, reviewer, compression, worktree isolation
# RUN-AS: hermes
# GUIDE: Step 11
# NEEDS: OR_WORKER_MODEL OR_REVIEW_MODEL OR_COMPRESSION_MODEL REASONING_EFFORT MAX_CONCURRENT_CHILDREN MAX_ITERATIONS APPROVAL_MODE
# Needs `hermes model` done (planner + OpenRouter key). The worker, reviewer and summariser model IDs are asked for.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
stage_begin
require_vars OR_WORKER_MODEL OR_REVIEW_MODEL OR_COMPRESSION_MODEL
need_cmd python3

cfg=$HOME/.hermes/config.yaml
[[ -f $cfg ]] || fail_or_warn "$cfg does not exist yet - run 'hermes model' first (stage 06 explains how)"
if ! grep -qs '^OPENROUTER_API_KEY=' "$HOME/.hermes/.env"; then
  warn "no OPENROUTER_API_KEY in ~/.hermes/.env - did 'hermes model' finish?"
fi
[[ $OR_REVIEW_MODEL != "$OR_WORKER_MODEL" ]] || warn "reviewer and worker model are the same; the guide wants the reviewer from a different family than the planner"

render_template "$HS_ROOT/templates/hermes/cloud.yaml.tpl"
frag=$(mktemp)
printf '%s' "$RENDERED" >"$frag"
if [[ $DRY_RUN == 1 ]]; then
  log "[dry-run] would merge into $cfg:"
  sed 's/^/    | /' "$frag" >&2
else
  python3 "$HS_ROOT/lib/merge_yaml.py" "$cfg" "$frag"
fi
rm -f "$frag"

stage_end
cat <<MSG
Next: ./setup.sh run 08  (gateway + dashboard as services). The dangerous-command approval mode is now
'$APPROVAL_MODE' (setting APPROVAL_MODE; the dashboard's Config page can change it too).
Then prove subagents and review (guide Step 12) - see docs/CHECKLIST.md.
MSG
