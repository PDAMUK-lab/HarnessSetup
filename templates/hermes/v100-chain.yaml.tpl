# Optional V100 tier: the fallback chain with the V100 endpoint in it (the order follows V100_PRIMARY)
fallback_providers:
  - provider: openrouter
    model: "@@OR_FALLBACK_MODEL@@"
  - provider: @@CHAIN1_PROVIDER@@
    model: @@CHAIN1_MODEL@@
  - provider: @@CHAIN2_PROVIDER@@
    model: @@CHAIN2_MODEL@@
  - provider: custom:laptop
    model: @@LAPTOP_MODEL_ALIAS@@
