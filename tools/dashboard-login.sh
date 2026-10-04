#!/usr/bin/env bash
# TITLE: Set the dashboard's user name and password (needed when DASHBOARD_FROM lets browsers on the LAN in)
# RUN-AS: hermes
# GUIDE: extension (dashboard from a phone or another laptop)
# NEEDS: DASHBOARD_PORT
# Usage:  dashboard-login.sh   asks for a user name and a password (twice) and writes Hermes's own login to the dashboard:
#         dashboard.basic_auth.{username,password_hash,secret} in ~/.hermes/config.yaml. Only the scrypt hash is stored.
#         Run it again to change the password; stage 08 runs it when the dashboard needs one and has none.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
for a in "$@"; do common_flag "$a" || die "unknown option: $a"; done
load_config
cfg=$HOME/.hermes/config.yaml
[[ -f $cfg || $DRY_RUN == 1 ]] || die "no $cfg yet: run stage 06 first"

user=''
read -rp "Dashboard user name [hermes]: " user || true
user=${user:-hermes}
[[ $user =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "use letters, digits, '.', '_' or '-' in the user name"
pw='' pw2=''
read -rsp "Password (12 characters or more): " pw || true; echo >&2
((${#pw} >= 12)) || die "the password must have at least 12 characters"
read -rsp "Password again: " pw2 || true; echo >&2
[[ $pw == "$pw2" ]] || die "the two passwords differ"
if [[ $DRY_RUN == 1 ]]; then log "[dry-run] would write dashboard.basic_auth for '$user' to $cfg and restart the dashboard"; exit 0; fi

frag=$(mktemp)
trap 'rm -f "$frag"' EXIT
# the same scrypt format as Hermes's plugins/dashboard_auth/basic hash_password; the password goes through stdin, not argv
# shellcheck disable=SC2016  # the YAML is built by python
printf '%s' "$pw" | python3 -c '
import base64, hashlib, secrets, sys
pw = sys.stdin.read().encode("utf-8")
salt = secrets.token_bytes(16)
dk = hashlib.scrypt(pw, salt=salt, n=2**14, r=8, p=1, dklen=32, maxmem=0)
h = "scrypt$16384$8$1$%s$%s" % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode())
print("dashboard:\n  basic_auth:\n    username: \"%s\"\n    password_hash: \"%s\"\n    secret: \"%s\"" % (sys.argv[1], h, secrets.token_hex(32)))
' "$user" >"$frag"
chmod 600 "$frag"
python3 "$HS_ROOT/lib/merge_yaml.py" "$cfg" "$frag"
chmod 600 "$cfg"
systemctl --user restart hermes-dashboard 2>/dev/null || warn "restart the dashboard: systemctl --user restart hermes-dashboard"
ok "dashboard login set for '$user' (the password itself is not stored)"
