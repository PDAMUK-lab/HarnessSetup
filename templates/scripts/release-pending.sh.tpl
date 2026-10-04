#!/usr/bin/env bash
# Wakes the agent only when a merged "Release vX.Y.Z" PR has no tag yet
cd @@AGENT_HOME@@/repos-cron/@@CRON_REPO@@ || exit 1
git fetch -q --tags origin
# GitHub search matches whole words, so 'v' never matches 'v1.2.3': search the word Release, then keep exactly "Release vX.Y.Z"
for v in $(gh pr list --state merged --search 'Release in:title' --limit 100 --json title -q '.[].title' \
           | grep -E '^Release v[0-9]+\.[0-9]+\.[0-9]+$' | cut -d' ' -f2); do
  if ! git rev-parse -q --verify "refs/tags/$v" >/dev/null; then
    echo "{\"wakeAgent\": true, \"context\": {\"version\": \"$v\"}}"
    exit 0
  fi
done
echo '{"wakeAgent": false}'
