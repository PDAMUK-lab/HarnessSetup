# .github/workflows/test.yml - runs on every PR; make it a required check on main
name: test
on:
  pull_request:
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          @@INSTALL_CMD@@
      - run: |
          @@TEST_CMD@@
