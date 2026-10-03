#!/usr/bin/env bash
# TITLE: Build tools, Node.js 22, GitHub CLI
# RUN-AS: admin
# GUIDE: Step 7
# Options: --docker (also install Docker and add the agent user to the docker group)
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
DOCKER=0
for a in "$@"; do
  case $a in
    --docker) DOCKER=1 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
stage_begin
APT=(env DEBIAN_FRONTEND=noninteractive apt-get -y)

sudo_run "${APT[@]}" install git build-essential cmake curl ca-certificates jq pciutils \
  python3 python3-venv python3-pip python3-yaml libcurl4-openssl-dev ufw

node_major=$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)
if [[ ${node_major:-0} -ge 22 ]]; then
  ok "Node.js $(node -v) already installed"
else
  log "Node.js 22 (the dashboard's Chat tab runs the Hermes TUI, which needs it)"
  run bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | ${SUDO[*]} -E bash -"
  sudo_run "${APT[@]}" install nodejs
fi

if command -v gh >/dev/null 2>&1; then
  ok "GitHub CLI already installed"
else
  log "GitHub CLI from GitHub's own repository"
  sudo_run mkdir -p -m 755 /etc/apt/keyrings
  run bash -c "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | ${SUDO[*]} tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null"
  sudo_run chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  arch=$(dpkg --print-architecture)
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
    put_file /etc/apt/sources.list.d/github-cli.list 644
  sudo_run apt-get update
  sudo_run "${APT[@]}" install gh
fi

if [[ $DOCKER == 1 ]]; then
  sudo_run "${APT[@]}" install docker.io
  sudo_run usermod -aG docker "$AGENT_USER"
fi

if [[ $DRY_RUN != 1 ]]; then
  v=$(node -v | sed -E 's/^v([0-9]+).*/\1/')
  [[ $v -ge 22 ]] || die "node is v$v, need 22 or later"
  gh --version | head -1
  git --version
fi
stage_end
cat <<MSG
Also install the toolchains your projects need to build and test (language runtimes, compilers,
databases). The agent can 'sudo apt install' the rest itself and lists them in each PR.
Next: do the GitHub web steps in docs/RUNBOOK.md (machine account, rulesets, token), then:  ./setup.sh run 05
MSG
