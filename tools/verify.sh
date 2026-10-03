#!/usr/bin/env bash
# TITLE: Final checks (the guide's Step 33 table, automated where a machine can judge)
# RUN-AS: admin
# GUIDE: Step 33
# NEEDS: LAPTOP_IP DESKTOP_IP AGENT_USER DASHBOARD_PORT DESKTOP_MODEL_ALIAS LAPTOP_MODEL_ALIAS LLM_PORT NIGHT_ENABLED V100_ENABLED V100_PORT V100_MODEL_ALIAS
# Options (asked when not given): --models | --no-models (the two tool-call smoke tests can take a few minutes)
# Prints PASS / FAIL / WARN / MANUAL per check. Exit status is 1 if anything FAILED.
set -Euo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
MODELS=''
for a in "$@"; do
  case $a in
    --no-models) MODELS=0 ;;
    --models) MODELS=1 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
ask_flag MODELS "Run the tool-call smoke test on both models? (can take a few minutes)" y

npass=0 nfail=0 nwarn=0 nmanual=0
res() { # res pass|fail|warn|manual "check" ["detail"]
  local tag col
  case $1 in
    pass) tag=PASS col=$_c_green; npass=$((npass + 1)) ;;
    fail) tag=FAIL col=$_c_red; nfail=$((nfail + 1)) ;;
    warn) tag=WARN col=$_c_yellow; nwarn=$((nwarn + 1)) ;;
    *) tag=MANUAL col=$_c_blue; nmanual=$((nmanual + 1)) ;;
  esac
  printf '%s%-6s%s #%-3s %s%s\n' "$col" "$tag" "$_c_off" "$2" "$3" "${4:+  - $4}"
}
check() { # check N "label" cmd...   (cmd succeeds => pass)
  local n=$1 label=$2; shift 2
  if "$@" >/dev/null 2>&1; then res pass "$n" "$label"; else res fail "$n" "$label"; fi
}
is_eq() { # is_eq ACTUAL EXPECTED N "label" [failtag] [detail]  - equal passes, otherwise records failtag (default fail)
  local detail=${6:-}
  [[ -n $detail ]] || detail="got \"$1\""
  if [[ $1 == "$2" ]]; then res pass "$3" "$4"; else res "${5:-fail}" "$3" "$4" "$detail"; fi
}
http_code() { curl -s -m 8 -o /dev/null -w '%{http_code}' "$@" || true; }

echo "== Laptop"
gpu=$(nvidia-smi 2>&1 || true)
if grep -q 'GTX 1070' <<<"$gpu" && grep -qE 'Driver Version: 550\.' <<<"$gpu"; then res pass 1 "nvidia-smi: GTX 1070 on a 550-series driver"; else res fail 1 "nvidia-smi: GTX 1070 on a 550-series driver" "$(head -1 <<<"$gpu")"; fi

if agent_exec 'sudo -n true' >/dev/null 2>&1; then res pass 2 "$AGENT_USER has passwordless sudo"; else res fail 2 "$AGENT_USER has passwordless sudo"; fi
res manual 2 "dashboard Config page shows approval mode OFF"
res manual 3 "pushing to main and deleting a v* tag are rejected" "run: ./setup.sh tool github-smoke-test"

if agent_exec 'hermes doctor' >/dev/null 2>&1; then res pass 4 "hermes doctor"; else res fail 4 "hermes doctor" "run it as $AGENT_USER to see the errors"; fi
if agent_exec 'hermes -p local doctor' >/dev/null 2>&1; then res pass 4 "local profile doctor"; else res fail 4 "local profile doctor"; fi

st=$(curl -fsS -m 5 "http://127.0.0.1:$DASHBOARD_PORT/api/status" 2>/dev/null || true)
if [[ -n $st ]]; then res pass 5 "dashboard answers on 127.0.0.1:$DASHBOARD_PORT"; else res fail 5 "dashboard answers on 127.0.0.1:$DASHBOARD_PORT"; fi
gw=$(agent_exec 'hermes gateway status' 2>&1 || true)
if grep -qi running <<<"$gw"; then res pass 5 "gateway running"; else res fail 5 "gateway running"; fi
binds=$(ss -tln 2>/dev/null | awk -v p=":$DASHBOARD_PORT" '$4 ~ p"$" {print $4}')
if [[ -n $binds ]] && ! grep -qvE '^127\.0\.0\.1:' <<<"$binds"; then res pass 6 "dashboard listens on loopback only ($binds)"; else res fail 6 "dashboard listens on loopback only" "${binds:-not listening}"; fi
res manual 6 "http://$LAPTOP_IP:$DASHBOARD_PORT from a phone must NOT load"
res manual 7 "parallel subagent task leaves the main checkout clean" "guide Step 12"
res manual 8 "an agent PR body has test output and the review summary"

echo "== Models"
ids=$(curl -s -m 5 "http://127.0.0.1:$LLM_PORT/v1/models" | jq -r '.data[].id' 2>/dev/null || true)
if [[ $ids == "$LAPTOP_MODEL_ALIAS" ]]; then res pass 9 "laptop serves $LAPTOP_MODEL_ALIAS"; else res fail 9 "laptop serves $LAPTOP_MODEL_ALIAS" "got '${ids:-nothing}'"; fi
key=$("${SUDO[@]}" grep -hE '^DESKTOP_LLM_KEY=' "$AGENT_HOME/.hermes/.env" 2>/dev/null | cut -d= -f2- || true)
dcode=$(http_code -H "Authorization: Bearer $key" "http://$DESKTOP_IP:$LLM_PORT/health")
if [[ $MODELS == 1 ]]; then
  if tool_call_smoke "http://127.0.0.1:$LLM_PORT" "$LAPTOP_MODEL_ALIAS"; then res pass 9 "laptop answers with a tool call"; else res fail 9 "laptop answers with a tool call" "is the server running with --jinja?"; fi
  if [[ $dcode == 200 ]]; then
    if tool_call_smoke "http://$DESKTOP_IP:$LLM_PORT" "$DESKTOP_MODEL_ALIAS" "$key"; then res pass 9 "desktop answers with a tool call"; else res fail 9 "desktop answers with a tool call"; fi
  else
    res warn 9 "desktop tool-call test skipped" "desktop health returned '$dcode' (is it on?)"
  fi
else
  res manual 9 "tool-call smoke test on both models" "re-run without --no-models"
fi
if [[ ${V100_ENABLED:-0} == 1 ]]; then
  vcode=$(http_code -H "Authorization: Bearer $key" "http://$DESKTOP_IP:$V100_PORT/health")
  is_eq "$vcode" 200 9 "V100 model port reachable" warn "got \"$vcode\" - fine if the desktop is off"
  if [[ $MODELS == 1 && $vcode == 200 ]]; then
    if tool_call_smoke "http://$DESKTOP_IP:$V100_PORT" "$V100_MODEL_ALIAS" "$key"; then res pass 9 "V100 model answers with a tool call"; else res fail 9 "V100 model answers with a tool call"; fi
  fi
fi
fb=$(agent_exec 'hermes fallback list' 2>&1 || true)
o=$(grep -n openrouter <<<"$fb" | head -1 | cut -d: -f1); d=$(grep -n desktop <<<"$fb" | head -1 | cut -d: -f1); l=$(grep -n laptop <<<"$fb" | head -1 | cut -d: -f1)
away=0
if agent_exec "test -e \"\$HOME/.hermes/desktop-away\"" >/dev/null 2>&1; then away=1; fi
if ((away)); then
  # the desktop was taken out of the loop on purpose (hermes-desktop off): the chain must then be OpenRouter, laptop
  if [[ -n $o && -n $l && -z $d && $o -lt $l ]]; then res warn 10 "fallback chain: the desktop is OUT of the loop (OpenRouter, then laptop)" "hermes-desktop on puts it back"
  else res fail 10 "fallback chain while the desktop is away: OpenRouter, then laptop only"; fi
elif [[ -n $o && -n $d && -n $l && $o -lt $d && $d -lt $l ]]; then res pass 10 "fallback chain: OpenRouter, then desktop, then laptop"
else res fail 10 "fallback chain: OpenRouter, then desktop, then laptop"; fi

ms=$(agent_exec 'hermes-mode status' 2>&1 || true)
code_of() { grep -E "^$1 " <<<"$ms" | sed 's/.*: *//' | tr -d '[:space:]'; }
is_eq "$(code_of laptop)" 200 11 "hermes-mode: laptop 200"
is_eq "$(code_of desktop)" 200 11 "hermes-mode: desktop 200" warn "fine if the desktop is off"
if [[ ${V100_ENABLED:-0} == 1 ]]; then is_eq "$(code_of desktop-v100)" 200 11 "hermes-mode: desktop-v100 200" warn "fine if the desktop is off"; fi
is_eq "$(code_of openrouter)" 200 11 "hermes-mode: openrouter 200"
res manual 12 "hermes-mode local / cloud round trip" "answer from $DESKTOP_MODEL_ALIAS, then cloud restored"
res manual 13 "/model custom:laptop:$LAPTOP_MODEL_ALIAS mid-session"
res manual 14 "internet-off fallback" "run: ./setup.sh tool fallback-test"
res manual 15 "/release round trip in a test repo"

if agent_exec 'hermes cron status' >/dev/null 2>&1; then res pass 16 "hermes cron status"; else res fail 16 "hermes cron status"; fi
if agent_exec 'hermes cron doctor' >/dev/null 2>&1; then res pass 16 "hermes cron doctor exits 0"; else res fail 16 "hermes cron doctor exits 0"; fi
if [[ ${NIGHT_ENABLED:-0} == 1 ]]; then
  if agent_exec 'hermes -p local cron doctor' >/dev/null 2>&1; then res pass 16 "local cron doctor exits 0"; else res fail 16 "local cron doctor exits 0"; fi
fi

echo "== Firewall"
is_eq "$(http_code https://openrouter.ai/api/v1/models)" 200 17 "outbound 443 works (OpenRouter 200)"
is_eq "$dcode" 200 17 "desktop model port reachable" warn
if timeout 3 bash -c "(exec 3<>/dev/tcp/$DESKTOP_IP/445)" 2>/dev/null; then res fail 17 "desktop port 445 is BLOCKED"; else res pass 17 "desktop port 445 is BLOCKED"; fi
check 17 "DNS resolves (deb.debian.org)" getent hosts deb.debian.org
is_eq "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" yes 17 "NTP synchronized"

echo "== Ready to come back after a reboot (check 18 itself needs a real reboot)"
check 18 "llama-server is enabled at boot" "${SUDO[@]}" systemctl is-enabled llama-server
linger=$(loginctl show-user "$AGENT_USER" -p Linger 2>/dev/null || true)
if [[ $linger == 'Linger=yes' ]]; then res pass 18 "linger is on for $AGENT_USER"; else res fail 18 "linger is on for $AGENT_USER"; fi
if agent_exec 'systemctl --user is-enabled hermes-dashboard' >/dev/null 2>&1; then res pass 18 "dashboard unit is enabled"; else res fail 18 "dashboard unit is enabled"; fi
check 18 "ufw is enabled" "${SUDO[@]}" systemctl is-enabled ufw
res manual 18 "reboot the laptop, do NOT log in as $AGENT_USER, then repeat checks 5, 11 and 16"
[[ ${NIGHT_ENABLED:-0} == 1 ]] && res manual 19 "the morning after an overnight job: completed run, draft PR, desktop back on $DESKTOP_MODEL_ALIAS"

echo
printf 'PASS %d   FAIL %d   WARN %d   MANUAL %d\n' "$npass" "$nfail" "$nwarn" "$nmanual"
[[ $nfail -eq 0 ]]
