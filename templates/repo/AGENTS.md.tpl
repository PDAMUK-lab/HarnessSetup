# Agent rules for this repo

## Build and test
- Install: `@@INSTALL_CMD@@`
- Test (must pass before any push): `@@TEST_CMD@@`
- Lint: `@@LINT_CMD@@`
- Package (what CI publishes): `@@PACKAGE_CMD@@` -> `dist/`

## Git
- Never commit to or push `main`. Work on `hermes/<short-topic>` branches.
- One logical change per branch. Rebase on `origin/main` before pushing.
- Before opening a PR, delegate an independent review of the full diff to a
  subagent, giving it the task, this file and the test output. Fix what it finds,
  re-run the tests, and summarise the review in the PR body.
- Open PRs with `gh pr create`. Body: what changed, why, the test output and the review summary.
- Use `--draft` unless all tests pass locally.
- Never edit `.github/workflows/`. The token cannot push those changes.

## Releases
- Version lives in: `@@VERSION_FILE@@`
- Changelog: `CHANGELOG.md`, newest section first.
- Semantic versioning. Tags are `vX.Y.Z` on the release PR's merge commit.
- Never delete or move a tag. Fix mistakes with a new patch release.

## Machine and boundaries
- You have passwordless sudo on this laptop. Install missing system packages with
  `sudo apt install`, and list each one in the PR body so the setup stays reproducible.
- Do not add project dependencies without saying why in the PR.
- Secrets never go in code, logs or PR text.
