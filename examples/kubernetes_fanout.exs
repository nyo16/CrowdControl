# A bounded fan-out over Kubernetes: many tasks, different parameters each, at
# most N sandboxes alive at once, one report at the end.
#
#   mix run examples/kubernetes_fanout.exs
#   CC_MAX_CONCURRENCY=2 mix run examples/kubernetes_fanout.exs
#
# This is the shape you want for batch work -- a queue of heterogeneous jobs,
# a concurrency ceiling you pick from your cluster's capacity, and a result set
# you can act on. `examples/kubernetes_task.exs` is the simpler sibling: same
# prompt, unbounded fan-out, no report.
#
# Needs a reachable cluster and the optional `{:kubereq, "~> 0.4.4"}`. It needs
# no API key and no custom image -- see the agent below.
#
# Three properties this example is built to *demonstrate* rather than claim:
#
#   1. Per-task parameters actually reach the sandbox. Each task names its own
#      model, and the process inside the Pod echoes back the model it was
#      handed. If plumbing were broken, the report would show one model N times
#      instead of each task's own.
#
#   2. The concurrency ceiling holds. A counter is bumped when a sandbox starts
#      and dropped when it finishes, tracking the high-water mark. The report
#      prints observed peak vs the limit; they must match, and a run whose peak
#      exceeded its limit would be a bug worth reporting.
#
#   3. Nothing leaks. After the last result the script asks the API server for
#      surviving sandboxes under this run's owner label, rather than trusting
#      that teardown ran.

# ---------------------------------------------------------------------------
# The stand-in CLI, wired in through the public `CrowdControl.Agent` behaviour.
#
# `build_command/1` receives the session's resolved options, so `:model` --
# passed per task below -- is readable here and travels into the Pod as an
# environment variable, over the same env path a real CLI's credentials use.
# The `sh` loop then reports it back, which is what makes property 1 visible.
# ---------------------------------------------------------------------------
defmodule EchoAgent do
  @behaviour CrowdControl.Agent

  @script """
  printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$(hostname)"
  while IFS= read -r _line; do
    printf '{"type":"result","subtype":"success","result":"%s|%s","num_turns":1}\\n' \\
      "$(hostname)" "$CC_MODEL"
  done
  """

  @impl true
  def build_command(opts) do
    # A real adapter raises on options it cannot express; this one only needs
    # the model, and a task that omits it is a caller error worth surfacing
    # before a Pod is created rather than after.
    model = Keyword.fetch!(opts, :model)
    {"/bin/sh", ["-c", @script], %{"CC_MODEL" => model}}
  end

  @impl true
  def init_frames(_opts), do: []

  @impl true
  def encode_prompt(prompt, _seq, _opts), do: CrowdControl.Protocol.encode_user_message(prompt)

  @impl true
  defdelegate decode_line(line), to: CrowdControl.Protocol
end

# ---------------------------------------------------------------------------
# Peak-concurrency tracker. This is Elixir's `Agent`, not `CrowdControl.Agent`
# above -- an unfortunate name collision, and worth one line to say so.
# ---------------------------------------------------------------------------
defmodule Peak do
  use Agent

  def start_link, do: Agent.start_link(fn -> {0, 0} end, name: __MODULE__)

  def enter, do: Agent.update(__MODULE__, fn {cur, peak} -> {cur + 1, max(peak, cur + 1)} end)
  def leave, do: Agent.update(__MODULE__, fn {cur, peak} -> {cur - 1, peak} end)
  def peak, do: Agent.get(__MODULE__, fn {_cur, peak} -> peak end)
end

max_concurrency = String.to_integer(System.get_env("CC_MAX_CONCURRENCY", "3"))
image = System.get_env("CC_K8S_IMAGE", "busybox:1.36")
owner = "cc-fanout-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

# The queue: heterogeneous work, one row per task. Models here are labels the
# stand-in echoes; with a real CLI these are the model names it dispatches on,
# and `:cpus`/`:memory` are per-task Pod limits rather than a global default.
tasks = [
  %{id: "sum-1", model: "haiku", cpus: 0.25, prompt: "Summarize the changelog"},
  %{id: "sum-2", model: "haiku", cpus: 0.25, prompt: "Summarize the README"},
  %{id: "review-1", model: "sonnet", cpus: 0.5, prompt: "Review lib/foo.ex"},
  %{id: "review-2", model: "sonnet", cpus: 0.5, prompt: "Review lib/bar.ex"},
  %{id: "design-1", model: "opus", cpus: 1.0, prompt: "Propose a migration plan"},
  %{id: "design-2", model: "opus", cpus: 1.0, prompt: "Propose a rollback plan"}
]

{:ok, _} = Peak.start_link()

IO.puts("""
#{length(tasks)} tasks, at most #{max_concurrency} sandboxes at a time
owner #{owner}, image #{image}
""")

run_task = fn task ->
  Peak.enter()
  started = System.monotonic_time(:millisecond)

  result =
    CrowdControl.run(task.prompt,
      agent: EchoAgent,
      executable: "/bin/sh",
      model: task.model,
      timeout: 120_000,
      backend:
        {
          CrowdControl.Backend.Kubernetes,
          # Per-task sizing: a summary does not need a design review's CPU.
          # See kubernetes_task.exs on why :unrestricted is honest for a shell
          # loop and wrong for real model-driven code.
          image: image,
          owner: owner,
          cpus: task.cpus,
          network: :unrestricted,
          provision_timeout: 180_000,
          timeout: 60_000,
          exec_timeout: 30_000
        }
    )

  Peak.leave()
  Map.merge(task, %{result: result, ms: System.monotonic_time(:millisecond) - started})
end

wall_started = System.monotonic_time(:millisecond)

report =
  tasks
  # The ceiling. `ordered: false` returns each task as it finishes, so a slow
  # design review does not hold up the summaries behind it; the report is
  # sorted back into task order below.
  |> Task.async_stream(run_task,
    max_concurrency: max_concurrency,
    timeout: :infinity,
    ordered: false
  )
  |> Enum.map(fn {:ok, row} -> row end)
  |> Enum.sort_by(& &1.id)

wall = System.monotonic_time(:millisecond) - wall_started

# ---------------------------------------------------------------------------
# The report.
# ---------------------------------------------------------------------------
rows =
  Enum.map(report, fn row ->
    case row.result do
      {:result, "success", %{"result" => payload}} ->
        [pod, model_seen] = String.split(payload, "|", parts: 2)
        {row, "ok", pod, model_seen}

      {:result, subtype, _} ->
        {row, subtype, "—", "—"}

      {:error, reason} ->
        {row, "error: #{inspect(reason)}", "—", "—"}
    end
  end)

IO.puts(
  String.pad_trailing("task", 11) <>
    String.pad_trailing("model asked", 13) <>
    String.pad_trailing("model in pod", 14) <>
    String.pad_trailing("ms", 7) <>
    String.pad_trailing("status", 8) <> "pod"
)

IO.puts(String.duplicate("-", 96))

for {row, status, pod, model_seen} <- rows do
  IO.puts(
    String.pad_trailing(row.id, 11) <>
      String.pad_trailing(row.model, 13) <>
      String.pad_trailing(model_seen, 14) <>
      String.pad_trailing(to_string(row.ms), 7) <>
      String.pad_trailing(status, 8) <> pod
  )
end

ok = Enum.count(rows, fn {_, status, _, _} -> status == "ok" end)

mismatched =
  Enum.count(rows, fn {row, status, _, seen} -> status == "ok" and seen != row.model end)

serial = report |> Enum.map(& &1.ms) |> Enum.sum()

IO.puts("""

#{ok}/#{length(tasks)} succeeded in #{wall} ms wall clock
#{serial} ms if run one at a time, so #{Float.round(serial / max(wall, 1), 1)}x from concurrency
peak sandboxes alive: #{Peak.peak()} (limit #{max_concurrency})
tasks whose pod reported a different model than asked: #{mismatched}
distinct pods: #{rows |> Enum.map(fn {_, _, pod, _} -> pod end) |> Enum.uniq() |> length()}\
""")

{:ok, live} = CrowdControl.Backend.Kubernetes.list_live(owner: owner)
IO.puts("sandboxes still alive under #{owner}: #{length(live)}")
