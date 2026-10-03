#!/usr/bin/env bash
# PowerShell checks: parse every script, unit-test the helpers, run each installer with -DryRun.
# Needs PowerShell 7 (pwsh); skipped if it is not installed (STRICT=1 makes that a failure).
exec </dev/null
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PWSH=${PWSH:-$(command -v pwsh || true)}
if [[ -z $PWSH ]]; then echo "pwsh not installed - skipped"; [[ ${STRICT:-0} == 1 ]] && exit 1; exit 0; fi
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 POWERSHELL_TELEMETRY_OPTOUT=1
T=$(mktemp -d); trap 'kill ${s1:-} ${s2:-} ${s3:-} 2>/dev/null; rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }
ps() { "$PWSH" -NoProfile -NonInteractive "$@"; }
has() { grep -qF -- "$1" <<<"$OUT"; }

# ---- parse every script
parse_all() { ps -File "$ROOT/tests/powershell/Parse-All.ps1" "$ROOT/desktop,$ROOT/tests/powershell"; }
check "every .ps1 parses" parse_all

# ---- helper unit tests against fake llama-servers
port=$((20000 + RANDOM % 20000))
python3 "$ROOT/tests/fakebin/fake_llm.py" "$port" tool & s1=$!
python3 "$ROOT/tests/fakebin/fake_llm.py" "$((port + 1))" prose & s2=$!
python3 "$ROOT/tests/fakebin/fake_llm.py" "$((port + 2))" tool secret & s3=$!
sleep 1
FAKE_TOOL_PORT=$port FAKE_PROSE_PORT=$((port + 1)) FAKE_KEY_PORT=$((port + 2)) \
  ps -File "$ROOT/tests/powershell/Test-Common.ps1" -Root "$ROOT" -Tmp "$T"
check "helper unit tests" test $? -eq 0

# ---- settings engine (shared validator cases, wizard, import, byte-for-byte parity with the bash writer)
export PATH="$ROOT/tests/fakebin:$PATH"
NODE_ENV="$T/parity.env" "$ROOT/setup.sh" configure --defaults --set GITHUB_ORG=acme --set 'GITHUB_REPOS=api web' --set LAPTOP_IP=10.1.2.3 --set DESKTOP_QUANT=UD-Q4_K_XL >/dev/null 2>&1
HS_PARITY_FILE="$T/parity.env" ps -File "$ROOT/tests/powershell/Test-Settings.ps1" -Root "$ROOT" -Tmp "$T"
check "settings engine tests" test $? -eq 0
# a file the PowerShell wizard wrote loads in bash with the same meaning
ps -File "$ROOT/desktop/windows/Configure.ps1" -ConfigFile "$T/ps-written.env" -Defaults -Set 'LAPTOP_IP=10.0.0.20,DESKTOP_IP=10.0.0.30,DESKTOP_QUANT=UD-Q4_K_XL' >/dev/null 2>&1
check "bash loads the PowerShell-written file" bash -c "NODE_ENV='$T/ps-written.env'; source '$ROOT/lib/common.sh'; load_config; [[ \$LAPTOP_IP == 10.0.0.20 && \$DESKTOP_MODEL_FILE == Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf && \$SSH_ALLOWED_FROM == 10.0.0.30 ]]"

# ---- dry runs of the three installers
cfg_with() { sed -E "$@" "$ROOT/config/node.env.example" >"$T/node.env"; }
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|'
run_ps() { OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/$1" -ConfigFile "$T/node.env" "${@:2}" 2>&1); RC=$?; }

run_ps Install-Llama.ps1 -DryRun
check "Install-Llama -DryRun exits 0" test $RC -eq 0
check "Install-Llama: downloads the Vulkan build" has "latest llama-*-bin-win-vulkan-x64.zip"
check "Install-Llama: checks the GPU is listed" has "--list-devices"
check "Install-Llama: downloads the Q5 model" has "Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
check "Install-Llama: writes start-llama.cmd" has "write C:\\llama\\start-llama.cmd"
check "Install-Llama: key file gets a locked-down ACL" has "readable only by you and administrators"
check "Install-Llama: firewall rule is laptop-only" has "firewall rule 'llama-server 8080 (laptop only)' from 192.168.1.150"
check "Install-Llama: task starts at logon with no time limit" has "at logon, highest privileges, no time limit"
check "Install-Llama: finishes by pointing at the laptop stage" has "./setup.sh run 11"
run_ps Install-Llama.ps1 -DryRun -SkipModelDownload -NoStart -NeverSleepOnAC
check "Install-Llama: -SkipModelDownload skips the download" bash -c "! grep -q 'curl.exe -L --fail -C' <<<\"\$0\"" "$OUT"
check "Install-Llama: -NeverSleepOnAC changes the power plan" has "never sleep on mains power"
check "Install-Llama: -NoStart skips the server start" bash -c "! grep -q 'start the' <<<\"\$0\"" "$OUT"
sed -i 's|^DESKTOP_IP=.*|DESKTOP_IP=|' "$T/node.env"
run_ps Install-Llama.ps1 -DryRun
check "Install-Llama: an empty DESKTOP_IP is rejected by name" bash -c "[[ $RC -ne 0 ]] && grep -q DESKTOP_IP <<<\"\$0\"" "$OUT"
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|'

run_ps Install-Overnight.ps1 -DryRun
check "Install-Overnight -DryRun exits 0" test $RC -eq 0
check "Install-Overnight: downloads the 27B" has "Qwen3.8-27B-UD-Q4_K_XL.gguf"
check "Install-Overnight: night and day tasks at the configured times" has "tasks llama-night at 01:00 and llama-day at 07:00"
check "Install-Overnight: allows wake timers" has "wake timers on"
check "Install-Overnight: active hours only on request" has "-SetUpdateActiveHours"
run_ps Install-Overnight.ps1 -DryRun -SetUpdateActiveHours
check "Install-Overnight: -SetUpdateActiveHours sets them" has "Windows Update active hours"
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=0|'
run_ps Install-Overnight.ps1 -DryRun
check "Install-Overnight: refuses while NIGHT_ENABLED=0" bash -c "[[ $RC -ne 0 ]] && grep -q NIGHT_ENABLED <<<\"\$0\"" "$OUT"
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|' -e 's|^NIGHT_START=.*|NIGHT_START=25:00|'
run_ps Install-Overnight.ps1 -DryRun
check "Install-Overnight: rejects a bad NIGHT_START" bash -c "[[ $RC -ne 0 ]] && grep -q NIGHT_START <<<\"\$0\"" "$OUT"
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|'

mkdir -p "$T/profile" "$T/desk"
run_ps Setup-LaptopAccess.ps1 -DryRun -TunnelDir "$T/desk"
check "Setup-LaptopAccess -DryRun exits 0" test $RC -eq 0
check "Setup-LaptopAccess: generates an ed25519 key when none exists" has "ssh-keygen -t ed25519"
check "Setup-LaptopAccess: installs the key for the admin user on the laptop" has "ai-node@192.168.1.150"
check "Setup-LaptopAccess: proves a password-less login" has "PasswordAuthentication=no"
check "Setup-LaptopAccess: writes the tunnel shortcut" has "hermes-tunnel.cmd"
check "Setup-LaptopAccess: points at stage 02" has "./setup.sh run 02"
mkdir -p "$T/profile/.ssh" && echo "ssh-ed25519 AAAA test" >"$T/profile/.ssh/id_ed25519.pub"
run_ps Setup-LaptopAccess.ps1 -DryRun -NoTunnelFile
check "Setup-LaptopAccess: reuses an existing key" has "using the existing key"
check "Setup-LaptopAccess: -NoTunnelFile skips the shortcut" bash -c "! grep -q 'hermes-tunnel.cmd' <<<\"\$0\"" "$OUT"

# ---- no settings yet: the installers ask by themselves (scripted answers stand in for the user)
rm -f "$T/fresh.env"
printf '%s\n' '' 10.0.0.20 10.0.0.30 10.0.0.1 james 2 n n '' y n >"$T/psans1"   # skip the import offer, wizard (ip x3, admin, quant=Q4, overnight n, advanced n, save), then: never-sleep y, start now n
export HS_INPUT="$T/psans1"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Install-Llama.ps1" -ConfigFile "$T/fresh.env" -DryRun 2>&1); RC=$?
unset HS_INPUT
check "no settings: Install-Llama asks, saves and carries on (exit 0)" test $RC -eq 0
check "no settings: ...the answers were saved" bash -c "grep -q '^LAPTOP_IP=10.0.0.20' '$T/fresh.env' && grep -q '^DESKTOP_QUANT=UD-Q4_K_XL' '$T/fresh.env'"
check "no settings: ...the Q4 choice reaches the download" has "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
check "no settings: ...the firewall rule uses the laptop address that was typed" has "from 10.0.0.20"
check "no settings: ...the sleep question was answered yes" has "never sleep on mains power"
check "no settings: ...the start question was answered no" bash -c "! grep -q 'start the .llama-server. task' <<<\"\$0\"" "$OUT"
rm -f "$T/fresh2.env"
printf '%s\n' '' 10.0.0.20 10.0.0.30 10.0.0.1 james '' n n '' n >"$T/psans2"   # skip import, wizard, then: tunnel shortcut n
export HS_INPUT="$T/psans2"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Setup-LaptopAccess.ps1" -ConfigFile "$T/fresh2.env" -DryRun 2>&1); RC=$?
unset HS_INPUT
check "no settings: Setup-LaptopAccess asks first (exit 0)" test $RC -eq 0
check "no settings: ...installs the key for the admin user that was typed" has "james@10.0.0.20"
check "no settings: ...declining the shortcut writes none" bash -c "! grep -q 'write .*hermes-tunnel.cmd' <<<\"\$0\"" "$OUT"
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=0|'
printf '%s\n' y 03:00 06:00 n >"$T/psans3"   # turn the tier on, start, end, then: update active hours n
export HS_INPUT="$T/psans3"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Install-Overnight.ps1" -ConfigFile "$T/node.env" -DryRun 2>&1); RC=$?
unset HS_INPUT
check "overnight off in the settings: offers to turn it on (exit 0)" test $RC -eq 0
check "overnight: ...uses the times that were typed" has "tasks llama-night at 03:00 and llama-day at 06:00"
check "overnight: ...and saved the switch" grep -q '^NIGHT_ENABLED=1' "$T/node.env"
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=0|'
run_ps Install-Overnight.ps1 -DryRun
check "overnight off, no terminal: refuses and never flips the setting" bash -c "[[ $RC -ne 0 ]] && grep -q '^NIGHT_ENABLED=0' '$T/node.env'"
rm -f "$T/none.env"
run_ps Configure.ps1 -Print
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Install-Llama.ps1" -ConfigFile "$T/none.env" -DryRun 2>&1); RC=$?
check "no settings and no terminal: refuses and names Configure.ps1" bash -c "[[ $RC -ne 0 ]] && grep -q 'Configure.ps1' <<<\"\$0\"" "$OUT"

echo "powershell: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
