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

# run_as USER CMD...  - run() as another user (runuser when already root, sudo -u otherwise)
run_as() {
  local user=$1
  shift
  if [[ $EUID -eq 0 ]]; then run runuser -u "$user" -- "$@"; else run sudo -u "$user" "$@"; fi
}

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

confirm() { # confirm "Question?"  - default no; --yes answers yes
  if [[ $ASSUME_YES == 1 ]]; then return 0; fi
  if [[ -z ${HS_INPUT:-} ]] && ! _hs_tty_ok; then die "need an answer to '$1' but there is no terminal; re-run with --yes"; fi
  read_answer "$1 [y/N] "
  [[ ${ANSWER,,} == y || ${ANSWER,,} == yes ]]
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
  [[ -f $NODE_ENV_FILE ]] || die "no settings yet ($NODE_ENV_FILE). Run: ./setup.sh configure   (it asks for them)"
  set -a
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$NODE_ENV_FILE")   # tolerate a file saved with Windows line endings
  set +a
  cfg_apply_defaults
  # only what every stage uses; a stage that needs more (the firewall: ROUTER_IP, LAN_CIDR) says so itself
  require_vars LAPTOP_IP DESKTOP_IP ADMIN_USER AGENT_USER DASHBOARD_PORT LLM_PORT \
    LAPTOP_MODEL_ALIAS LAPTOP_MODEL_FILE LAPTOP_MODEL_URL LAPTOP_CTX DESKTOP_MODEL_ALIAS DESKTOP_CTX
  # Derived values used by templates
  AGENT_HOME=/home/$AGENT_USER
  HERMES_BIN_DIR=$AGENT_HOME/.local/bin
  HERMES_BIN=$HERMES_BIN_DIR/hermes
  LAPTOP_NKVO_FLAG=''
  [[ ${LAPTOP_KV_IN_RAM:-1} == 1 ]] && LAPTOP_NKVO_FLAG='-nkvo'
  # model-specific request defaults ('auto' = the kit's values for the Qwen3.5 model it ships; 'none' = nothing)
  local kw=${LAPTOP_CHAT_KWARGS:-auto}
  [[ $kw == auto ]] && kw=enable_thinking=true
  LAPTOP_KWARGS_FLAG=''
  # shellcheck disable=SC2089  # text for the systemd unit (rendered into ExecStart), never word-split by this shell
  [[ $kw == none ]] || LAPTOP_KWARGS_FLAG="--chat-template-kwargs '$(cfg_kwargs_json "$kw")'"
  LAPTOP_SAMPLING_FLAGS=${LAPTOP_SAMPLING:-auto}
  [[ $LAPTOP_SAMPLING_FLAGS == auto ]] && LAPTOP_SAMPLING_FLAGS='--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0'
  [[ $LAPTOP_SAMPLING_FLAGS == none ]] && LAPTOP_SAMPLING_FLAGS=''
  CRON_REPO=${GITHUB_REPOS:-}
  CRON_REPO=${CRON_REPO%% *}
  # shellcheck disable=SC2090  # see above
  export AGENT_HOME HERMES_BIN_DIR HERMES_BIN LAPTOP_NKVO_FLAG LAPTOP_KWARGS_FLAG LAPTOP_SAMPLING_FLAGS CRON_REPO
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
  if [[ -n $DESTDIR || $owner == self ]]; then
    install -D -m "$mode" "$tmp" "$target"   # owner "self": a file in the caller's own home, no sudo
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

# download_gguf URL DEST [USER]  - resumable; refuses HTML error pages saved as a model
download_gguf() {
  local url=$1 dest=$2 user=${3:-} magic
  if [[ -f $dest ]] && [[ $(head -c4 "$dest") == GGUF ]]; then
    ok "already downloaded: $dest"
    return 0
  fi
  log "downloading $(basename "$dest") (large; resumes if interrupted)"
  if [[ -n $user ]]; then runner=(run_as "$user"); else runner=(run); fi
  "${runner[@]}" curl --fail --location --retry 5 --retry-delay 5 --continue-at - --output "$dest" "$url"
  [[ $DRY_RUN == 1 ]] && return 0
  magic=$(head -c4 "$dest" || true)
  [[ $magic == GGUF ]] || die "$dest is not a GGUF file. Check the exact file name on the repo's Files tab."
}

# wait_http URL SECONDS  - poll until URL answers 2xx
wait_http() {
  local url=$1 secs=$2 i
  for ((i = 0; i < secs; i += 3)); do
    curl -fsS -m 3 -o /dev/null "$url" 2>/dev/null && return 0
    sleep 3
  done
  return 1
}

# tool_call_smoke BASE_URL MODEL [API_KEY]  - succeeds only if the model answers with a get_weather tool call
# (the guide's Step 20 check: a server started without --jinja answers in prose instead)
tool_call_smoke() {
  local base=$1 model=$2 key=${3:-} resp
  local -a auth=()
  [[ -n $key ]] && auth=(-H "Authorization: Bearer $key")
  resp=$(curl -s -m 300 "${auth[@]}" "$base/v1/chat/completions" -H 'Content-Type: application/json' -d "{
    \"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Weather in Paris?\"}],
    \"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"parameters\":{\"type\":\"object\",
    \"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}]}") || return 1
  jq -e '.choices[0].message.tool_calls[0].function.name == "get_weather"' <<<"$resp" >/dev/null 2>&1
}

# set_env_var FILE KEY VALUE  - set KEY=VALUE in a dotenv file, keeping it mode 600
set_env_var() {
  local file=$1 key=$2 val=$3
  [[ $DRY_RUN == 1 ]] && { log "[dry-run] would set $key in $file"; return 0; }
  mkdir -p "$(dirname "$file")"
  touch "$file" && chmod 600 "$file"
  if grep -q "^$key=" "$file"; then
    local tmp; tmp=$(mktemp)
    grep -v "^$key=" "$file" >"$tmp" || true
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
    cat "$tmp" >"$file" && rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >>"$file"
  fi
}

# agent_exec "COMMAND"  - run a shell command as the agent user in a real login session (machinectl) and
# return its exit status. machinectl does not reliably pass the status through, so the command echoes it.
# HS_AGENT_RUNNER=script is the test seam: it receives the command string instead.
agent_exec() {
  local cmd=$1 out rc
  if [[ -n ${HS_AGENT_RUNNER:-} ]]; then "$HS_AGENT_RUNNER" "$cmd"; return; fi
  out=$("${SUDO[@]}" machinectl -q shell "$AGENT_USER@" /bin/bash -c "export PATH=\$HOME/.local/bin:\$PATH; $cmd; echo __RC=\$?" 2>&1 | tr -d '\r') || true
  rc=$(sed -n 's/^__RC=//p' <<<"$out" | tail -1)
  grep -v '^__RC=' <<<"$out" || true
  return "${rc:-1}"
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
      [[ $(id -un) == "${AGENT_USER:-hermes}" || $DRY_RUN == 1 || ${HS_ALLOW_ANY_USER:-0} == 1 ]] ||
        die "this stage runs as the agent user. Use: ./setup.sh run $(stage_id)"
      # the real home of whoever runs this (templates paths, e.g. the cron clone)
      AGENT_HOME=$HOME
      export AGENT_HOME
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

# user_bus_env  - `sudo -u USER` is not a login session, so XDG_RUNTIME_DIR is unset: point systemctl --user at the
# user manager that linger keeps running (HS_RUN_USER_DIR is the test seam)
user_bus_env() {
  local dir=${HS_RUN_USER_DIR:-/run/user/$(id -u)}
  if [[ -z ${XDG_RUNTIME_DIR:-} && -d $dir ]]; then export XDG_RUNTIME_DIR=$dir; fi
  if [[ -n ${XDG_RUNTIME_DIR:-} && -z ${DBUS_SESSION_BUS_ADDRESS:-} && -S $XDG_RUNTIME_DIR/bus ]]; then
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
  fi
}

# need_user_session  - systemctl --user needs the login session machinectl provides (or the lingering user manager)
need_user_session() {
  user_bus_env
  [[ -n ${XDG_RUNTIME_DIR:-} || $DRY_RUN == 1 ]] ||
    die "no user session bus. Run this through ./setup.sh (it uses machinectl), not 'sudo -iu'."
}

# common_flag ARG  - handle the flags every stage shares; returns 1 if ARG is not one of them
common_flag() {
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    *) return 1 ;;
  esac
}

# publish_shared  - copy the repo (with your config/node.env) to $HS_SHARED so the
# agent user, which cannot read the admin's home directory, can run its stages.
publish_shared() {
  log "publishing $HS_ROOT -> $HS_SHARED for the agent user"
  [[ $DRY_RUN == 1 ]] && { warn "[dry-run] skipped"; return 0; }
  local nf=${NODE_ENV:-$HS_ROOT/config/node.env} new="$HS_SHARED.new" old="$HS_SHARED.old"
  # build the new copy beside the old one, then swap, so a failed copy never leaves the agent without a kit
  "${SUDO[@]}" rm -rf "$new" "$old"
  "${SUDO[@]}" install -d -m 755 "$new" || die "cannot create $new"
  tar -C "$HS_ROOT" --exclude=.git -cf - . | "${SUDO[@]}" tar -C "$new" --no-same-owner -xf - || die "could not copy the kit to $new"
  if [[ -f $nf ]]; then "${SUDO[@]}" install -D -m 644 "$nf" "$new/config/node.env" || die "could not copy the settings to $new"; fi
  "${SUDO[@]}" chmod -R a+rX,go-w "$new"
  if [[ -e $HS_SHARED ]]; then "${SUDO[@]}" mv "$HS_SHARED" "$old"; fi
  "${SUDO[@]}" mv "$new" "$HS_SHARED" || die "could not put the new kit in place at $HS_SHARED"
  "${SUDO[@]}" rm -rf "$old"
}

# shellcheck source=lib/config.sh
source "$HS_ROOT/lib/config.sh"

# shellcheck source=lib/chain.sh
source "$HS_ROOT/lib/chain.sh"
