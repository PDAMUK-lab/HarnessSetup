#!/usr/bin/env bash
# release-notes.sh [VERSION]  - print the CHANGELOG.md section for VERSION (default: the VERSION file); fails if there is none
set -euo pipefail
cd "$(dirname "$0")/../.."
v=${1:-$(tr -d '[:space:]' <VERSION)}
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-notes: '$v' is not a version like 1.2.3" >&2; exit 1; }
notes=$(awk -v h="## $v" '$0 == h { f = 1; next } /^## / { if (f) exit } f' CHANGELOG.md)
notes=$(sed -e '/./,$!d' <<<"$notes")   # drop leading blank lines
[[ -n ${notes//[[:space:]]/} ]] || { echo "release-notes: CHANGELOG.md has no '## $v' section" >&2; exit 1; }
printf '%s\n' "$notes"
