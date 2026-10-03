#!/usr/bin/env bash
# Add AGENTS.md and the CI workflows to one of your repos (the agent's token cannot push workflows,
# so YOU commit these, once per repo, with your own account).
#
#   tools/adopt-repo.sh PATH --install 'npm ci' --test 'npm test' --package 'npm pack' \
#                       [--lint 'npm run lint'] [--version-file package.json] [--force] [--no-workflows]
#
# Works on any machine with bash (the desktop's Git Bash is fine). Existing files are never overwritten
# unless you pass --force.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
target='' INSTALL_CMD='' TEST_CMD='' LINT_CMD='' PACKAGE_CMD='' VERSION_FILE='' FORCE=0 WORKFLOWS=1
while (($#)); do
  case $1 in
    --install) INSTALL_CMD=${2:?}; shift ;;
    --test) TEST_CMD=${2:?}; shift ;;
    --lint) LINT_CMD=${2:?}; shift ;;
    --package) PACKAGE_CMD=${2:?}; shift ;;
    --version-file) VERSION_FILE=${2:?}; shift ;;
    --force) FORCE=1 ;;
    --no-workflows) WORKFLOWS=0 ;;
    -h | --help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z $target ]] || die "only one PATH, got '$target' and '$1'"; target=$1 ;;
  esac
  shift
done
[[ -n $target ]] || die "usage: tools/adopt-repo.sh PATH --install CMD --test CMD --package CMD  (--help for more)"
[[ -d $target/.git ]] || die "$target is not a git repository"
[[ -n $INSTALL_CMD && -n $TEST_CMD && -n $PACKAGE_CMD ]] || die "--install, --test and --package are required"
: "${LINT_CMD:=none}" "${VERSION_FILE:=VERSION}"
export INSTALL_CMD TEST_CMD LINT_CMD PACKAGE_CMD VERSION_FILE
# the commands are substituted literally; refuse text that would break the generated files
for v in INSTALL_CMD TEST_CMD LINT_CMD PACKAGE_CMD; do
  [[ ${!v} != *@@* && ${!v} != *$'\n'* ]] || die "$v must be a single line without '@@'"
done

write() { # write TEMPLATE DEST
  local dest=$target/$2
  if [[ -e $dest && $FORCE == 0 ]]; then warn "exists, left alone: $2 (use --force to overwrite)"; return 0; fi
  render_template "$HS_ROOT/templates/repo/$1"
  mkdir -p "$(dirname "$dest")"
  printf '%s' "$RENDERED" >"$dest"
  ok "wrote $2"
}
write AGENTS.md.tpl AGENTS.md
if [[ $WORKFLOWS == 1 ]]; then
  write workflows/test.yml.tpl .github/workflows/test.yml
  write workflows/release.yml.tpl .github/workflows/release.yml
fi
cat <<MSG

Next, with YOUR account (not the machine account):
  cd $target && git switch -c add-agent-rules && git add AGENTS.md .github && git commit -m "Add agent rules and CI" && git push -u origin HEAD
Then merge it, and on GitHub: Settings > Rules > the 'main' ruleset > Require status checks > add the 'test' job.
Check that the repo's 'make'-style commands really work from a clean clone; CI runs exactly these.
MSG
