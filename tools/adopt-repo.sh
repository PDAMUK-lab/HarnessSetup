#!/usr/bin/env bash
# Add AGENTS.md and the CI workflows to one of your repos (the agent's token cannot push workflows,
# so YOU commit these, once per repo, with your own account).
#
#   tools/adopt-repo.sh PATH --install 'npm ci' --test 'npm test' --package 'npm pack' \
#                       [--lint 'npm run lint'] [--version-file package.json] [--force] [--no-workflows]
#
# Anything you leave out is asked for, with a guess based on the project (package.json, pyproject.toml,
# Cargo.toml, go.mod, Makefile). Works on any machine with bash (the desktop's Git Bash is fine).
# Existing files are never overwritten unless you pass --force.
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
if [[ -z $target ]]; then
  is_interactive || die "usage: tools/adopt-repo.sh PATH --install CMD --test CMD --package CMD  (--help for more)"
  ask_text target "Path of the repository to adopt" "$PWD"
fi
[[ -d $target/.git ]] || die "$target is not a git repository"

# a guess from the project type, offered as the default for each question
d_install='' d_test='' d_lint='' d_package='' d_version=VERSION
if [[ -f $target/package.json ]]; then
  d_install='npm ci' d_test='npm test' d_lint='npm run lint' d_package='npm pack' d_version=package.json
elif [[ -f $target/pyproject.toml || -f $target/setup.py ]]; then
  d_install='pip install -e .[dev]' d_test='pytest -q' d_lint='ruff check .' d_package='python -m build' d_version=pyproject.toml
elif [[ -f $target/Cargo.toml ]]; then
  d_install='cargo fetch' d_test='cargo test' d_lint='cargo clippy' d_package='cargo build --release' d_version=Cargo.toml
elif [[ -f $target/go.mod ]]; then
  d_install='go mod download' d_test='go test ./...' d_lint='go vet ./...' d_package='go build ./...'
elif [[ -f $target/Makefile ]]; then
  d_install='make install' d_test='make test' d_package='make dist'
fi
ask_text INSTALL_CMD "Install command (CI and the agent run it first)" "$d_install"
ask_text TEST_CMD "Test command (must pass before any push)" "$d_test"
ask_text LINT_CMD "Lint command (or none)" "${d_lint:-none}"
ask_text PACKAGE_CMD "Package command (what CI publishes into dist/)" "$d_package"
ask_text VERSION_FILE "File that holds the version" "$d_version"
[[ -n $INSTALL_CMD && -n $TEST_CMD && -n $PACKAGE_CMD ]] || die "an install, a test and a package command are required (--install, --test, --package)"
export INSTALL_CMD TEST_CMD LINT_CMD PACKAGE_CMD VERSION_FILE
# the commands are substituted literally; refuse text that would break the generated files
for v in INSTALL_CMD TEST_CMD LINT_CMD PACKAGE_CMD; do
  [[ ${!v} != *@@* && ${!v} != *$'\n'* && ${!v} != *$'\r'* ]] || die "$v must be a single line without '@@'"
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
