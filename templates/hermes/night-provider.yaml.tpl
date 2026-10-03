# Step 31: third endpoint for the overnight Qwen3.8-27B tier (local profile only)
providers:
  desktop-night:
    api: http://@@DESKTOP_IP@@:@@LLM_PORT@@/v1
    key_env: DESKTOP_LLM_KEY
    default_model: @@NIGHT_MODEL_ALIAS@@
    context_length: @@DESKTOP_CTX@@
