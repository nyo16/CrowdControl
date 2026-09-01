# Fan out N sandboxes as concurrent tasks, one Kubernetes Pod per session.
#
#   mix run examples/kubernetes_task.exs
#   CC_K8S_TASKS=5 CC_K8S_NAMESPACE=sandboxes mix run examples/kubernetes_task.exs
#
# Needs a reachable cluster (`kubectl get nodes` works) and the optional
# `{:kubereq, "~> 0.4.4"}` dependency. It needs **no API key and no custom
# image**: the CLI inside each Pod is a `sh` loop that speaks the same
# stream-json protocol Claude Code does, wired in through the public
# `CrowdControl.Agent` behaviour. That is the whole trick this example is for --
# every layer below the agent is exactly what a real CLI gets.
#
# What "spawn as a task" means here: `CrowdControl.start_sessions/1` starts each
# session under `Task.async_stream`, so N Pods are created concurrently rather
# than one after another, and `CrowdControl.collect/2` gathers the N results as
# they land. Each Pod prints its own name, so the fan-out is visible rather than
# asserted.
#
# Cleanup is not best-effort: `stop_all/1` destroys the Pods, and the script
# then asks the API server whether any sandbox with this run's owner label is
# still alive. A leaked Pod keeps billing on a real cluster.

# ---------------------------------------------------------------------------
# The stand-in CLI.
#
# It runs *inside* the Pod, so it may only use what the image has: this is
# busybox `sh`. It emits a system/init line at startup and one result line per
# prompt it reads from the FIFO, which is the minimum a `CrowdControl.Session`
# needs to assign a session id and complete a turn.
#
# `hostname` is the Pod name, so the result proves which Pod answered.
# ---------------------------------------------------------------------------
defmodule ShellAgent do
  @behaviour CrowdControl.Agent

  @script """
  printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$(hostname)"
  while IFS= read -r _line; do
    printf '{"type":"result","subtype":"success","result":"answered by pod %s","num_turns":1}\\n' "$(hostname)"
  done
  """

  @impl true
  def build_command(_opts), do: {"/bin/sh", ["-c", @script], %{}}

  # No handshake: the loop is reading stdin from the moment it starts.
  @impl true
  def init_frames(_opts), do: []

  # The wire format is unchanged -- only the program producing it is fake.
  @impl true
  def encode_prompt(prompt, _seq, _opts), do: CrowdControl.Protocol.encode_user_message(prompt)

  @impl true
  defdelegate decode_line(line), to: CrowdControl.Protocol
end

tasks = String.to_integer(System.get_env("CC_K8S_TASKS", "3"))
image = System.get_env("CC_K8S_IMAGE", "busybox:1.36")

# One label for this run, so cleanup can be verified by asking the API server
# rather than by trusting that destroy/1 was called.
owner = "cc-example-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

backend =
  [
    image: image,
    owner: owner,
    # Pods always have cluster networking, so the posture is explicit or the
    # backend refuses to guess.
    #
    # :unrestricted is the honest choice *for this example* and only because of
    # what runs inside: a `sh` loop written above, not model-driven code. Run a
    # real CLI here and the answer changes to :deny_all, which additionally
    # proves the CNI enforces the policy before provisioning:
    #
    #     CC_K8S_NETWORK=deny_all mix run examples/kubernetes_task.exs
    #
    # On a stock local cluster that fails with {:k8s, :network_policy_not_enforced}
    # -- orbstack, kind and Docker Desktop ship no policy controller, so a
    # NetworkPolicy there is an object the API server stores and nothing obeys.
    # The refusal is the feature; see SECURITY.md#the-kubernetes-backend.
    network: String.to_atom(System.get_env("CC_K8S_NETWORK", "unrestricted")),
    provision_timeout: 180_000,
    timeout: 60_000,
    exec_timeout: 30_000
  ]
  |> then(fn opts ->
    case System.get_env("CC_K8S_NAMESPACE") do
      nil -> opts
      ns -> Keyword.put(opts, :namespace, ns)
    end
  end)

IO.puts("starting #{tasks} sandboxes concurrently (owner #{owner}, image #{image})\n")

started = System.monotonic_time(:millisecond)

session_opts =
  Enum.map(1..tasks, fn i ->
    [
      agent: ShellAgent,
      executable: "/bin/sh",
      backend: {CrowdControl.Backend.Kubernetes, backend},
      timeout: 120_000,
      prompt: "task #{i}"
    ]
  end)

case CrowdControl.start_sessions(session_opts) do
  {:ok, sessions} ->
    elapsed = System.monotonic_time(:millisecond) - started
    IO.puts("#{length(sessions)} Pods running after #{elapsed} ms\n")

    results = CrowdControl.collect(sessions, 120_000)

    for {_pid, msg} <- results do
      case msg do
        {:result, "success", r} -> IO.puts("  #{r["result"]}")
        other -> IO.puts("  unexpected: #{inspect(other)}")
      end
    end

    IO.puts(
      "\n#{length(results)}/#{tasks} results in #{System.monotonic_time(:millisecond) - started} ms"
    )

    CrowdControl.stop_all(sessions)

    # Verified, not assumed: ask the API server what is still alive.
    {:ok, live} = CrowdControl.Backend.Kubernetes.list_live(owner: owner)
    IO.puts("leaked Pods after stop_all/1: #{length(live)}")

  {:error, reasons} ->
    IO.puts("""
    no sandbox started: #{inspect(reasons)}

    Usual causes: no reachable cluster, the optional :kubereq dependency is
    missing, or the CNI does not enforce NetworkPolicy -- that last one reads as
    {:k8s, :network_policy_not_enforced} and is a refusal to pretend a Pod is
    isolated. Re-run with CC_K8S_NETWORK=unrestricted if you accept that, and
    read SECURITY.md#the-kubernetes-backend before you do.
    """)
end
