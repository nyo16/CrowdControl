# CrowdControl examples

Runnable scripts demonstrating common usage patterns. Each file is a
standalone `.exs` that you can execute with:

```sh
mix run examples/<name>.exs
```

You need a working `claude`, `opencode`, or `omp` binary on your `PATH` and a
valid API key in `ANTHROPIC_API_KEY` (or pass `:api_key` per-session).

| Example | Demonstrates |
|---------|--------------|
| [`single_session.exs`](single_session.exs) | Basic subscribe + streaming loop for one session |
| [`parallel_models.exs`](parallel_models.exs) | Run the same prompt across sonnet / opus / haiku side-by-side |
| [`streaming.exs`](streaming.exs) | Render assistant deltas as they arrive |
| [`multi_turn.exs`](multi_turn.exs) | Multi-turn conversation against a single session |
| [`custom_mcp.exs`](custom_mcp.exs) | Wire up an MCP config and restrict tools |
| [`error_handling.exs`](error_handling.exs) | Timeouts, oversized prompts, supervisor cap |
| [`bounded_pool.exs`](bounded_pool.exs) | Saturate `max_sessions` and degrade gracefully |
| [`omp_agent.exs`](omp_agent.exs) | Drive [omp](https://omp.sh/) over JSON-RPC and mix it with Claude Code |
| [`omp_custom_provider.exs`](omp_custom_provider.exs) | Point omp at a self-hosted vLLM / OpenAI-compatible endpoint |
| [`sandbox_lifecycle.exs`](sandbox_lifecycle.exs) | The sandbox itself, one step at a time: FIFO, tee file, a mid-line byte-exact reattach, and a killed CLI ending the session. Needs Docker and `alpine`, no API key — see [`docs/sandboxes.md`](../docs/sandboxes.md) |
| [`sandboxd_docker.exs`](sandboxd_docker.exs) | Drive a sandbox over HTTP with `Backend.Sandboxd` + `Provider.Docker` (needs Docker and a sandboxd image) |
| [`compose_stack.exs`](compose_stack.exs) | A two-service stack: internal-only sandbox plus an egress proxy sidecar (needs Docker and a proxy image) |
| [`kubernetes_task.exs`](kubernetes_task.exs) | Fan out N sandboxes as concurrent tasks, one Pod each, and verify nothing leaked. Needs a cluster and `:kubereq`; no API key and no custom image — the in-Pod CLI is a `sh` loop wired in through `CrowdControl.Agent` |
| [`gce_spot_vm.exs`](gce_spot_vm.exs) | **BILLABLE** — one GCE spot VM per sandbox, reached over an SSH tunnel (needs `:gcp_compute` and GCP credentials) |
