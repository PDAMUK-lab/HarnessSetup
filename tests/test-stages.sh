#!/usr/bin/env bash
# End-user style dry runs: drive every stage through ./setup.sh with --dry-run and check what it would do.
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }

sed -E \
  -e 's|^OR_WORKER_MODEL=.*|OR_WORKER_MODEL=vendor-a/worker|' -e 's|^OR_REVIEW_MODEL=.*|OR_REVIEW_MODEL=vendor-b/reviewer|' \
  -e 's|^OR_COMPRESSION_MODEL=.*|OR_COMPRESSION_MODEL=vendor-a/mid|' -e 's|^OR_FALLBACK_MODEL=.*|OR_FALLBACK_MODEL=vendor-c/fallback|' \
  -e 's|^GITHUB_ORG=.*|GITHUB_ORG=acme|' -e 's|^GITHUB_REPOS=.*|GITHUB_REPOS="app lib"|' \
  -e 's|^GITHUB_MACHINE_USER=.*|GITHUB_MACHINE_USER=acme-bot|' -e 's|^GITHUB_NOREPLY_EMAIL=.*|GITHUB_NOREPLY_EMAIL=42+acme-bot@users.noreply.github.com|' \
  "$ROOT/config/node.env.example" >"$T/node.env"
export NODE_ENV="$T/node.env" DESTDIR="$T/root" DRY_RUN_SHOW=0
# stubs for sudo/ufw/hermes keep these dry runs independent of the machine they run on
export PATH="$ROOT/tests/fakebin:$PATH" FAKE_LOG=/dev/null

dry() { # dry ID [opts] -> output in $OUT, status in $RC
  OUT=$("$ROOT/setup.sh" run "$@" --dry-run --yes 2>&1); RC=$?
  OUT=${OUT//\\/}   # run() prints with %q escaping; drop the backslashes
}
has() { [[ $1 == -- ]] && shift; grep -qF -- "$1" <<<"$OUT"; }
hasre() { grep -qE -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
line_of() { grep -nF -- "$1" <<<"$OUT" | head -1 | cut -d: -f1; }   # first line of OUT that has the text

# ---- the dispatcher itself
OUT=$("$ROOT/setup.sh" list 2>&1)
check "list shows every stage" bash -c "[[ \$(grep -cE '^[0-9]{2} ' <<<'$OUT') -ge 4 ]]"
OUT=$("$ROOT/setup.sh" run 99 2>&1); RC=$?
check "unknown stage is an error" test "$RC" -ne 0
OUT=$(NODE_ENV="$T/missing.env" "$ROOT/setup.sh" run 01 --dry-run 2>&1); RC=$?
check "missing settings without a terminal: refuses and points at configure" bash -c "[[ $RC -ne 0 ]] && grep -q './setup.sh configure' <<<'$OUT'"

# ---- stage 01
dry 01 --skip-nvidia
check "01: exits 0" test "$RC" -eq 0
check "01: enables non-free components" has "contrib non-free non-free-firmware"
check "01: ignores the lid switch" has "lid.conf"
check "01: masks sleep targets" has "mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
check "01: sets up zram" has "systemd-zram-generator"
check "01: starts the zram swap unit (the setup service only creates the device)" has "start /dev/zram0"
check "01: no zram setup-service start (it never turns the swap on)" lacks "start systemd-zram-setup@zram0.service"
check "01: lid and sleep come before the package upgrade (a closed lid must not break Steps 2-3)" bash -c "[[ $(line_of lid.conf) -gt 0 && $(line_of lid.conf) -lt $(line_of full-upgrade) ]]"
check "01: --skip-nvidia installs no NVIDIA package" bash -c "! grep -q nvidia-driver <<<'$OUT'"
dry 01 --nvidia
check "01: installs the 550-series package set" has "nvidia-kernel-dkms nvidia-driver nvidia-smi"
check "01: enables nvidia-persistenced" has "enable nvidia-persistenced"
OUT=$(HS_KERNEL=6.17.8+deb13-amd64 "$ROOT/setup.sh" run 01 --nvidia --dry-run --yes 2>&1)
check "01: warns about a 6.16+ kernel (backports) before building the 550 module" has "does not build on 6.16"
OUT=$(HS_KERNEL=6.12.48+deb13-amd64 "$ROOT/setup.sh" run 01 --nvidia --dry-run --yes 2>&1)
check "01: no kernel warning on trixie's 6.12" lacks "does not build on 6.16"
check "static: no script ever installs the Pascal-breaking NVIDIA packages" bash -c "! grep -rnE 'nvidia-open|cuda-drivers|nvidia-driver-5[6-9]|backports' '$ROOT/laptop' | grep -vE 'die |warn |fail_or_warn|dpkg-query|^[^:]+:[0-9]+:[[:space:]]*#'"

# ---- stage 02
dry 02
check "02: refuses (warns in dry run) without an authorized key" has "authorized_keys is empty"
check "02: writes the hardening drop-in" has "10-hardening.conf"
check "02: reloads ssh" has "reload ssh"

# ---- stage 03
dry 03
check "03: exits 0" test "$RC" -eq 0
check "03: creates the agent user" has "adduser --disabled-password --comment '' hermes"
check "03: enables linger" has "enable-linger hermes"
check "03: writes the sudoers file mode 440" has "90-hermes (mode 440"

# ---- stage 04
dry 04
check "04: installs build tools incl. python3-yaml" has "python3-yaml"
check "04: installs ufw" has "ufw"
check "04: --docker adds the agent to the docker group" bash -c "'$ROOT/setup.sh' run 04 --dry-run --yes --docker 2>&1 | grep -q 'usermod -aG docker hermes'"

# ---- stage 09
lineno() { grep -nF -- "$1" <<<"$OUT" | head -1 | cut -d: -f1; }
dry 09
check "09: exits 0" test "$RC" -eq 0
check "09: CUDA build" has "DGGML_CUDA=ON"
check "09: compiles the FlashAttention kernel for the f16-K / q8_0-V cache it uses" has "f16-q8_0"
check "09: for Pascal (compute capability 6.1)" has "DCMAKE_CUDA_ARCHITECTURES=61"
check "09: host compiler g++-13" has "DCMAKE_CUDA_HOST_COMPILER=g++-13"
check "09: installs into /opt/llama.cpp/bin" has "/opt/llama.cpp/bin"
dry 09 --vulkan
check "09: --vulkan uses the Vulkan backend" has "DGGML_VULKAN=ON"
check "09: --vulkan drops the CUDA flags" lacks "DGGML_CUDA"
check "09: --vulkan installs spirv-headers (cmake configure fails without it)" has "spirv-headers"
check "static: 09 verifies with --list-devices, not --version" bash -c "grep -q -- '--list-devices' '$ROOT/laptop/09-llama-cpp.sh' && ! grep -q 'llama-server --version' '$ROOT/laptop/09-llama-cpp.sh'"

# ---- stage 10
dry 10
check "10: exits 0" test "$RC" -eq 0
check "10: creates the llm system user" has "adduser --system --group --home /srv/llm llm"
check "10: downloads as llm and fails on HTTP errors" hasre "(runuser -u llm --|sudo -u llm) curl --fail"
check "10: download is resumable" has -- "--continue-at"
check "10: installs the systemd unit" has "llama-server.service"
check "10: enables and starts it" has "enable --now llama-server"
check "10: no benchmark unless asked" lacks "llama-bench"
dry 10 --bench
check "10: --bench runs llama-bench with the guide's flags" has "-nkvo 0,1 -d 0,32768"
dry 10 --no-start
check "10: --no-start does not enable the service" lacks "enable --now"

# ---- stages 11 and 12 (dry)
dry 11
check "11: exits 0" test "$RC" -eq 0
check "11: shows the fallback chain it would write" has "fallback_providers"
check "11: creates the local profile from a clone" has "hermes profile create local --clone"
check "11: clears stale cloud keys from the profile" has "after deleting delegation.provider"
dry 12
check "12: exits 0" test "$RC" -eq 0
check "12: creates nightly-tests paused" has "--name nightly-tests --paused"
check "12: creates release-watcher paused by default" has "--name release-watcher --paused"
dry 12 --active
check "12: --active creates the watcher running" lacks "release-watcher --paused"

# ---- stage 13
dry 13
check "13: exits 0" test "$RC" -eq 0
check "13: reset comes before enable" test "$(lineno 'ufw --force reset')" -lt "$(lineno 'ufw --force enable')"
deny=$(lineno 'deny out to 192.168.1.0/24')
check "13: DNS allow precedes the LAN deny" test "$(lineno 'allow out to 192.168.1.1 port 53')" -lt "$deny"
check "13: desktop model allow precedes the LAN deny" test "$(lineno 'allow out to 192.168.1.100 port 8080')" -lt "$deny"
check "13: NTP allow precedes the LAN deny" test "$(lineno 'allow out 123/udp')" -lt "$deny"
check "13: DHCP allow precedes the LAN deny" test "$(lineno 'allow out 67/udp')" -lt "$deny"
check "13: default-deny outgoing is set" has "default deny outgoing"
check "13: default-deny incoming is set" has "default deny incoming"
check "13: only the desktop may SSH in" has "allow in from 192.168.1.100 to any port 22"
check "13: 443 allowed out" has "allow out 443/tcp"
check "13: env files locked to 600" has "chmod 600 /home/hermes/.hermes/.env"
OUT=$(SSH_CLIENT="10.9.9.9 5555 22" "$ROOT/setup.sh" run 13 --dry-run --yes 2>&1)
check "13: warns before cutting off an SSH session from another address" has "would cut you off"
OUT=$(SSH_CLIENT="192.168.1.100 5555 22" "$ROOT/setup.sh" run 13 --dry-run --yes 2>&1)
check "13: no warning when connected from the allowed address" lacks "would cut you off"
OUT=$(SSH_CLIENT="10.9.9.9 5555 22" "$ROOT/setup.sh" run 13 --dry-run --yes --force 2>&1)
check "13: --force silences the lock-out warning" lacks "would cut you off"
dry 13
check "13: no V100 rule while the tier is off" bash -c "! grep -q 'port 8081' <<<\"\$0\"" "$OUT"
sed 's|^V100_ENABLED=.*|V100_ENABLED=1|' "$T/node.env" >"$T/v100.env"
OUT=$(NODE_ENV="$T/v100.env" "$ROOT/setup.sh" run 13 --dry-run --yes 2>&1); OUT=${OUT//\\/}
check "13: the V100 port is allowed for the desktop" has "allow out to 192.168.1.100 port 8081 proto tcp"
check "13: ...before the LAN deny" test "$(lineno 'allow out to 192.168.1.100 port 8081')" -lt "$(lineno 'deny out to 192.168.1.0/24')"
sed 's|^V100_PORT=.*|V100_PORT=9001|' "$T/v100.env" >"$T/v100b.env"
OUT=$(NODE_ENV="$T/v100b.env" "$ROOT/setup.sh" run 13 --dry-run --yes 2>&1); OUT=${OUT//\\/}
check "13: the V100 port follows the setting" has "port 9001 proto tcp"

# ---- bookkeeping: a marker makes the stage show as done and 'next' skips it
mkdir -p "$DESTDIR/var/lib/harness-setup/done" && echo now >"$DESTDIR/var/lib/harness-setup/done/01"
OUT=$("$ROOT/setup.sh" list 2>&1)
check "list marks completed stages" grep -qE '^01 .*\[done\]' <<<"$OUT"
check "list leaves others open" bash -c "! grep -E '^02 ' <<<'$OUT' | grep -q done"

echo "stages: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
