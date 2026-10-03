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

auxiliary:
  review:
    provider: openrouter
    model: "@@OR_REVIEW_MODEL@@"
  compression:
    provider: openrouter
    model: "@@OR_COMPRESSION_MODEL@@"

provider_routing:
  data_collection: "deny"        # skip OpenRouter providers that may store or train on data
