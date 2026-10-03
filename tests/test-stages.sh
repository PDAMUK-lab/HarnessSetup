#!/usr/bin/env bash
# End-user style dry runs: drive every stage through ./setup.sh with --dry-run and check what it would do.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { local n=$1; shift; if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi; }

sed -E \
  -e 's|^OR_WORKER_MODEL=.*|OR_WORKER_MODEL=vendor-a/worker|' -e 's|^OR_REVIEW_MODEL=.*|OR_REVIEW_MODEL=vendor-b/reviewer|' \
  -e 's|^OR_COMPRESSION_MODEL=.*|OR_COMPRESSION_MODEL=vendor-a/mid|' -e 's|^OR_FALLBACK_MODEL=.*|OR_FALLBACK_MODEL=vendor-c/fallback|' \
  "$ROOT/config/node.env.example" >"$T/node.env"
export NODE_ENV="$T/node.env" DESTDIR="$T/root" DRY_RUN_SHOW=0

dry() { # dry ID [opts] -> output in $OUT, status in $RC
  OUT=$("$ROOT/setup.sh" run "$@" --dry-run --yes 2>&1); RC=$?
  OUT=${OUT//\\/}   # run() prints with %q escaping; drop the backslashes
}
has() { grep -qF -- "$1" <<<"$OUT"; }
hasre() { grep -qE -- "$1" <<<"$OUT"; }

# ---- the dispatcher itself
OUT=$("$ROOT/setup.sh" list 2>&1)
check "list shows every stage" bash -c "[[ \$(grep -cE '^[0-9]{2} ' <<<'$OUT') -ge 4 ]]"
OUT=$("$ROOT/setup.sh" run 99 2>&1); RC=$?
check "unknown stage is an error" test "$RC" -ne 0
OUT=$(NODE_ENV="$T/missing.env" "$ROOT/setup.sh" run 01 --dry-run 2>&1); RC=$?
check "missing node.env gives a helpful error" bash -c "[[ $RC -ne 0 ]] && grep -q 'cp config/node.env.example' <<<'$OUT'"

# ---- stage 01
dry 01 --skip-nvidia
check "01: exits 0" test "$RC" -eq 0
check "01: enables non-free components" has "contrib non-free non-free-firmware"
check "01: ignores the lid switch" has "lid.conf"
check "01: masks sleep targets" has "mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
check "01: sets up zram" has "systemd-zram-setup@zram0.service"
check "01: --skip-nvidia installs no NVIDIA package" bash -c "! grep -q nvidia-driver <<<'$OUT'"
dry 01
check "01: installs the 550-series package set" has "nvidia-kernel-dkms nvidia-driver nvidia-smi"
check "01: enables nvidia-persistenced" has "enable nvidia-persistenced"
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

# ---- bookkeeping: a marker makes the stage show as done and 'next' skips it
mkdir -p "$DESTDIR/var/lib/harness-setup/done" && echo now >"$DESTDIR/var/lib/harness-setup/done/01"
OUT=$("$ROOT/setup.sh" list 2>&1)
check "list marks completed stages" grep -qE '^01 .*\[done\]' <<<"$OUT"
check "list leaves others open" bash -c "! grep -E '^02 ' <<<'$OUT' | grep -q done"

echo "stages: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
