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
      - uses: actions/checkout@v4
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
