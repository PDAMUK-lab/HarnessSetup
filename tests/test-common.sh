#!/usr/bin/env bash
# Unit tests for lib/common.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
check() { # check "name" cmd...   (cmd must succeed)
  local n=$1; shift
  if "$@"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $n"; fi
}
eq() { [[ $1 == "$2" ]]; }

# --- render_template
printf 'a=@@FOO@@\nb=@@BAR@@ x\n' >"$T/t1"
FOO='x/y&z' BAR=''
export FOO BAR
render_template "$T/t1"
check "render substitutes / & and empty values" eq "$RENDERED" $'a=x/y&z\nb= x\n'
check "render keeps the trailing newline" eq "${RENDERED: -1}" $'\n'
printf 'a=@@NOPE_UNDEFINED@@\n' >"$T/t2"
check "render dies on an undefined variable" bash -c "source '$ROOT/lib/common.sh'; ! (render_template '$T/t2') 2>/dev/null"

# shellcheck disable=SC2034  # DESTDIR/DRY_RUN/NODE_ENV are read by common.sh
# --- put_file / install_template with DESTDIR
( DESTDIR="$T/root"; printf 'hi\n' | put_file /etc/x/y.conf 640 )
check "put_file creates parents" test -f "$T/root/etc/x/y.conf"
check "put_file sets mode" eq "$(stat -c %a "$T/root/etc/x/y.conf")" 640
( DRY_RUN=1; DESTDIR="$T/root"; printf 'no\n' | put_file /etc/dry 644 ) 2>/dev/null
check "put_file writes nothing in a dry run" test ! -e "$T/root/etc/dry"

# --- run under DRY_RUN
out=$(DRY_RUN=1 run touch "$T/never" 2>&1)
check "run prints the command in a dry run" test "$out" = "[dry-run] touch $T/never"
check "run does not execute in a dry run" test ! -e "$T/never"

# --- require_vars
check "require_vars accepts a set variable" bash -c "source '$ROOT/lib/common.sh'; GOOD=1; require_vars GOOD"
check "require_vars rejects empty" bash -c "source '$ROOT/lib/common.sh'; EMPTY=''; ! (require_vars EMPTY) 2>/dev/null"
check "require_vars rejects <placeholder>" bash -c "source '$ROOT/lib/common.sh'; PH='<x>'; ! (require_vars PH) 2>/dev/null"

# --- load_config with the shipped example
( NODE_ENV="$ROOT/config/node.env.example"; load_config; eq "$LAPTOP_NKVO_FLAG" -nkvo && eq "$CRON_REPO" yourrepo && eq "$HERMES_BIN" /home/hermes/.local/bin/hermes )
check "load_config derives values from the example" test $? -eq 0
check "load_config fails when the file is missing" bash -c "source '$ROOT/lib/common.sh'; NODE_ENV=/nonexistent; ! (load_config) 2>/dev/null"

# --- download_gguf (file:// URLs stand in for Hugging Face)
printf 'GGUFxxxx' >"$T/good.gguf"; printf '<html>404</html>' >"$T/bad.gguf"
( download_gguf "file://$T/good.gguf" "$T/out-good.gguf" ) >/dev/null 2>&1
check "download_gguf accepts a GGUF file" eq "$(head -c4 "$T/out-good.gguf" 2>/dev/null)" GGUF
check "download_gguf rejects an HTML page" bash -c "source '$ROOT/lib/common.sh'; ! (download_gguf 'file://$T/bad.gguf' '$T/out-bad.gguf') >/dev/null 2>&1"

echo "common.sh: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
