# The `mixed` profile (tools/mixed-mode.sh): a clone of the cloud profile whose sub-agents run on the local GPUs.
# The planner, the reviewer and the fallback chain stay as in the cloud profile; lib/chain.sh writes the sub-agents'
# endpoint (the first local one) and their fallbacks (the other local ones, then OpenRouter's worker model).
delegation:
  max_concurrent_children: 1           # one slot per GPU; more would only queue
  child_timeout_seconds: 1800          # stop a sub-agent that makes no progress for 30 minutes
