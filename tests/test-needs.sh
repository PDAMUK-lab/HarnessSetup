#!/usr/bin/env bash
# Every stage and tool declares, in its "# NEEDS:" header, the settings it uses (directly or through the
# templates it renders), so the dispatcher can validate or ask for them. A setting used but not declared would
# reach the script unchecked (or unbound) when the settings file is short or hand-edited.
# It also checks the "# ONLINE: yes" header: only stages 05, 07 and 12 need the internet, and the value must be 'yes'.
exec </dev/null
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
schema = {}
for line in open(f"{root}/config/settings.schema"):
    if line.startswith('#') or not line.strip():
        continue
    f = line.rstrip('\n').split('|', 7)
    schema[f[0]] = f
ALWAYS = {'LAPTOP_IP', 'DESKTOP_IP', 'ADMIN_USER'}   # the dispatcher checks these for every script
WANT_ONLINE = {'05', '07', '12'}                     # the stages that need GitHub / OpenRouter
bad = 0
checked = 0
online = []
for path in sorted(glob.glob(f"{root}/laptop/[0-9][0-9]-*.sh") + glob.glob(f"{root}/tools/*.sh")):
    text = open(path).read()
    rel = os.path.relpath(path, root)
    m = re.search(r'^# ONLINE: *(.*)$', text, re.M)
    if m:
        val = m.group(1).strip()
        if val != 'yes':
            bad += 1
            print(f"FAIL: {rel}: ONLINE must be 'yes', got '{val}'")
        else:
            online.append(os.path.basename(path).split('-')[0])
    m = re.search(r'^# NEEDS: *(.*)$', text, re.M)
    if not m:
        continue                       # no header = needs no settings (adopt-repo)
    declared = {k.split('=')[0] for k in m.group(1).split() if k != '-'}
    body = '\n'.join(l for l in text.split('\n') if not l.lstrip().startswith('#'))
    used = set()
    for k in schema:
        if re.search(r'\$\{?' + k + r'\b', body):
            used.add(k)
    for t in re.findall(r'templates/[A-Za-z0-9_./-]+', body):
        tp = f"{root}/{t}"
        if os.path.isfile(tp):
            used |= {k for k in re.findall(r'@@([A-Z0-9_]+)@@', open(tp).read()) if k in schema}
    # settings read by name through ${!v} loops are listed in the script itself
    missing = sorted(used - declared - ALWAYS)
    unknown = sorted(k for k in declared if k not in schema)
    checked += 1
    if missing or unknown:
        bad += 1
        print(f"FAIL: {rel}: " + (f"uses but does not declare {' '.join(missing)}; " if missing else '') + (f"declares unknown settings {' '.join(unknown)}" if unknown else ''))
if set(online) != WANT_ONLINE:
    bad += 1
    print(f"FAIL: the internet-only stages must be exactly {', '.join(sorted(WANT_ONLINE))} (# ONLINE: yes); found {', '.join(sorted(online)) or 'none'}")
print(f"needs: {checked - bad} passed, {bad} failed")
sys.exit(1 if bad else 0)
PY
