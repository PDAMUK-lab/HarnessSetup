#!/usr/bin/env bash
# Schema, validators and the interactive wizard (driven by scripted answers, like a user typing).
# shellcheck disable=SC2016  # literal $ and backticks are the point of some tests
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
has() { grep -qF -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
val() { bash -c "set -a; source '$1'; printf '%s' \"\${$2-<unset>}\""; }   # value of KEY as bash sees the file
export ASSUME_YES=0
unset SSH_CLIENT

# =============================== schema integrity
cfg_schema_load
check "schema has settings" test "${#CFG_KEYS[@]}" -gt 40
nbad=0
for k in "${CFG_KEYS[@]}"; do
  [[ ${CFG_SCOPE[$k]} =~ ^(both|laptop|desktop)$ ]] || { echo "  $k: bad scope"; nbad=1; }
  [[ ${CFG_LEVEL[$k]} =~ ^(basic|advanced)$ ]] || { echo "  $k: bad level"; nbad=1; }
  [[ -n ${CFG_PROMPT[$k]} && -n ${CFG_HELP[$k]} && -n ${CFG_GROUP[$k]} ]] || { echo "  $k: missing prompt/help/group"; nbad=1; }
  cfg_validate "${CFG_TYPE[$k]}" "x" >/dev/null 2>&1; [[ $CFG_ERR != unknown* ]] || { echo "  $k: unknown type ${CFG_TYPE[$k]}"; nbad=1; }
done
check "every schema line is well formed" test $nbad -eq 0
check "no duplicate keys" test "$(printf '%s\n' "${CFG_KEYS[@]}" | sort | uniq -d | wc -l)" -eq 0
order_ok() { # a derived default may only refer to keys that come earlier
  local seen=' ' k r
  for k in "${CFG_KEYS[@]}"; do
    for r in $(grep -o '{[A-Z0-9_]*}' <<<"${CFG_DEFAULT[$k]}" | tr -d '{}'); do [[ $seen == *" $r "* ]] || { echo "  $k refers to later key $r"; return 1; }; done
    seen+="$k "
  done
}
check "derived defaults refer only to earlier settings" order_ok

# the shipped example agrees with the schema
cfg_reset_values; cfg_parse_env "$ROOT/config/node.env.example"
exk=$(grep -oE '^[A-Z0-9_]+=' "$ROOT/config/node.env.example" | tr -d = | sort)
check "example has exactly the schema's keys (plus none extra)" test "$exk" = "$(printf '%s\n' "${CFG_KEYS[@]}" | sort)"
ex_ok() {
  local k d nbad=0
  for k in "${CFG_KEYS[@]}"; do
    cfg_validate "${CFG_TYPE[$k]}" "${CFG_VAL[$k]-}" >/dev/null 2>&1 && continue
    case $k in OR_*|GITHUB_ORG|GITHUB_REPOS|GITHUB_MACHINE_USER|GITHUB_NOREPLY_EMAIL|CRON_MODEL) continue ;; esac   # deliberate placeholders/empties
    echo "  example $k=${CFG_VAL[$k]-} is invalid: $CFG_ERR"; nbad=1
  done
  for k in "${CFG_KEYS[@]}"; do
    d=${CFG_DEFAULT[$k]}; [[ -n $d && $d != auto:* ]] || continue
    [[ ${CFG_VAL[$k]-} == "$(cfg_expand "$d")" ]] || { echo "  example $k=${CFG_VAL[$k]-} differs from the schema default $(cfg_expand "$d")"; nbad=1; }
  done
  return $nbad
}
check "example values are valid and match the schema defaults" ex_ok

# =============================== validators
v() { # v TYPE VALUE EXPECT(ok|bad) [NORM|<empty>]   (empty NORM = not checked)
  local type=$1 val=$2 want=$3 norm=${4-}
  if cfg_validate "$type" "$val" >/dev/null 2>&1; then got=ok; else got=bad; fi
  [[ $got == "$want" ]] || { echo "  $type '$val': wanted $want got $got ($CFG_ERR)"; return 1; }
  if [[ -n $norm ]]; then
    [[ $norm == '<empty>' ]] && norm=''
    [[ $CFG_NORM == "$norm" ]] || { echo "  $type '$val': normalised to '$CFG_NORM', wanted '$norm'"; return 1; }
  fi
}
while IFS='|' read -r vt vv vw vn vwhy; do
  case $vt in '#'* | '') continue ;; esac
  check "validate $vt '$vv': $vwhy" v "$vt" "$vv" "$vw" "$vn"
done <"$ROOT/tests/validator-cases.psv"

check "cfg_time_add: +15" test "$(cfg_time_add 01:00 15)" = 01:15
check "cfg_time_add: -120" test "$(cfg_time_add 07:00 -120)" = 05:00
check "cfg_time_add: wraps past midnight" test "$(cfg_time_add 23:30 75)/$(cfg_time_add 00:10 -30)" = 00:45/23:40
check "cfg_time_words: the scheduler's spelling" test "$(cfg_time_words 02:00)/$(cfg_time_words 01:15)/$(cfg_time_words 12:30)/$(cfg_time_words 00:05)/$(cfg_time_words 23:00)" = 2am/1:15am/12:30pm/12:05am/11pm
check "cfg_net /24"               test "$(cfg_net 192.168.1.150/24)" = 192.168.1.0/24
check "cfg_net /20"               test "$(cfg_net 172.16.37.9/20)" = 172.16.32.0/20

# =============================== the wizard, fed like a user typing
printf '%s\n' \
  300.1.1.1 10.0.0.20 \
  10.0.0.30 \
  10.0.0.1 \
  '' \
  james \
  acme \
  'api  web' \
  '' \
  not-a-noreply 42+acme-hermes@users.noreply.github.com \
  vendor-a/worker vendor-b/reviewer vendor-a/mid vendor-c/fallback \
  2 \
  '' \
  y 2:00 '' \
  n \
  n \
  '' >"$T/ans1"
OUT=$(NODE_ENV="$T/node.env" "$ROOT/setup.sh" configure --answers "$T/ans1" 2>&1); RC=$?
check "wizard: exits 0" test $RC -eq 0
check "wizard: rejects 300.1.1.1 and says why" has "expected an IPv4 address"
check "wizard: rejects a bad noreply address" has "ID+name@users.noreply.github.com"
check "wizard: shows the help text" has "DHCP reservation"
check "wizard: shows choices" has "2) UD-Q4_K_XL"
f=$T/node.env
check "wizard: laptop ip saved"       test "$(val "$f" LAPTOP_IP)" = 10.0.0.20
check "wizard: lan derived from the laptop ip" test "$(val "$f" LAN_CIDR)" = 10.0.0.0/24
check "wizard: admin user saved"      test "$(val "$f" ADMIN_USER)" = james
check "wizard: repos normalised"      test "$(val "$f" GITHUB_REPOS)" = 'api web'
check "wizard: machine user derived from the org" test "$(val "$f" GITHUB_MACHINE_USER)" = acme-hermes
check "wizard: models saved"          test "$(val "$f" OR_REVIEW_MODEL)" = vendor-b/reviewer
check "wizard: quant chosen by number" test "$(val "$f" LAPTOP_QUANT)" = UD-Q4_K_XL
check "wizard: desktop quant default" test "$(val "$f" DESKTOP_QUANT)" = UD-Q5_K_XL
check "wizard: overnight tier on"     test "$(val "$f" NIGHT_ENABLED)" = 1
check "wizard: overnight start padded" test "$(val "$f" NIGHT_START)" = 02:00
check "wizard: overnight end default" test "$(val "$f" NIGHT_END)" = 07:00
check "wizard: derived model file follows the quant (unset in file)" test "$(val "$f" LAPTOP_MODEL_FILE)" = '<unset>'
check "wizard: derived value is documented in a comment" grep -q '# LAPTOP_MODEL_FILE=Qwen3.5-9B-UD-Q4_K_XL.gguf' "$f"
check "wizard: file is world-readable (the agent user reads the published copy)" test "$(stat -c %a "$f")" = 644
loaded() { ( NODE_ENV="$f"; load_config; printf '%s' "${!1}" ); }
check "load_config derives the model file from the quant" test "$(loaded LAPTOP_MODEL_FILE)" = Qwen3.5-9B-UD-Q4_K_XL.gguf
check "load_config derives the download URL too" test "$(loaded LAPTOP_MODEL_URL)" = https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-UD-Q4_K_XL.gguf
check "load_config: SSH_ALLOWED_FROM follows the desktop ip" test "$(loaded SSH_ALLOWED_FROM)" = 10.0.0.30
check "load_config: default ports apply" test "$(loaded DASHBOARD_PORT)/$(loaded LLM_PORT)" = 9119/8080
check "load_config: desktop model derived from its quant" test "$(loaded DESKTOP_MODEL_FILE)" = Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf

# edit session: Enter keeps everything; changing the quant re-derives
# 13 Enters (ip x3, lan, admin, org, repos, machine, noreply, 4 models), then quant=1, Enters for desktop quant/overnight/start/end/V100, n, save
printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' 1 '' '' '' '' '' n '' >"$T/ans2"
cp "$f" "$T/before.env"
OUT=$(NODE_ENV="$f" "$ROOT/setup.sh" configure --answers "$T/ans2" 2>&1); RC=$?
check "edit: exits 0" test $RC -eq 0
check "edit: Enter keeps the laptop ip" test "$(val "$f" LAPTOP_IP)" = 10.0.0.20
check "edit: Enter keeps the models" test "$(val "$f" OR_WORKER_MODEL)" = vendor-a/worker
check "edit: new quant re-derives the model file" test "$(loaded LAPTOP_MODEL_FILE)" = Qwen3.5-9B-UD-Q5_K_XL.gguf

# a hand-copied example: derived values follow a quant change instead of sticking
cp "$ROOT/config/node.env.example" "$T/copy.env"
OUT=$(NODE_ENV="$T/copy.env" "$ROOT/setup.sh" configure --only LAPTOP_QUANT --answers <(printf '2\n') 2>&1); RC=$?
check "copied example: --only exits 0" test $RC -eq 0
check "copied example: the pinned Q5 file is replaced by the Q4 derivation" test "$( ( NODE_ENV="$T/copy.env"; load_config; printf '%s' "$LAPTOP_MODEL_FILE" ) )" = Qwen3.5-9B-UD-Q4_K_XL.gguf
check "copied example: other values untouched" test "$(val "$T/copy.env" DESKTOP_IP)" = 192.168.1.100

# --defaults and --set
rm -f "$T/d.env"
OUT=$(NODE_ENV="$T/d.env" "$ROOT/setup.sh" configure --defaults --set GITHUB_ORG=acme --set DESKTOP_IP=10.9.8.7 2>&1); RC=$?
check "defaults: exits 0 without a terminal" test $RC -eq 0
check "defaults: --set values land" test "$(val "$T/d.env" DESKTOP_IP)/$(val "$T/d.env" GITHUB_ORG)" = 10.9.8.7/acme
check "defaults: machine user derived from --set org" test "$(val "$T/d.env" GITHUB_MACHINE_USER)" = acme-hermes
check "defaults: reports what is still needed" has "not set yet:"
check "defaults: unset required settings are commented, not empty" grep -q '# OR_WORKER_MODEL=   (not set yet' "$T/d.env"
check "defaults: the file still sources cleanly" test "$(val "$T/d.env" OR_WORKER_MODEL)" = '<unset>'
OUT=$(NODE_ENV="$T/d.env" "$ROOT/setup.sh" configure --defaults --set LAPTOP_IP=nope 2>&1); RC=$?
check "set: an invalid value is refused" test $RC -ne 0
check "set: ...with the reason" has "expected an IPv4 address"
OUT=$(NODE_ENV="$T/d.env" "$ROOT/setup.sh" configure --defaults --set NOT_A_SETTING=1 2>&1); RC=$?
check "set: an unknown setting is refused" test $RC -ne 0
OUT=$(NODE_ENV="$T/never.env" "$ROOT/setup.sh" configure 2>&1 </dev/null); RC=$?
check "no terminal and no --defaults: refuses instead of guessing" test $RC -ne 0
check "...and says what to do" has "--defaults"
OUT=$(NODE_ENV="$T/p.env" "$ROOT/setup.sh" configure --defaults --print 2>&1); RC=$?
check "print: shows the result without saving" bash -c "[[ $RC -eq 0 ]] && [[ ! -e '$T/p.env' ]]"
check "print: contains the settings" has "LAPTOP_IP="

# --advanced and --only
printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' >"$T/blank"
cp "$T/d.env" "$T/adv.env"
OUT=$(NODE_ENV="$T/adv.env" "$ROOT/setup.sh" configure --answers "$T/blank" --advanced --set OR_WORKER_MODEL=a/b --set OR_REVIEW_MODEL=a/c --set OR_COMPRESSION_MODEL=a/d --set OR_FALLBACK_MODEL=a/e --set GITHUB_REPOS=app --set GITHUB_NOREPLY_EMAIL=1+acme-hermes@users.noreply.github.com 2>&1); RC=$?
check "advanced: exits 0" test $RC -eq 0
check "advanced: asks about ports"            has "Dashboard port"
check "advanced: asks about the context size" has "Laptop context size"
check "advanced: asks for the laptop cache size" has "Laptop prompt cache"
check "advanced: leaves the desktop-only questions to the desktop wizard" lacks "Expert layers kept in RAM"
check "advanced: is not offered the overnight-only settings while the tier is off" lacks "GPU layers for the 27B"
printf '9090\n' >"$T/p9090"
OUT=$(NODE_ENV="$T/adv.env" "$ROOT/setup.sh" configure --only LLM_PORT --answers "$T/p9090" 2>&1); RC=$?
check "only: exits 0" test $RC -eq 0
check "only: asks just that setting" test "$(val "$T/adv.env" LLM_PORT)" = 9090
check "only: leaves the others alone" test "$(val "$T/adv.env" GITHUB_ORG)" = acme
echo 'MY_EXTRA=keepme' >>"$T/adv.env"
printf '8081\n' >"$T/p8081"
NODE_ENV="$T/adv.env" "$ROOT/setup.sh" configure --only LLM_PORT --answers "$T/p8081" >/dev/null 2>&1
check "unknown lines in node.env survive a rewrite" test "$(val "$T/adv.env" MY_EXTRA)" = keepme
OUT=$(NODE_ENV="$T/adv.env" "$ROOT/setup.sh" configure --only LLM_PORT --answers /dev/null 2>&1); RC=$?
check "scripted answers running out is a clear error" bash -c "[[ $RC -ne 0 ]] && grep -q 'ran out' <<<\"\$0\"" "$OUT"


# =============================== file integrity (found by the review workflow)
hv=$T/hostile.env
cat >"$hv" <<ENV
LAPTOP_IP=10.0.0.20
DESKTOP_IP=10.0.0.30
ROUTER_IP=10.0.0.1
ADMIN_USER=james
LAPTOP_MODEL_ALIAS="x' ; touch $T/PWNED ; echo '"
export DASHBOARD_PORT=9120
MY_ARR=(a b)
MY_HOME="\$HOME/x"
ENV
NODE_ENV="$hv" "$ROOT/setup.sh" configure --defaults >/dev/null 2>&1
# shellcheck disable=SC1090  # sourcing the file under test, as the stages do
( set -a; source "$hv" ) >/dev/null 2>&1
check "integrity: a value with a quote stays inert after the wizard rewrites the file" test ! -e "$T/PWNED"
check "integrity: ...and still reads back identical" test "$(NODE_ENV="$hv" bash -c 'source "$1/lib/common.sh"; cfg_schema_load; cfg_parse_env "$NODE_ENV"; printf "%s" "${CFG_VAL[LAPTOP_MODEL_ALIAS]}"' _ "$ROOT")" = "x' ; touch $T/PWNED ; echo '"
check "integrity: the rewritten file still sources cleanly" bash -c "set -e; set -a; source '$hv' >/dev/null 2>&1"
check "integrity: an 'export KEY=value' line is honoured, not dropped" test "$(val "$hv" DASHBOARD_PORT)" = 9120
check "integrity: an array assignment is kept exactly as found" grep -qxF 'MY_ARR=(a b)' "$hv"
check "integrity: an unexpanded \$HOME is kept exactly as found" grep -qxF 'MY_HOME="$HOME/x"' "$hv"
printf 'LAPTOP_MODEL_ALIAS="it'"'"'s"\nLAPTOP_IP=10.0.0.20\nDESKTOP_IP=10.0.0.30\nADMIN_USER=james\n' >"$T/apos.env"
NODE_ENV="$T/apos.env" "$ROOT/setup.sh" configure --defaults >/dev/null 2>&1
check "integrity: a benign apostrophe no longer breaks the file" bash -c "NODE_ENV='$T/apos.env'; source '$ROOT/lib/common.sh'; load_config 2>/dev/null; [[ \$LAPTOP_MODEL_ALIAS == \"it's\" ]]"
for tricky in 'a b' 'a#b' 'a=b' 'x"y' "x'y" 'back\slash' 'tab	tab' '$HOME' '`id`' '*' '-rf' ''; do
  roundtrip_ok() {
    local q; q=$(cfg_quote "$tricky")
    local back; back=$(bash -c "source /dev/stdin <<<\"V=\$1\"; printf '%s' \"\$V\"" _ "$q")
    [[ $back == "$tricky" ]] && [[ $(cfg_unquote "$q") == "$tricky" ]]
  }
  check "quote round trip: shell and cfg_unquote both read back [$tricky]" roundtrip_ok
done
# CRLF files
printf 'LAPTOP_IP=10.0.0.20\r\nDESKTOP_IP=10.0.0.30\r\nADMIN_USER=james\r\n' >"$T/crlf.env"
check "CRLF: load_config strips the carriage returns" test "$( ( NODE_ENV="$T/crlf.env"; load_config; printf '%s' "$ADMIN_USER" ) | od -An -c | tr -d ' ')" = 'james'
# the old pinned model file picks the quantization
printf 'LAPTOP_IP=10.0.0.20\nDESKTOP_IP=10.0.0.30\nADMIN_USER=james\nLAPTOP_MODEL_FILE=Qwen3.5-9B-UD-Q4_K_XL.gguf\nDESKTOP_MODEL_FILE=Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf\n' >"$T/old.env"
check "upgrade: load_config infers the quantization from a pinned file name" test "$( ( NODE_ENV="$T/old.env"; load_config; printf '%s/%s' "$LAPTOP_QUANT" "$DESKTOP_QUANT" ) )" = UD-Q4_K_XL/UD-Q4_K_XL
NODE_ENV="$T/old.env" "$ROOT/setup.sh" configure --defaults >/dev/null 2>&1
check "upgrade: the wizard writes the inferred quantization" test "$(val "$T/old.env" LAPTOP_QUANT)" = UD-Q4_K_XL
# an unusable current value is not offered as the default
cp "$ROOT/config/node.env.example" "$T/ph2.env"
printf '\nacme\n' >"$T/ans-ph"
OUT=$(NODE_ENV="$T/ph2.env" "$ROOT/setup.sh" configure --only GITHUB_ORG --answers "$T/ans-ph" 2>&1); RC=$?
check "placeholder: --only asks again until a real value is given" test $RC -eq 0
check "placeholder: ...and says the current value is not usable" has "not usable"
check "placeholder: ...and saves the real value" test "$(val "$T/ph2.env" GITHUB_ORG)" = acme
# --only must not adopt detected values for everything else
printf 'GITHUB_ORG=acme\n' >"$T/min.env"
printf 'vendor-a/worker\n' >"$T/ans-w"
NODE_ENV="$T/min.env" "$ROOT/setup.sh" configure --only OR_WORKER_MODEL --answers "$T/ans-w" >/dev/null 2>&1
check "--only: asked setting saved" test "$(val "$T/min.env" OR_WORKER_MODEL)" = vendor-a/worker
check "--only: unrelated detected defaults (laptop ip, router) were NOT adopted silently" test "$(val "$T/min.env" LAPTOP_IP)/$(val "$T/min.env" ROUTER_IP)" = '<unset>/<unset>'
# final scripted answer without a trailing newline
printf 'acme' >"$T/nonl"
OUT=$(NODE_ENV="$T/min.env" "$ROOT/setup.sh" configure --only GITHUB_ORG --answers "$T/nonl" 2>&1); RC=$?
check "scripted input: the last answer may lack a trailing newline" test $RC -eq 0
# symlinked settings file stays a symlink
mkdir -p "$T/real"; cp "$T/min.env" "$T/real/node.env"; ln -sf "$T/real/node.env" "$T/link.env"
NODE_ENV="$T/link.env" "$ROOT/setup.sh" configure --defaults >/dev/null 2>&1
check "symlink: the link survives and the target is updated" bash -c "[[ -L '$T/link.env' ]] && grep -q '^GITHUB_ORG=acme' '$T/real/node.env'"
check "no temp files are left next to the settings file" test -z "$(find "$T/real" -name '.node.env.*')"
# admin == agent warning
printf 'ADMIN_USER=hermes\n' >"$T/same.env"
OUT=$(NODE_ENV="$T/same.env" "$ROOT/setup.sh" configure --defaults 2>&1)
check "wizard: warns when the admin and agent accounts are the same" has "the agent should have its own account"

# --scope desktop asks the desktop's questions only (the PowerShell wizard's scope)
printf '%s\n' 10.0.0.20 10.0.0.30 10.0.0.1 james 2 n n n '' >"$T/ans-scope"
OUT=$(NODE_ENV="$T/scope.env" "$ROOT/setup.sh" configure --scope desktop --answers "$T/ans-scope" 2>&1); RC=$?
check "scope desktop: exits 0" test $RC -eq 0
check "scope desktop: asks the shared and desktop questions" has "Desktop model quantization"
check "scope desktop: does not ask GitHub or OpenRouter questions" lacks "Worker model"
check "scope desktop: does not ask the laptop model question" lacks "Laptop model quantization"
check "scope desktop: a laptop-only detected default (LAN) is not adopted" test "$(val "$T/scope.env" LAN_CIDR)" = '<unset>'
check "scope desktop: the answers were saved" test "$(val "$T/scope.env" DESKTOP_QUANT)/$(val "$T/scope.env" ADMIN_USER)" = UD-Q4_K_XL/james
OUT=$(NODE_ENV="$T/scope.env" "$ROOT/setup.sh" configure --scope nowhere --defaults 2>&1); RC=$?
check "scope: an unknown scope is refused" test $RC -ne 0

# =============================== just-in-time prompting (cfg_ensure)
cp "$T/d.env" "$T/jit.env"
ens() { OUT=$(NODE_ENV="${ENS_FILE:-$T/jit.env}" bash -c 'source "$1/lib/common.sh"; shift; cfg_ensure "$@"' _ "$ROOT" "$@" 2>&1 </dev/null); RC=$?; }
ens GITHUB_ORG DASHBOARD_PORT
check "ensure: nothing to ask when everything is valid" test $RC -eq 0
ens OR_WORKER_MODEL OR_REVIEW_MODEL
check "ensure: refuses without a terminal" test $RC -ne 0
check "ensure: names the missing settings and the command" bash -c "grep -q 'OR_WORKER_MODEL OR_REVIEW_MODEL' <<<\"\$0\" && grep -q 'configure --only' <<<\"\$0\"" "$OUT"
printf 'vendor-a/worker\nvendor-b/reviewer\n' >"$T/jitans"
OUT=$(NODE_ENV="$T/jit.env" HS_INPUT="$T/jitans" bash -c 'source "$1/lib/common.sh"; cfg_ensure OR_WORKER_MODEL OR_REVIEW_MODEL OR_FALLBACK_MODEL GITHUB_ORG' _ "$ROOT" 2>&1 </dev/null); RC=$?
check "ensure: asks only for what is missing (the third model is still missing, so it asks and runs out)" test $RC -ne 0
printf 'vendor-a/worker\nvendor-b/reviewer\nvendor-c/fallback\n' >"$T/jitans"
OUT=$(NODE_ENV="$T/jit.env" HS_INPUT="$T/jitans" bash -c 'source "$1/lib/common.sh"; cfg_ensure OR_WORKER_MODEL OR_REVIEW_MODEL OR_FALLBACK_MODEL GITHUB_ORG' _ "$ROOT" 2>&1 </dev/null); RC=$?
check "ensure: asks for the three missing models" test $RC -eq 0
check "ensure: persists them" test "$(val "$T/jit.env" OR_FALLBACK_MODEL)" = vendor-c/fallback
check "ensure: keeps earlier settings" test "$(val "$T/jit.env" DESKTOP_IP)" = 10.9.8.7
cp "$ROOT/config/node.env.example" "$T/ph.env"
ENS_FILE="$T/ph.env" ens GITHUB_ORG
check "ensure: the example's 'yourorg' counts as missing" test $RC -ne 0
printf 'GITHUB_ORG=acme\n' >"$T/noadopt.env"
printf 'vendor-a/worker\n' >"$T/noadopt-ans"
OUT=$(NODE_ENV="$T/noadopt.env" HS_INPUT="$T/noadopt-ans" bash -c 'source "$1/lib/common.sh"; cfg_ensure OR_WORKER_MODEL' _ "$ROOT" 2>&1 </dev/null); RC=$?
check "ensure: asked for one setting" test $RC -eq 0
check "ensure: ...and did not adopt detected addresses for settings nobody asked about" test "$(val "$T/noadopt.env" LAPTOP_IP)/$(val "$T/noadopt.env" ROUTER_IP)/$(val "$T/noadopt.env" LAN_CIDR)" = '<unset>/<unset>/<unset>'
ENS_FILE="$T/ph.env" ens DASHBOARD_PORT LAPTOP_QUANT
check "ensure: settings with a literal default need no prompt" test $RC -eq 0
rm -f "$T/auto.env"; printf 'GITHUB_ORG=acme\n' >"$T/auto.env"
ens LAPTOP_IP
NODE_ENV="$T/auto.env" bash -c 'source "$1/lib/common.sh"; cfg_ensure LAPTOP_IP' _ "$ROOT" >/dev/null 2>&1 </dev/null
check "ensure: a detected (auto) setting is never adopted silently" test $? -ne 0

# =============================== yes/no and flag prompts
yn() { # yn "answers" default -> status
  printf '%b' "$1" >"$T/yn"; HS_INPUT="$T/yn" bash -c 'source "$1/lib/common.sh"; ask_yesno "Q?" "$2"' _ "$ROOT" "$2" >/dev/null 2>&1
}
yn 'y\n' n;   check "yesno: y"                    test $? -eq 0
yn 'no\n' y;  check "yesno: no"                   test $? -eq 1
yn '\n' y;    check "yesno: Enter takes default y" test $? -eq 0
yn '\n' n;    check "yesno: Enter takes default n" test $? -eq 1
yn 'huh\ny\n' n; check "yesno: re-asks after junk" test $? -eq 0
bash -c 'source "$1/lib/common.sh"; ASSUME_YES=1; ask_yesno "Q?" y' _ "$ROOT" >/dev/null 2>&1 </dev/null; check "yesno: --yes takes the default (y)" test $? -eq 0
bash -c 'source "$1/lib/common.sh"; ask_yesno "Q?" n' _ "$ROOT" >/dev/null 2>&1 </dev/null; check "yesno: no terminal takes the default (n)" test $? -eq 1
flagv() { printf '%b' "$1" >"$T/fl"; HS_INPUT="$T/fl" bash -c 'source "$1/lib/common.sh"; FOO="$2"; ask_flag FOO "Q?" "$3" >/dev/null 2>&1; printf "%s" "$FOO"' _ "$ROOT" "$2" "$3"; }
check "flag: asks when unset and stores 1"       test "$(flagv 'y\n' '' n)" = 1
check "flag: asks when unset and stores 0"       test "$(flagv 'n\n' '' y)" = 0
check "flag: a command-line value is never overridden (and not asked)" test "$(flagv '' 0 y)" = 0
check "text: Enter takes the default"             test "$(printf '\n' >"$T/t"; HS_INPUT="$T/t" bash -c 'source "$1/lib/common.sh"; ask_text X "Q" dflt >/dev/null 2>&1; printf "%s" "$X"' _ "$ROOT")" = dflt

echo "config: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
