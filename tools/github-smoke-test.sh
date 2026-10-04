#!/usr/bin/env bash
# TITLE: Prove the GitHub guard rails (push branch and PR ok; main, unapproved merge, tag delete, workflow change rejected)
# RUN-AS: hermes
# GUIDE: Step 8 Verify
# NEEDS: GITHUB_ORG GITHUB_REPOS
# Run BEFORE adding .github/workflows/release.yml: it pushes a tag, which would trigger a release.
# Options: --repo NAME (default: first repo in GITHUB_REPOS)
set -Euo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
REPO=''
while (($#)); do
  case $1 in
    --repo) REPO=$2; shift ;;
    *) common_flag "$1" || die "unknown option: $1" ;;
  esac
  shift
done
load_config
use_hermes_path
if [[ -z $REPO && $GITHUB_REPOS == *" "* ]]; then ask_text REPO "Which repo should the smoke test use? ($GITHUB_REPOS)" "$CRON_REPO"; fi
REPO=${REPO:-$CRON_REPO}
case " $GITHUB_REPOS " in
  *" $REPO "*) ;;
  *) die "'$REPO' is not one of your repositories ($GITHUB_REPOS)" ;;
esac
dir=$HOME/repos/$REPO
[[ -d $dir/.git ]] || die "$dir is not a clone (run stage 05)"
cd "$dir" || exit 1

echo "This pushes a throw-away branch and a v0.0.0-smoke.* tag to $GITHUB_ORG/$REPO and tries to break the rules."
confirm "Continue?" || die "not confirmed"
[[ $DRY_RUN == 1 ]] && { log "[dry-run] would run the seven checks"; exit 0; }

git fetch -q origin
base=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||')
ts=$(date +%Y%m%d%H%M%S)
br=hermes/smoke-$ts wf=hermes/smoke-wf-$ts tag=v0.0.0-smoke.$ts
fails=0
out=$(mktemp)
expect() { # expect ok|reject "label" cmd...
  local want=$1 label=$2; shift 2
  if "$@" >"$out" 2>&1; then got=ok; else got=reject; fi
  if [[ $got == "$want" ]]; then printf '  PASS  %s\n' "$label"; else printf '  FAIL  %s (expected %s, got %s)\n' "$label" "$want" "$got"; sed 's/^/        /' "$out"; fails=$((fails + 1)); fi
}

git switch -q -c "$br" "origin/$base"
git commit -q --allow-empty -m "smoke test"
expect ok     "push a hermes/ branch"                 git push -q -u origin "$br"
expect reject "push straight to $base is rejected"    git push -q origin "HEAD:refs/heads/$base"
# "Require a pull request" alone only needs a PR to exist; without required approvals the agent could merge its own
expect ok     "open a pull request"                   gh pr create --head "$br" --base "$base" --title "smoke test (close me)" --body "Throw-away PR from tools/github-smoke-test.sh"
expect reject "merging it without your approval is rejected" gh pr merge "$br" --squash
gh pr close "$br" --delete-branch >/dev/null 2>&1 || true
git tag "$tag"
expect ok     "create a release tag"                  git push -q origin "$tag"
expect reject "delete that tag is rejected"           git push -q origin ":refs/tags/$tag"
git switch -q -c "$wf" "origin/$base"
mkdir -p .github/workflows
printf 'name: smoke\non: workflow_dispatch\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' >.github/workflows/smoke.yml
git add .github/workflows/smoke.yml && git commit -q -m "smoke: workflow change"
expect reject "changing .github/workflows is rejected" git push -q origin "$wf"

git switch -q "$base" 2>/dev/null || git switch -q --detach "origin/$base"
git branch -q -D "$br" "$wf" 2>/dev/null
git tag -d "$tag" >/dev/null 2>&1
rm -f "$out"

echo
if ((fails)); then
  echo "FAILED ($fails). A push that should have been rejected succeeded: the matching ruleset is not active or targets the wrong"
  echo "branch/tag pattern, the main ruleset does not require an approval, or the token has too many permissions (Workflows)."
  echo "Fix it before continuing."
else
  echo "All guard rails hold."
fi
echo "Clean up in the GitHub web UI: tag $tag (deleting it needs you as a bypass actor on the tag ruleset), and branch $br if it is still there."
exit $((fails > 0))
