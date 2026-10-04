# Step 11: planner / workers / reviewer on OpenRouter
terminal:
  backend: local                 # runs as the hermes user
  cwd: @@AGENT_HOME@@/repos

agent:
  reasoning_effort: @@REASONING_EFFORT@@

delegation:
  provider: openrouter
  model: "@@OR_WORKER_MODEL@@"
  max_concurrent_children: @@MAX_CONCURRENT_CHILDREN@@
  max_iterations: @@MAX_ITERATIONS@@
  worktree_isolation: true       # each subagent works on its own branch and worktree
  child_timeout_seconds: 1800    # stop a sub-agent that makes no progress for 30 minutes (Hermes default: never)
  reasoning_effort: "@@WORKER_EFFORT_VALUE@@"   # sub-agents; empty = the planner's effort (setting WORKER_EFFORT)
  # fallback_providers for sub-agents is written by lib/chain.sh with the main chain

approvals:
  mode: "@@APPROVAL_MODE@@"            # off = no prompts for the agent, its sub-agents or cron (quoted: YAML reads a bare off as false)
  deny: @@APPROVAL_DENY_YAML@@   # refused in every mode (setting APPROVAL_DENY)

auxiliary:
  review:
    provider: openrouter
    model: "@@OR_REVIEW_MODEL@@"
  compression:
    provider: openrouter
    model: "@@OR_COMPRESSION_MODEL@@"

provider_routing:
  data_collection: "deny"        # skip OpenRouter providers that may store or train on data
