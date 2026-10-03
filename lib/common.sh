# shellcheck shell=bash
# Shared helpers for the HarnessSetup scripts. Source this file, do not run it.
#
# Environment switches (all optional):
#   DRY_RUN=1      print mutating commands instead of running them
#   DESTDIR=/path  prefix for every file written by put_file (for tests)
#   ASSUME_YES=1   answer yes to confirm() prompts
#   NODE_ENV=file  settings file (default: config/node.env)

if [[ -n ${HS_COMMON_LOADED:-} ]]; then return 0; fi
HS_COMMON_LOADED=1

HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DRY_RUN=${DRY_RUN:-0}
DESTDIR=${DESTDIR:-}
ASSUME_YES=${ASSUME_YES:-0}
# Where the repo is published for the agent user (it cannot read the admin's home).
HS_SHARED=${HS_SHARED:-/opt/harness-setup}

if [[ -t 2 ]]; then
  _c_blue=$'\033[1;34m' _c_green=$'\033[1;32m' _c_yellow=$'\033[1;33m' _c_red=$'\033[1;31m' _c_off=$'\033[0m'
else
  _c_blue='' _c_green='' _c_yellow='' _c_red='' _c_off=''
fi

log()  { printf '%s==>%s %s\n' "$_c_blue" "$_c_off" "$*" >&2; }
ok()   { printf '%s ok%s %s\n' "$_c_green" "$_c_off" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$_c_yellow" "$_c_off" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then SUDO=(); else SUDO=(sudo); fi

# run CMD...  - run a mutating command, or print it under DRY_RUN=1
run() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '[dry-run]' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

# sudo_run CMD...  - run() with root privileges
sudo_run() { run "${SUDO[@]}" "$@"; }

# fail_or_warn MSG  - a hard failure normally, only a warning in a dry run
fail_or_warn() {
  if [[ $DRY_RUN == 1 ]]; then warn "$* (ignored in dry run)"; else die "$*"; fi
}

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail_or_warn "required command not found: $c"
  done
}

confirm() { # confirm "Question?"  - default no
  local ans
  if [[ $ASSUME_YES == 1 ]]; then return 0; fi
  if [[ ! -r /dev/tty ]]; then die "need an answer to '$1' but there is no terminal; re-run with --yes"; fi
  read -r -p "$1 [y/N] " ans </dev/tty
  [[ $ans == [yY] || $ans == [yY][eE][sS] ]]
}

# ---- settings ---------------------------------------------------------------

# require_vars VAR...  - every variable must be set, non-empty and not a <placeholder>
require_vars() {
  local v bad=()
  for v in "$@"; do
    if [[ -z ${!v:-} || ${!v} == *'<'* || ${!v} == *CHANGEME* ]]; then bad+=("$v"); fi
  done
  if ((${#bad[@]})); then
    die "set these in ${NODE_ENV_FILE:-config/node.env}: ${bad[*]}"
  fi
}

load_config() {
  NODE_ENV_FILE=${NODE_ENV:-$HS_ROOT/config/node.env}
  [[ -f $NODE_ENV_FILE ]] || die "missing $NODE_ENV_FILE - run: cp config/node.env.example config/node.env  (then edit it)"
  set -a
  # shellcheck disable=SC1090
  source "$NODE_ENV_FILE"
  set +a
  require_vars LAPTOP_IP DESKTOP_IP ROUTER_IP LAN_CIDR ADMIN_USER AGENT_USER SSH_ALLOWED_FROM \
    DASHBOARD_PORT LLM_PORT LAPTOP_MODEL_ALIAS LAPTOP_MODEL_FILE LAPTOP_MODEL_URL LAPTOP_CTX \
    DESKTOP_MODEL_ALIAS DESKTOP_CTX
  # Derived values used by templates
  AGENT_HOME=/home/$AGENT_USER
  HERMES_BIN_DIR=$AGENT_HOME/.local/bin
  HERMES_BIN=$HERMES_BIN_DIR/hermes
  LAPTOP_NKVO_FLAG=''
  [[ ${LAPTOP_KV_IN_RAM:-1} == 1 ]] && LAPTOP_NKVO_FLAG='-nkvo'
  CRON_REPO=${GITHUB_REPOS%% *}
  export AGENT_HOME HERMES_BIN_DIR HERMES_BIN LAPTOP_NKVO_FLAG CRON_REPO
}

# ---- templates --------------------------------------------------------------

# render_template SRC  - expand @@VAR@@ tokens from the environment into $RENDERED.
# Runs in the current shell (no subshell) so a missing variable stops the script.
render_template() {
  local src=$1 tok name val
  local -a missing=()
  [[ -f $src ]] || die "template not found: $src"
  shopt -u patsub_replacement 2>/dev/null || true
  RENDERED=$(cat "$src"; printf x)
  RENDERED=${RENDERED%x}
  while IFS= read -r tok; do
    [[ -n $tok ]] || continue
    name=${tok//@/}
    if [[ -z ${!name+x} ]]; then missing+=("$name"); continue; fi
    val=${!name}
    RENDERED=${RENDERED//"$tok"/"$val"}
  done < <(grep -o '@@[A-Z0-9_]\+@@' "$src" | sort -u || true)
  if ((${#missing[@]})); then die "template $src uses undefined variables: ${missing[*]}"; fi
}

# put_file DEST [MODE] [OWNER:GROUP]  - write stdin to DEST (as root unless already root)
put_file() {
  local dest=$1 mode=${2:-644} owner=${3:-root:root} target tmp
  target=${DESTDIR}${dest}
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ $DRY_RUN == 1 ]]; then
    log "[dry-run] would write $target (mode $mode, owner $owner)"
    [[ ${DRY_RUN_SHOW:-0} == 1 ]] && sed 's/^/    | /' "$tmp" >&2
    rm -f "$tmp"
    return 0
  fi
  if [[ -n $DESTDIR ]]; then
    install -D -m "$mode" "$tmp" "$target"
  else
    "${SUDO[@]}" install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$target"
  fi
  rm -f "$tmp"
}

# install_template SRC DEST [MODE] [OWNER:GROUP]
install_template() {
  local src=$1
  shift
  render_template "$src"
  printf '%s' "$RENDERED" | put_file "$@"
  ok "wrote ${DESTDIR}$1"
}

# ---- downloads --------------------------------------------------------------

# download_gguf URL DEST  - resumable; refuses HTML error pages saved as a model
download_gguf() {
  local url=$1 dest=$2 magic
  if [[ -f $dest ]] && [[ $(head -c4 "$dest") == GGUF ]]; then
    ok "already downloaded: $dest"
    return 0
  fi
  log "downloading $(basename "$dest") (large; resumes if interrupted)"
  run curl --fail --location --retry 5 --retry-delay 5 --continue-at - --output "$dest" "$url"
  [[ $DRY_RUN == 1 ]] && return 0
  magic=$(head -c4 "$dest" || true)
  [[ $magic == GGUF ]] || die "$dest is not a GGUF file. Check the exact file name on the repo's Files tab."
}

# ---- stage bookkeeping ------------------------------------------------------

# stage_meta KEY  - read a "# KEY: value" header from the running script
stage_meta() { sed -n "s/^# $1: *//p" "${HS_SCRIPT:-$0}" | head -1; }

stage_id() { basename "${HS_SCRIPT:-$0}" | cut -d- -f1; }

stage_marker_dir() {
  if [[ $(stage_meta RUN-AS) == hermes ]]; then
    printf '%s\n' "${HOME}/.harness-setup/done"
  else
    printf '%s\n' "${DESTDIR}/var/lib/harness-setup/done"
  fi
}

mark_done() {
  [[ $DRY_RUN == 1 ]] && return 0
  local d
  d=$(stage_marker_dir)
  if [[ $(stage_meta RUN-AS) == hermes ]]; then
    mkdir -p "$d" && date -u +%FT%TZ >"$d/$(stage_id)"
  else
    "${SUDO[@]}" mkdir -p "$d" && date -u +%FT%TZ | "${SUDO[@]}" tee "$d/$(stage_id)" >/dev/null
  fi
}

# stage_begin  - banner, plus a guard that the script runs as the right user
stage_begin() {
  local who title
  who=$(stage_meta RUN-AS)
  title=$(stage_meta TITLE)
  log "Stage $(stage_id): $title  [$(stage_meta GUIDE)]"
  case $who in
    hermes)
      [[ $(id -un) == "${AGENT_USER:-hermes}" || $DRY_RUN == 1 ]] ||
        die "this stage runs as the agent user. Use: ./setup.sh run $(stage_id)"
      ;;
    admin)
      [[ $(id -un) != "${AGENT_USER:-hermes}" ]] ||
        die "this stage runs as the admin user, not '${AGENT_USER:-hermes}'. Use: ./setup.sh run $(stage_id)"
      ;;
  esac
}

stage_end() {
  mark_done
  ok "stage $(stage_id) complete"
}

# Make the agent's tools visible in non-login shells
use_hermes_path() { export PATH="$HOME/.local/bin:$PATH"; }
