# .github/workflows/release.yml - runs when the agent pushes a vX.Y.Z tag
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - name: Tag must be on main (never release an unreviewed commit)
        run: git merge-base --is-ancestor "$GITHUB_SHA" origin/main
      - run: |
          @@INSTALL_CMD@@
      - run: |
          @@TEST_CMD@@
      - name: Package (output in dist/)
        run: |
          @@PACKAGE_CMD@@
      - name: Publish
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" dist/* --verify-tag --generate-notes \
            || gh release upload "$GITHUB_REF_NAME" dist/* --clobber
