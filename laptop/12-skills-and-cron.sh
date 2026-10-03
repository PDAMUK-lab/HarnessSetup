#!/usr/bin/env bash
# TITLE: /release skill, cron clones, nightly tests, release watcher
# RUN-AS: hermes
# GUIDE: Steps 25, 27
# NEEDS: GITHUB_ORG GITHUB_REPOS CRON_MODEL
# Options (asked when not given): --active | --paused  (the release-watcher should only run once the
#          release workflow from Step 26 exists)
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
ACTIVE=''
for a in "$@"; do
  case $a in
    --active) ACTIVE=1 ;;
    --paused) ACTIVE=0 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
stage_begin
use_hermes_path
need_cmd hermes gh git
ask_flag ACTIVE "Start the release watcher running now? (answer no until .github/workflows/release.yml is on main in your repos)" n

log "Step 25: the /release skill, in both profiles"
for dest in "$HOME/.hermes/skills/release" "$HOME/.hermes/profiles/local/skills/release"; do
  put_file "$dest/SKILL.md" 644 self <"$HS_ROOT/templates/skills/release/SKILL.md"
  ok "installed $dest/SKILL.md"
done

log "Step 27: scheduled jobs get their own clones"
repo=$CRON_REPO
run mkdir -p "$HOME/repos-cron"
if [[ -d $HOME/repos-cron/$repo/.git ]]; then
  ok "$repo already cloned for cron"
else
  run gh repo clone "$GITHUB_ORG/$repo" "$HOME/repos-cron/$repo"
fi
if [[ $DRY_RUN != 1 ]]; then
  grep -qxF '.worktrees/' "$HOME/repos-cron/$repo/.git/info/exclude" 2>/dev/null ||
    echo '.worktrees/' >>"$HOME/repos-cron/$repo/.git/info/exclude"
fi

install_template "$HS_ROOT/templates/scripts/release-pending.sh.tpl" "$HOME/.hermes/scripts/release-pending.sh" 755 self

have_job() { hermes cron list 2>/dev/null | grep -qw -- "$1"; }
workdir=$HOME/repos-cron/$repo
if have_job nightly-tests; then
  ok "cron job nightly-tests exists"
else
  run hermes cron create "weekdays at 6am" \
    "Reset to origin/main and run the full test suite. If anything fails, create hermes/fix-tests-<date>, fix the cause, re-run the suite, push and open a draft PR whose body includes the failing and passing output. If all pass, reply with only [SILENT]." \
    --workdir "$workdir" --name nightly-tests --paused
fi
if have_job release-watcher; then
  ok "cron job release-watcher exists"
else
  watcher_flag=(--paused)
  [[ $ACTIVE == 1 ]] && watcher_flag=()
  run hermes cron create "every 15m" \
    "A merged release PR has no tag yet; its version is in the context above. Run stage 2 of the release skill for that version." \
    --script release-pending.sh --skill release \
    --workdir "$workdir" --name release-watcher "${watcher_flag[@]}"
fi
if [[ -n ${CRON_MODEL:-} ]]; then run hermes config set cron.model "$CRON_MODEL"; fi

[[ $DRY_RUN == 1 ]] || hermes cron list || true
stage_end
cat <<MSG
Manual steps left:
  * Enable the cron toolsets:   hermes tools     -> select the "cron" platform; enable file, terminal and delegation
  * Commit AGENTS.md and the CI workflows to each repo:   ./tools/adopt-repo.sh --help   (the agent's token cannot push workflows)
  * Try the nightly job, then enable it:
      hermes cron run nightly-tests ; hermes cron runs nightly-tests ; hermes cron doctor ; hermes cron resume nightly-tests
  * After release.yml is on main:   hermes cron resume release-watcher   (it only wakes the agent for a merged, untagged release PR)
  * Cost control: 'hermes pause' stops all schedules, 'hermes resume' restarts them.
Next: ./setup.sh run 13   (firewall - do this last)
MSG
