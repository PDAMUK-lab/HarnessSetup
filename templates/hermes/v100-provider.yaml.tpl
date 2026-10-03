# Optional V100 tier: one more local endpoint on the desktop (same API key as the desktop's other server)
providers:
  desktop-v100:
    api: http://@@DESKTOP_IP@@:@@V100_PORT@@/v1
    key_env: DESKTOP_LLM_KEY
    default_model: @@V100_MODEL_ALIAS@@
    context_length: @@V100_CTX@@
