# Step 21: name the local endpoints (the fallback chain itself is written by lib/chain.sh)
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
