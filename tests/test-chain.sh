#!/usr/bin/env bash
# The local endpoint order (lib/chain.sh) and the "desktop away" switch (tools/desktop-loop.sh, `hermes-desktop`):
# end-user style runs in a sandbox home with stubbed externals.
# shellcheck disable=SC2016,SC2030,SC2031  # literal $ in the expected text; NODE_ENV is set per subshell on purpose
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
has() { grep -qF -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
logged() { grep -qF -- "$1" "$FAKE_LOG"; }

export HOME="$T/home" FAKE_LOG="$T/calls.log" XDG_RUNTIME_DIR="$T/run" ASSUME_YES=1 DRY_RUN=0
export HS_ALLOW_ANY_USER=1 HS_SHARED="$ROOT"
mkdir -p "$HOME/.hermes/profiles/local" "$XDG_RUNTIME_DIR"; : >"$FAKE_LOG"
export PATH="$ROOT/tests/fakebin:$PATH"
sed -E \
  -e 's|^GITHUB_ORG=.*|GITHUB_ORG=acme|' -e 's|^GITHUB_REPOS=.*|GITHUB_REPOS="app"|' \
  -e 's|^OR_WORKER_MODEL=.*|OR_WORKER_MODEL=a/w|' -e 's|^OR_REVIEW_MODEL=.*|OR_REVIEW_MODEL=b/r|' \
  -e 's|^OR_COMPRESSION_MODEL=.*|OR_COMPRESSION_MODEL=a/m|' -e 's|^OR_FALLBACK_MODEL=.*|OR_FALLBACK_MODEL=c/f|' \
  "$ROOT/config/node.env.example" >"$T/node.env"
sed 's|^V100_ENABLED=.*|V100_ENABLED=1|' "$T/node.env" >"$T/v100.env"
sed 's|^V100_PRIMARY=.*|V100_PRIMARY=0|' "$T/v100.env" >"$T/v100-second.env"
export NODE_ENV="$T/node.env"
cfg=$HOME/.hermes/config.yaml pc=$HOME/.hermes/profiles/local/config.yaml flag=$HOME/.hermes/desktop-away

yget() { python3 - "$1" "$2" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    d = d[int(part)] if isinstance(d, list) else d[part]
print(d)
PY
}
chain_of() { python3 - "$1" <<'PY'
import sys, yaml
print(",".join(e["provider"] for e in yaml.safe_load(open(sys.argv[1]))["fallback_providers"]))
PY
}
entries() { ( NODE_ENV=$1; source "$ROOT/lib/common.sh"; load_config; chain_entries | cut -d'|' -f1 | paste -sd, ); }
loop() { OUT=$(bash "$ROOT/tools/desktop-loop.sh" "$@" 2>&1); RC=$?; }

# ================= the endpoint order
check "chain: desktop, then laptop by default" test "$(entries "$T/node.env")" = custom:desktop,custom:laptop
check "chain: with the V100 tier it comes first (V100_PRIMARY=1)" test "$(entries "$T/v100.env")" = custom:desktop-v100,custom:desktop,custom:laptop
check "chain: V100_PRIMARY=0 puts it after the day model" test "$(entries "$T/v100-second.env")" = custom:desktop,custom:desktop-v100,custom:laptop
touch_flag() { mkdir -p "$HOME/.hermes"; echo "since test" >"$flag"; }
touch_flag
check "chain: away leaves only the laptop" test "$(entries "$T/node.env")" = custom:laptop
check "chain: away leaves out the V100 as well" test "$(entries "$T/v100.env")" = custom:laptop
rm -f "$flag"
# head -1 exits after the first line, so chain_entries' next print hits a closed pipe (SIGPIPE, rc
# 141), and pipefail + set -e killed an offline run about once in ten (measured). The first entry is
# read to the end of the producer now, so every round must survive.
sed 's|^OFFLINE=.*|OFFLINE=1|' "$T/node.env" >"$T/off.env"
first_entry_rounds() { NODE_ENV="$T/off.env" bash -c '
set -Eeuo pipefail
source "$1/lib/common.sh"
load_config
for _ in $(seq 1 60); do chain_main_yaml >/dev/null; done
' _ "$ROOT"; }
check "chain: reading the first offline entry never SIGPIPEs the producer (60 rounds under set -e)" first_entry_rounds
chain_yaml_ok() { ( NODE_ENV=$1; source "$ROOT/lib/common.sh"; load_config; { chain_main_yaml; echo ---; chain_local_yaml; } >"$T/chain.out"; python3 - "$T/chain.out" <<'PY'
import sys, yaml
main, local = open(sys.argv[1]).read().split("---\n")
m, l = yaml.safe_load(main), yaml.safe_load(local)
assert m["fallback_providers"][0] == {"provider": "openrouter", "model": "c/f"}, m
assert l["model"]["provider"].startswith("custom:"), l
# sub-agents: the cloud profile's children fall back along the same chain; the local profile's (pinned to the
# laptop) fall back to the desktop endpoints only, or nowhere when the desktop is away
assert m["delegation"]["fallback_providers"] == m["fallback_providers"], m
lp = [e["provider"] for e in l["delegation"]["fallback_providers"]]
assert "custom:laptop" not in lp, lp
assert lp == [p for p in [l["model"]["provider"]] + [e["provider"] for e in l["fallback_providers"]] if p != "custom:laptop"], (lp, l)
PY
); }
check "chain: both fragments are valid YAML (default)" chain_yaml_ok "$T/node.env"
check "chain: both fragments are valid YAML (V100 tier)" chain_yaml_ok "$T/v100.env"
touch_flag
check "chain: both fragments are valid YAML (away)" chain_yaml_ok "$T/node.env"
rm -f "$flag"

# ================= hermes-desktop with nothing configured yet
loop status
check "status works before stage 11 (exit 0)" test $RC -eq 0
check "status says the desktop is in the loop" has "the desktop is in the loop"
loop off
check "off without the Hermes configs says to run stage 11" bash -c "[[ $RC -ne 0 ]] && grep -q 'run stages 07 and 11 first' <<<\"\$0\"" "$OUT"
check "...and changes nothing" test ! -e "$flag"

# what stages 07 and 11 leave behind
printf 'model:\n  provider: openrouter\nproviders:\n  desktop:\n    api: http://192.168.1.100:8080/v1\n  laptop:\n    api: http://127.0.0.1:8080/v1\nfallback_providers:\n  - provider: openrouter\n    model: "c/f"\n  - provider: custom:desktop\n    model: qwen3.6-35b-a3b\n  - provider: custom:laptop\n    model: qwen3.5-9b\n' >"$cfg"
printf 'model:\n  provider: custom:desktop\n  default: qwen3.6-35b-a3b\ndelegation:\n  model: qwen3.5-9b\n' >"$pc"
printf 'DESKTOP_LLM_KEY=testkey\n' >"$HOME/.hermes/.env"
printf 'overnight-coverage\n' >"$HOME/.hermes/profiles/local/fake-cron"

# ================= off
cp "$cfg" "$T/cfg.before"; cp "$pc" "$T/pc.before"
loop off --dry-run
check "off --dry-run exits 0" test $RC -eq 0
check "off --dry-run changes nothing" bash -c "cmp -s '$cfg' '$T/cfg.before' && cmp -s '$pc' '$T/pc.before' && [[ ! -e '$flag' ]]"
check "off --dry-run shows what it would write" has "would merge into"
: >"$FAKE_LOG"
loop off
check "off: exits 0" test $RC -eq 0
check "off: writes the flag" test -s "$flag"
check "off: main chain is OpenRouter, then laptop" test "$(chain_of "$cfg")" = openrouter,custom:laptop
check "off: the fallback model stays the configured one" test "$(yget "$cfg" fallback_providers.0.model)" = c/f
check "off: the local profile runs on the laptop" test "$(yget "$pc" model.provider)/$(yget "$pc" model.default)" = custom:laptop/qwen3.5-9b
check "off: ...with no fallbacks" test "$(python3 -c "import yaml;print(yaml.safe_load(open('$pc'))['fallback_providers'])")" = "[]"
check "off: other local profile settings are untouched" test "$(yget "$pc" delegation.model)" = qwen3.5-9b
check "off: the desktop endpoint stays defined (/model custom:desktop still works)" test "$(yget "$cfg" providers.desktop.api)" = http://192.168.1.100:8080/v1
check "off: says it is out of the loop" has "the desktop is OUT of the loop"
check "off: tells how to bring it back" has "hermes-desktop on"
check "off: warns about the pinned overnight job" has "never fall back"
check "off: no timer without --for" bash -c "! grep -q 'systemd-run' '$FAKE_LOG'"
loop status
check "status afterwards says OUT" has "OUT of the loop"
check "status lists only the laptop" bash -c "grep -q '1. custom:laptop' <<<\"\$0\" && ! grep -q 'custom:desktop' <<<\"\$0\"" "$OUT"
cp "$cfg" "$T/cfg.away"
loop off
check "off twice is harmless" bash -c "[[ $RC -eq 0 ]] && cmp -s '$cfg' '$T/cfg.away'"

# ================= the rest of the kit respects it
HM_OUT=$(bash -c "$(cd "$ROOT" && source lib/common.sh && load_config >/dev/null 2>&1 && render_template templates/bin/hermes-mode.tpl && printf '%s' "$RENDERED")" status 2>&1)
check "hermes-mode status says the desktop is out of the loop" grep -q 'OUT of the loop' <<<"$HM_OUT"
check "hermes-mode status shows which model the desktop actually serves" grep -qE 'desktop .*: 200  serving qwen3.5-9b' <<<"$HM_OUT"
HM_OUT=$(FAKE_HTTP_CODE=000 bash -c "$(cd "$ROOT" && source lib/common.sh && load_config >/dev/null 2>&1 && render_template templates/bin/hermes-mode.tpl && printf '%s' "$RENDERED")" status 2>&1)
check "hermes-mode status: no 'serving' line for an endpoint that is down" bash -c "grep -qE 'desktop .*: 000\$' <<<\"\$1\"" _ "$HM_OUT"
cp "$T/cfg.before" "$cfg"; cp "$T/pc.before" "$pc"   # configs as stage 11 finds them: desktop still in both
OUT=$(bash "$ROOT/laptop/11-hermes-local-config.sh" 2>&1); RC=$?
check "stage 11 re-run: exits 0 while away" test $RC -eq 0
check "stage 11 re-run: warns the desktop is out" has "OUT of the loop"
check "stage 11 re-run: keeps the desktop out of the chain" test "$(chain_of "$cfg")" = openrouter,custom:laptop
check "stage 11 re-run: ...and out of the local profile" test "$(yget "$pc" model.provider)" = custom:laptop
rm -f "$flag"; cp "$T/cfg.before" "$cfg"; cp "$T/pc.before" "$pc"
OUT=$(NODE_ENV="$T/v100.env" bash "$ROOT/laptop/11-hermes-local-config.sh" 2>&1); RC=$?
check "stage 11 with the V100 tier on: exits 0" test $RC -eq 0
check "stage 11 with the V100 tier on: the chain has the V100 first" test "$(chain_of "$cfg")" = openrouter,custom:desktop-v100,custom:desktop,custom:laptop
check "stage 11 with the V100 tier on: the endpoint is defined in the main config and the local profile" test "$(yget "$cfg" providers.desktop-v100.api)/$(yget "$pc" providers.desktop-v100.api)" = http://192.168.1.100:8081/v1/http://192.168.1.100:8081/v1
check "stage 11 with the V100 tier on: the local profile plans on the V100" test "$(yget "$pc" model.provider)" = custom:desktop-v100
check "stage 11 with the V100 tier on: hermes-mode gets its probe" test -s "$HOME/.hermes/hermes-mode.d/desktop-v100"
OUT=$(bash "$ROOT/laptop/11-hermes-local-config.sh" 2>&1)
check "stage 11 with the tier off again: the probe is removed" test ! -e "$HOME/.hermes/hermes-mode.d/desktop-v100"
touch_flag
OUT=$(NODE_ENV="$T/v100.env" bash "$ROOT/tools/v100-laptop.sh" 2>&1); RC=$?
check "v100 tool: exits 0 while away" test $RC -eq 0
check "v100 tool: warns the desktop is out" has "OUT of the loop"
check "v100 tool: the chain still leaves every desktop endpoint out" test "$(chain_of "$cfg")" = openrouter,custom:laptop
check "v100 tool: ...but the V100 endpoint is defined for later" test "$(yget "$cfg" providers.desktop-v100.api)" = http://192.168.1.100:8081/v1

# ================= on
: >"$FAKE_LOG"
loop on
check "on: exits 0" test $RC -eq 0
check "on: removes the flag" test ! -e "$flag"
check "on: main chain is OpenRouter, desktop, laptop again" test "$(chain_of "$cfg")" = openrouter,custom:desktop,custom:laptop
check "on: the local profile plans on the desktop again" test "$(yget "$pc" model.provider)/$(yget "$pc" fallback_providers.0.provider)" = custom:desktop/custom:laptop
check "on: says the desktop is back" has "the desktop is back in the loop"
check "on: checks the desktop answers" has "the desktop model answers on 192.168.1.100:8080"
check "on: cancels a pending return timer" logged "systemctl --user stop hermes-desktop-return.timer"
loop on
check "on twice: says it was already in the loop" has "already in the loop"
FAKE_HTTP_CODE=000 loop on
check "on: an unreachable desktop is a warning, not a failure" bash -c "[[ $RC -eq 0 ]] && grep -q 'does not answer yet' <<<\"\$0\"" "$OUT"

# ================= off --for, and bad input
: >"$FAKE_LOG"
loop off --for 4h
check "off --for 4h: exits 0" test $RC -eq 0
check "off --for 4h: sets a timer that runs 'on'" bash -c "grep -q -- 'systemd-run --user --on-active=4h --unit=hermes-desktop-return' '$FAKE_LOG' && grep 'systemd-run' '$FAKE_LOG' | grep -q 'hermes-desktop on'"
check "off --for 4h: the flag says when it comes back" grep -q 'comes back by itself at' "$flag"
loop on
# reached through `sudo -u hermes` from the desktop: no XDG_RUNTIME_DIR, so the tool finds the lingering user manager itself
mkdir -p "$T/run-user"; python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$T/run-user/bus"
: >"$FAKE_LOG"
OUT=$(env -u XDG_RUNTIME_DIR HS_RUN_USER_DIR="$T/run-user" bash "$ROOT/tools/desktop-loop.sh" off --for 2h 2>&1); RC=$?
check "off --for without a login session: finds the user manager" bash -c "[[ $RC -eq 0 ]] && grep -q 'XDG_RUNTIME_DIR=$T/run-user BUS=unix:path=$T/run-user/bus' '$FAKE_LOG'"
: >"$FAKE_LOG"
OUT=$(env -u XDG_RUNTIME_DIR HS_RUN_USER_DIR="$T/run-user" bash "$ROOT/tools/desktop-loop.sh" on 2>&1); RC=$?
check "on without a login session: still cancels the return timer on the user manager" bash -c "[[ $RC -eq 0 ]] && grep -q 'systemctl --user stop hermes-desktop-return.timer.*XDG_RUNTIME_DIR=$T/run-user' '$FAKE_LOG'"
loop on
: >"$FAKE_LOG"; cp "$cfg" "$T/cfg.nobus"
OUT=$(env -u XDG_RUNTIME_DIR HS_RUN_USER_DIR="$T/no-such-dir" bash "$ROOT/tools/desktop-loop.sh" off --for 2h 2>&1); RC=$?
check "off --for with no user manager at all: refuses before changing anything" bash -c "[[ $RC -ne 0 ]] && grep -q 'no user session bus' <<<\"\$0\" && [[ ! -e '$flag' ]] && cmp -s '$cfg' '$T/cfg.nobus'" "$OUT"
loop off --for 90m
check "off --for 90m is accepted" test $RC -eq 0
loop on
loop off --for 4
check "off --for 4 (no unit) is refused" bash -c "[[ $RC -ne 0 ]] && grep -q 'expects a duration' <<<\"\$0\"" "$OUT"
loop off --for '4h; reboot'
check "off --for with shell text is refused" test $RC -ne 0
loop on --for 4h
check "on --for is refused" bash -c "[[ $RC -ne 0 ]] && grep -q 'only goes with' <<<\"\$0\"" "$OUT"
loop bogus
check "an unknown word is refused with the usage" bash -c "[[ $RC -ne 0 ]] && grep -q 'usage: hermes-desktop' <<<\"\$0\"" "$OUT"
check "the flag was left alone by the refused commands" test ! -e "$flag"

# ================= the hermes-desktop wrapper (what stage 11 installs)
bash "$ROOT/laptop/11-hermes-local-config.sh" >/dev/null 2>&1
check "stage 11 installs hermes-desktop" test -x "$HOME/.local/bin/hermes-desktop"
check "hermes-desktop points at the kit copy" grep -q "$ROOT/tools/desktop-loop.sh" "$HOME/.local/bin/hermes-desktop"
OUT=$("$HOME/.local/bin/hermes-desktop" off 2>&1); RC=$?
check "hermes-desktop off works through the wrapper" bash -c "[[ $RC -eq 0 && -s '$flag' ]]"
OUT=$("$HOME/.local/bin/hermes-desktop" status 2>&1)
check "hermes-desktop status works through the wrapper" has "OUT of the loop"
"$HOME/.local/bin/hermes-desktop" on >/dev/null 2>&1
check "hermes-desktop on works through the wrapper" test ! -e "$flag"

echo "chain: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
