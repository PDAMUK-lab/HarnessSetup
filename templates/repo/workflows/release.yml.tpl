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
      - run: @@INSTALL_CMD@@
      - run: @@TEST_CMD@@
      - run: @@PACKAGE_CMD@@            # output in dist/
      - name: Publish
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" dist/* --verify-tag --generate-notes \
            || gh release upload "$GITHUB_REF_NAME" dist/* --clobber
