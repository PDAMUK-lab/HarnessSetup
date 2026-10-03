# Optional V100 tier: the `local` profile's model and fallbacks (still nothing that reaches the cloud)
model:
  provider: @@CHAIN1_PROVIDER@@
  default: @@CHAIN1_MODEL@@

fallback_providers:
  - provider: @@CHAIN2_PROVIDER@@
    model: @@CHAIN2_MODEL@@
  - provider: custom:laptop
    model: @@LAPTOP_MODEL_ALIAS@@
