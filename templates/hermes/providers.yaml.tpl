# Step 21: name the local endpoints and build the fallback chain
providers:
  laptop:
    api: http://127.0.0.1:@@LLM_PORT@@/v1
    default_model: @@LAPTOP_MODEL_ALIAS@@
    context_length: @@LAPTOP_CTX@@
  desktop:
    api: http://@@DESKTOP_IP@@:@@LLM_PORT@@/v1
    key_env: DESKTOP_LLM_KEY
    default_model: @@DESKTOP_MODEL_ALIAS@@
    context_length: @@DESKTOP_CTX@@

fallback_providers:
  - provider: openrouter
    model: "@@OR_FALLBACK_MODEL@@"
  - provider: custom:desktop
    model: @@DESKTOP_MODEL_ALIAS@@
  - provider: custom:laptop
    model: @@LAPTOP_MODEL_ALIAS@@
