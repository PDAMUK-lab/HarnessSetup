---
name: release
description: Cut a versioned release of the current repo. Stage 1 opens a release PR with the version bump and changelog. Stage 2 tags the merged PR and verifies the GitHub release.
---
# Release

Input: a version such as 1.4.0, without the v. If none is given, propose one from the commits since the last tag (semantic versioning) and ask.

First check: if a PR titled "Release v<version>" is already merged and the tag v<version> does not exist, go straight to Stage 2.

## Stage 1: release PR
1. git fetch --tags origin, switch to main, pull with --ff-only.
2. Read AGENTS.md for the version file, changelog and the build, test and package commands. Run the full test suite. Stop and report if it fails.
3. Create branch hermes/release-<version>. Bump the version. Add a CHANGELOG.md section summarising changes since the last tag (git log <last-tag>..HEAD --oneline, and merged PR titles from gh pr list).
4. Run the package command to prove the release artifacts build.
5. Push, then open a PR titled "Release v<version>" with the changelog section as its body. Report the PR link and stop. Never merge it yourself.

## Stage 2: tag and release
1. Confirm the PR is merged: gh pr view <number> --json state,mergeCommit.
2. git fetch origin, then tag the merge commit: git tag -a v<version> <merge sha> -m "v<version>", and git push origin v<version>.
3. If .github/workflows/release.yml exists, find its run with gh run list --workflow release.yml -L 1, wait with gh run watch, and report the outcome.
4. If there is no release workflow, run gh release create v<version> --verify-tag --title "v<version>" --notes-file <the changelog section> with the artifacts from the package command.
5. Finish by checking gh release view v<version> and report its URL and assets.
6. Never delete or move a tag. If something is wrong, release the next patch version.
