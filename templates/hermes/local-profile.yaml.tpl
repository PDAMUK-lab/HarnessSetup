# Step 22: the `local` profile never touches the cloud (its model and fallbacks are written by lib/chain.sh)
delegation:
  base_url: http://127.0.0.1:@@LLM_PORT@@/v1   # subagents on the laptop's 9B
  model: @@LAPTOP_MODEL_ALIAS@@
  api_key: local
  max_concurrent_children: 1           # one slot per GPU; more would only queue
  child_timeout_seconds: 1800          # stop a sub-agent that makes no progress for 30 minutes

approvals:
  mode: "@@APPROVAL_MODE@@"                  # the overnight cron jobs and their sub-agents run here
  deny: @@APPROVAL_DENY_YAML@@

auxiliary:
  review:      { provider: main }      # /review on the desktop model
  compression: { provider: main }
