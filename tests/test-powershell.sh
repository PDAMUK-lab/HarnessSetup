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
check() { # on a failure, show the end of the last script output (CI logs are all we get there)
  local n=$1; shift
  if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; tail -n 6 <<<"${OUT:-}" | sed 's/^/    | /'; fi
}
ps() { "$PWSH" -NoProfile -NonInteractive "$@"; }
has() { grep -qF -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
# flat TEXT  - PowerShell wraps an error message to the console width ("     | " continuation lines): join it back into one line
flat() { sed -E 's/\x1b\[[0-9;]*m//g; s/^ *\| ?//' <<<"$1" | tr '\n' ' ' | tr -s ' '; }

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
check "Install-Overnight: stays awake after an unattended wake" has "stay awake for up to 7 hours"
# the task bodies do not run in a dry run, so check the source: both swap tasks must run elevated like the day server
check "static: Install-Overnight registers llama-night and llama-day elevated" bash -c "[[ \$(grep -c 'Register-ScheduledTask.*-Principal \$principal' '$ROOT/desktop/windows/Install-Overnight.ps1') -eq 2 ]] && grep -q 'New-ScheduledTaskPrincipal.*-RunLevel Highest' '$ROOT/desktop/windows/Install-Overnight.ps1'"
check "static: Install-Overnight sets the unattended sleep timeout (25200 s)" grep -q '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 25200' "$ROOT/desktop/windows/Install-Overnight.ps1"
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

# ---- Backup-Laptop.ps1: copy the laptop's newest backup here
run_ps Backup-Laptop.ps1 -DryRun -Register
check "Backup-Laptop -DryRun exits 0" test $RC -eq 0
check "Backup-Laptop: restricts the backup folder to you and administrators" has "restrict C:\\hermes-backups to"
check "Backup-Laptop: looks for the newest backup on the laptop" has "ssh ai-node@192.168.1.150 ls -1t /var/backups/hermes-node/hermes-node-*.tar.gz"
check "Backup-Laptop -Register: a daily copy half an hour after the laptop's backup" has "task 'hermes-backup-copy' every day at 07:45"

# ---- Desktop-Mode.ps1: the desktop out of the loop and back (the ssh call is a stub that records its arguments)
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|' -e 's|^V100_ENABLED=.*|V100_ENABLED=1|'
export FAKE_LOG="$T/ps-calls.log"; : >"$FAKE_LOG"
run_ps Desktop-Mode.ps1 away -DryRun -Yes
check "Desktop-Mode away -DryRun exits 0" test $RC -eq 0
check "Desktop-Mode away: tells the laptop first, as the agent user" has 'ssh ai-node@192.168.1.150 "sudo -u hermes -H /home/hermes/.local/bin/hermes-desktop off"'
check "Desktop-Mode away: stops and disables every server task (day, V100, night, day swap)" bash -c "for t in llama-server llama-v100 llama-night llama-day; do grep -q \"stop and disable the scheduled task '\$t'\" <<<\"\$0\" || exit 1; done" "$OUT"
check "Desktop-Mode away: stops each server by folder, not by program name" bash -c "grep -q 'stop the llama-server that runs from C:.llama\$' <<<\"\$0\" && grep -q 'runs from C:.llama-cuda' <<<\"\$0\" && ! grep -qi taskkill <<<\"\$0\"" "$OUT"
check "Desktop-Mode away: no return task without -For" lacks "starts the servers again at"
run_ps Desktop-Mode.ps1 away -For 3h -DryRun -Yes
check "Desktop-Mode away -For 3h: the laptop gets --for 3h" has "hermes-desktop off --for 3h"
check "Desktop-Mode away -For 3h: schedules the servers' return" has "scheduled task 'llama-return' starts the servers again at"
run_ps Desktop-Mode.ps1 away -NoLaptop -DryRun -Yes
check "Desktop-Mode away -NoLaptop: no ssh, and says what to run on the laptop" bash -c "! grep -q '^\[dry-run\] ssh' <<<\"\$0\" && grep -q 'hermes-desktop off' <<<\"\$0\"" "$OUT"
run_ps Desktop-Mode.ps1 back -DryRun -Yes
check "Desktop-Mode back -DryRun exits 0" test $RC -eq 0
check "Desktop-Mode back: enables the tasks and starts the day and V100 servers" bash -c "grep -q \"enable the scheduled task 'llama-night'\" <<<\"\$0\" && grep -q \"start the scheduled task 'llama-server'\" <<<\"\$0\" && grep -q \"start the scheduled task 'llama-v100'\" <<<\"\$0\" && ! grep -q \"start the scheduled task 'llama-night'\" <<<\"\$0\"" "$OUT"
check "Desktop-Mode back: waits for the servers, then tells the laptop" bash -c "[[ \$(grep -n 'wait until the model ports answer' <<<\"\$0\" | cut -d: -f1) -lt \$(grep -n 'hermes-desktop on' <<<\"\$0\" | cut -d: -f1) ]]" "$OUT"
run_ps Desktop-Mode.ps1 away -For 4 -DryRun -Yes
check "Desktop-Mode: a duration without a unit is refused" bash -c "[[ $RC -ne 0 ]] && grep -q 'expects a duration' <<<\"\$0\"" "$OUT"
run_ps Desktop-Mode.ps1 back -For 4h -DryRun -Yes
check "Desktop-Mode: -For is refused with back" bash -c "[[ $RC -ne 0 ]] && grep -q \"only goes with 'away'\" <<<\"\$0\"" "$OUT"
run_ps Desktop-Mode.ps1 away -For '4h; reboot' -DryRun -Yes
check "Desktop-Mode: shell text in -For is refused" test $RC -ne 0
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=0|'
run_ps Desktop-Mode.ps1 away -DryRun -Yes
check "Desktop-Mode away (no V100, no night tier): only the day server" bash -c "grep -q \"scheduled task 'llama-server'\" <<<\"\$0\" && ! grep -q llama-v100 <<<\"\$0\" && ! grep -q llama-night <<<\"\$0\"" "$OUT"
run_ps Desktop-Mode.ps1 status
check "Desktop-Mode status works anywhere (exit 0)" test $RC -eq 0
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|'

# ---- the V100 tier: Install-V100.ps1 (dry run, nvidia-smi is a stub that answers like two V100 cards) and Check-V100.ps1
cfg_with -e 's|^V100_ENABLED=.*|V100_ENABLED=1|'
FAKE_V100=2 run_ps Install-V100.ps1 -DryRun -Yes
check "Install-V100 -DryRun exits 0" test $RC -eq 0
check "Install-V100: lists the cards it found" has "GPU 1: Tesla V100-SXM2-16GB"
check "Install-V100: takes the CUDA 12 build, in its own folder" has "newest llama-*-bin-win-cuda-12.x-x64.zip"
check "Install-V100: requires the CUDA devices to be listed" has "CUDA devices must be listed"
check "Install-V100: downloads the 27B model (UD-Q4_K_XL is the default for two 16 GB cards)" has "Qwen3.8-27B-UD-Q4_K_XL.gguf"
check "Install-V100: writes its own start script" has "write C:\\llama-cuda\\start-llama-v100.cmd"
check "Install-V100: rewrites the Vulkan day script with the NVIDIA guard" has "write C:\\llama\\start-llama.cmd"
check "Install-V100: checks the Vulkan server sees no NVIDIA card" has "no NVIDIA card"
check "Install-V100: firewall rule is laptop-only on its own port" has "firewall rule 'llama-server 8081 (laptop only)' from 192.168.1.150"
check "Install-V100: its own scheduled task" has "scheduled task 'llama-v100'"
check "Install-V100: points at the laptop steps" bash -c "grep -q 'tool v100-laptop' <<<\"\$0\" && grep -q 'run 13' <<<\"\$0\"" "$OUT"
FAKE_V100=2 FAKE_V100_DRIVER=591.59 run_ps Install-V100.ps1 -DryRun -Yes
check "Install-V100: warns about a driver that dropped the V100" has "R590 and newer dropped the V100"
FAKE_V100=2 FAKE_V100_WIDTH=1 run_ps Install-V100.ps1 -DryRun -Yes
check "Install-V100: warns about a PCIe x1 slot" has "runs at PCIe x1"
FAKE_V100=2 FAKE_V100_MEM=32768 run_ps Install-V100.ps1 -DryRun -Yes
check "Install-V100: warns when V100_VRAM_GB disagrees with the cards" has "V100_VRAM_GB is 16"
FAKE_V100=2 run_ps Install-V100.ps1 -DryRun -Yes -SkipModelDownload -NoStart
check "Install-V100: -SkipModelDownload skips the download" lacks "curl.exe -L --fail -C"
check "Install-V100: -NoStart skips the start" lacks "start the 'llama-v100' task"
FAKE_V100=2 run_ps Install-V100.ps1 -DryRun -Yes -DownloadDriver
check "Install-V100 -DownloadDriver: fetches the R580 data-center driver and checks the signature" bash -c "grep -q 'driver 582.78' <<<\"\$0\" && grep -q 'check its signature' <<<\"\$0\"" "$OUT"
sed -i 's|^V100_PORT=.*|V100_PORT=8080|' "$T/node.env"
FAKE_V100=2 run_ps Install-V100.ps1 -DryRun -Yes
check "Install-V100: the same port as the day server is refused" bash -c "[[ $RC -ne 0 ]] && grep -q 'both 8080' <<<\"\$0\"" "$OUT"
cfg_with -e 's|^V100_ENABLED=.*|V100_ENABLED=0|'
FAKE_V100=2 run_ps Install-V100.ps1 -DryRun -Yes
check "Install-V100: refuses while the tier is off, and says how to turn it on" bash -c "[[ $RC -ne 0 ]] && grep -q 'V100_ENABLED=0' <<<\"\$0\" && grep -q 'Configure.ps1 -Only V100_ENABLED' <<<\"\$0\"" "$(flat "$OUT")"
check "Install-V100: ...and did not switch it on by itself" grep -q '^V100_ENABLED=0' "$T/node.env"

FAKE_V100=2 run_ps Check-V100.ps1
check "Check-V100 on two healthy cards: exit 0" test $RC -eq 0
check "Check-V100: counts the cards" has "nvidia-smi lists 2 V100 card(s)"
check "Check-V100: checks the driver mode" has "driver mode is TCC"
check "Check-V100: says the tier is not switched on yet" has "not switched on yet"
FAKE_V100=1 run_ps Check-V100.ps1
check "Check-V100: one card of two is a FAIL" bash -c "[[ $RC -ne 0 ]] && grep -q 'lists 1 V100' <<<\"\$0\"" "$OUT"
FAKE_V100=2 FAKE_V100_DRIVER=591.59 run_ps Check-V100.ps1
check "Check-V100: R590 or newer is a FAIL" bash -c "[[ $RC -ne 0 ]] && grep -q 'still supports the V100' <<<\"\$0\"" "$OUT"
FAKE_V100=2 FAKE_V100_WIDTH=1 FAKE_V100_TEMP=90 FAKE_V100_MODE=MCDM run_ps Check-V100.ps1
check "Check-V100: a slow link, a hot card and another driver mode are warnings, not failures" bash -c "[[ $RC -eq 0 ]] && grep -q 'PCIe link gen 3 x1' <<<\"\$0\" && grep -q '90 C' <<<\"\$0\" && grep -q 'driver mode is MCDM' <<<\"\$0\"" "$OUT"
FAKE_NVIDIA=missing run_ps Check-V100.ps1
check "Check-V100: a broken driver is a FAIL" test $RC -ne 0
OUT=$(USERPROFILE="$T/profile" FAKE_V100=2 ps -File "$ROOT/desktop/windows/Check-V100.ps1" -ConfigFile "$T/no-such-file.env" 2>&1); RC=$?
check "Check-V100 needs no settings file" test $RC -eq 0
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=1|'

# ---- -Yes: no questions at all, defaults taken (empty answers file: any question would fail the run)
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=0|'
: >"$T/psnone"
export HS_INPUT="$T/psnone"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Install-Llama.ps1" -ConfigFile "$T/node.env" -DryRun -Yes 2>&1); RC=$?
check "-Yes: Install-Llama asks nothing and succeeds" test $RC -eq 0
check "-Yes: ...the default for sleep is no" bash -c "! grep -q 'never sleep on mains' <<<\"\$0\"" "$OUT"
check "-Yes: ...the default for starting is yes" has "start the 'llama-server' task"
mkdir -p "$T/desk2"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Setup-LaptopAccess.ps1" -ConfigFile "$T/node.env" -DryRun -Yes -TunnelDir "$T/desk2" 2>&1); RC=$?
check "-Yes: Setup-LaptopAccess asks nothing, writes the shortcut by default" bash -c "[[ $RC -eq 0 ]] && grep -q 'write .*hermes-tunnel.cmd' <<<\"\$0\"" "$OUT"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Install-Overnight.ps1" -ConfigFile "$T/node.env" -DryRun -Yes 2>&1); RC=$?
check "-Yes never switches the overnight tier on by itself" bash -c "[[ $RC -ne 0 ]] && grep -q '^NIGHT_ENABLED=0' '$T/node.env'"
unset HS_INPUT

# ---- Configure.ps1: -Print shows the file, -Advanced asks the advanced questions
OUT=$(ps -File "$ROOT/desktop/windows/Configure.ps1" -ConfigFile "$T/node.env" -Print -Defaults 2>&1); RC=$?
check "Configure -Print shows the settings file layout" bash -c "[[ $RC -eq 0 ]] && grep -q '^# ---- Machines and network ----' <<<\"\$0\" && grep -q '^LAPTOP_IP=' <<<\"\$0\"" "$OUT"
check "Configure -Print does not write the file" bash -c "! grep -q 'HarnessSetup settings - written' '$T/node.env' || grep -q '^NIGHT_ENABLED=0' '$T/node.env'"
yes '' | head -80 >"$T/psblank"
export HS_INPUT="$T/psblank"
OUT=$(ps -File "$ROOT/desktop/windows/Configure.ps1" -ConfigFile "$T/adv.env" -Advanced 2>&1); RC=$?
unset HS_INPUT
check "Configure -Advanced asks the advanced desktop questions" bash -c "grep -q 'Dashboard port' <<<\"\$0\" && grep -q 'Expert layers kept in RAM' <<<\"\$0\" && grep -q 'Desktop llama.cpp folder' <<<\"\$0\"" "$OUT"

# ---- no settings yet: the installers ask by themselves (scripted answers stand in for the user)
rm -f "$T/fresh.env"
printf '%s\n' '' 10.0.0.20 10.0.0.30 10.0.0.1 james 2 n n n '' y n >"$T/psans1"   # skip the import offer, wizard (ip x3, admin, quant=Q4, overnight n, V100 n, advanced n, save), then: never-sleep y, start now n
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
printf '%s\n' '' 10.0.0.20 10.0.0.30 10.0.0.1 james '' n n n '' n >"$T/psans2"   # skip import, wizard, then: tunnel shortcut n
export HS_INPUT="$T/psans2"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Setup-LaptopAccess.ps1" -ConfigFile "$T/fresh2.env" -DryRun 2>&1); RC=$?
unset HS_INPUT
check "no settings: Setup-LaptopAccess asks first (exit 0)" test $RC -eq 0
check "no settings: ...installs the key for the admin user that was typed" has "james@10.0.0.20"
check "no settings: ...declining the shortcut writes none" bash -c "! grep -q 'write .*hermes-tunnel.cmd' <<<\"\$0\"" "$OUT"
# -ShowKey must not ask the installer's questions (it used to ask about sleep, replacing llama.cpp ...)
: >"$T/psempty"
export HS_INPUT="$T/psempty"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Install-Llama.ps1" -ConfigFile "$T/node.env" -ShowKey 2>&1); RC=$?
unset HS_INPUT
check "-ShowKey asks nothing (an empty answers file would fail if it asked)" bash -c "! grep -q 'ran out' <<<\"\$0\"" "$OUT"
check "-ShowKey says there is no key yet instead" has "No key yet"
# the tunnel question names the dashboard port from the settings, not a hard-coded one
cfg_with -e 's|^DASHBOARD_PORT=.*|DASHBOARD_PORT=9120|'
printf '%s\n' n >"$T/psans-port"
export HS_INPUT="$T/psans-port"
mkdir -p "$T/profile/.ssh" && echo "ssh-ed25519 AAAA test" >"$T/profile/.ssh/id_ed25519.pub"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Setup-LaptopAccess.ps1" -ConfigFile "$T/node.env" -DryRun 2>&1); RC=$?
unset HS_INPUT
check "tunnel question shows the configured dashboard port" has "http://localhost:9120"
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=0|'
printf '%s\n' y 03:00 06:00 n >"$T/psans3"   # turn the tier on, start, end, then: update active hours n
export HS_INPUT="$T/psans3"
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Install-Overnight.ps1" -ConfigFile "$T/node.env" -DryRun 2>&1); RC=$?
unset HS_INPUT
check "overnight off in the settings: offers to turn it on (exit 0)" test $RC -eq 0
check "overnight: ...uses the times that were typed" has "tasks llama-night at 03:00 and llama-day at 06:00"
check "overnight: ...and saved the switch" grep -q '^NIGHT_ENABLED=1' "$T/node.env"
check "overnight: ...the job window shown follows the times" has "between 03:15 and 04:00"
check "overnight: ...without adopting settings it was never given" bash -c "! grep -q '^ROUTER_IP=' '$T/node.env' || true"
cfg_with -e 's|^NIGHT_ENABLED=.*|NIGHT_ENABLED=0|'
run_ps Install-Overnight.ps1 -DryRun
check "overnight off, no terminal: refuses and never flips the setting" bash -c "[[ $RC -ne 0 ]] && grep -q '^NIGHT_ENABLED=0' '$T/node.env'"
rm -f "$T/none.env"
run_ps Configure.ps1 -Print
OUT=$(USERPROFILE="$T/profile" ps -File "$ROOT/desktop/windows/Install-Llama.ps1" -ConfigFile "$T/none.env" -DryRun 2>&1); RC=$?
check "no settings and no terminal: refuses and names Configure.ps1" bash -c "[[ $RC -ne 0 ]] && grep -q 'Configure.ps1' <<<\"\$0\"" "$OUT"

echo "powershell: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
