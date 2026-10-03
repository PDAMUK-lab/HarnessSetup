# Step 22: the `local` profile never touches the cloud (its model and fallbacks are written by lib/chain.sh)
delegation:
  base_url: http://127.0.0.1:@@LLM_PORT@@/v1   # subagents on the laptop's 9B
  model: @@LAPTOP_MODEL_ALIAS@@
  api_key: local
  max_concurrent_children: 1           # one slot per GPU; more would only queue

auxiliary:
  review:      { provider: main }      # /review on the desktop model
  compression: { provider: main }
