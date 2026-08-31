defmodule CrowdControl.LogRedactor do
  @moduledoc """
  A `:logger` primary filter that keeps a `%Req.Request{}` out of crash reports.

  ## Why this exists

  `kubereq` 0.4.5 changed how an exec/log websocket is established: its Req
  adapter answers a synthetic `101` and **casts** the real request to the
  connection process, which then performs the upgrade. When that upgrade is
  rejected — a deleted Pod (404), a wrong container name (400), an unsupported
  subprotocol (403) — or the socket fails, the connection process stops
  abnormally, and OTP's crash report includes its **last message**: the cast,
  carrying the whole `%Req.Request{}`.

  That struct holds the kubeconfig. Measured against a live cluster:

    * with a **certificate** kubeconfig, `:connect_options` carries
      `cert: <<48, 130, …>>` — client-certificate DER, in a ~2 KB `:error` line;
    * with a **token** kubeconfig — the in-cluster ServiceAccount posture, i.e.
      production — `Req`'s `Inspect` implementation redacts the `authorization`
      header, but `options.kubeconfig.current_user["token"]` is printed **in
      full**.

  A failed exec upgrade is a routine event: a Pod that was reaped mid-session
  produces one. So without this filter a cluster credential reaches the log on an
  ordinary day, which is precisely the leak
  `CrowdControl.Backend.Kubernetes.API`'s exception_reason/1 was written to close
  for the *return* path.

  ## What it does, and does not do

  It **redacts fields**; it never drops an event. The reason, the process name and
  the stacktrace all survive, so a crash is still diagnosable — only the request
  term, the process state and the client info are replaced with
  `:redacted_by_crowd_control`.

  It is deliberately narrow: it fires only for a crash report that actually
  carries a `%Req.Request{}` (or the Kubereq.Connect state), found by a
  depth-bounded walk. Any other library's crash reports pass through untouched.

  ## Opting out

      config :crowd_control, redact_logs: false

  Set that if you install your own filter, or if you would rather have the raw
  reports and accept what they contain.
  """

  @redacted :redacted_by_crowd_control

  # Deep enough to reach the request through the *deepest* nesting OTP produces,
  # and no deeper. The `{:proc_lib, :crash}` report is the long path:
  #
  #     report -> [props] -> {:message_queue, [_]} -> [cast]
  #       -> {:"$gen_cast", {:request, %Req.Request{}}}
  #
  # which is six descents; `{:gen_server, :terminate}`'s `:last_message` is two.
  # Eight leaves margin without turning a filter into the expensive part of a
  # crash — breadth at each level is a handful of keys, and crashes are rare.
  @max_depth 8

  @doc """
  Installs the filter, unless `config :crowd_control, redact_logs: false`.

  Idempotent: adding a filter under a name that already exists is a no-op, so a
  release that restarts the application does not accumulate filters.
  """
  @spec install() :: :ok
  def install do
    if Application.get_env(:crowd_control, :redact_logs, true) do
      _ = :logger.add_primary_filter(:crowd_control_redact, {&__MODULE__.filter/2, []})
      :ok
    else
      :ok
    end
  end

  @doc """
  The filter itself. Returns the event, possibly with fields redacted.

  Never returns `:stop`: suppressing a crash report would trade a credential leak
  for an invisible failure, which is a worse bargain.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{msg: {:report, report}} = event, _opts) when is_map(report) do
    if leaky?(report), do: %{event | msg: {:report, redact_report(report)}}, else: event
  end

  def filter(event, _opts), do: event

  # `{:gen_server, :terminate}` puts the offending term in `:last_message`;
  # `{:proc_lib, :crash}` nests the same information inside `:report`.
  defp redact_report(report) do
    report
    |> redact_keys([:last_message, :state, :client_info])
    |> redact_crash_proplist()
  end

  defp redact_keys(report, keys) do
    Enum.reduce(keys, report, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, @redacted), else: acc
    end)
  end

  defp redact_crash_proplist(%{report: [own_report | rest]} = report) when is_list(own_report) do
    scrubbed =
      Enum.map(own_report, fn
        {key, _value} when key in [:message_queue, :messages, :dictionary] ->
          {key, @redacted}

        {key, value} ->
          {key, if(contains_request?(value, @max_depth), do: @redacted, else: value)}

        other ->
          other
      end)

    %{report | report: [scrubbed | rest]}
  end

  defp redact_crash_proplist(report), do: report

  defp leaky?(report) do
    contains_request?(Map.get(report, :last_message), @max_depth) or
      contains_request?(Map.get(report, :state), @max_depth) or
      contains_request?(Map.get(report, :report), @max_depth)
  end

  # Structs are matched by `__struct__` rather than by pattern, because :req and
  # :kubereq are optional dependencies — this module must compile and run in an
  # application that has neither.
  defp contains_request?(_term, 0), do: false

  defp contains_request?(%{__struct__: struct}, _depth)
       when struct in [Req.Request, Kubereq.Connect],
       do: true

  defp contains_request?(%{__struct__: _} = struct, depth) do
    struct |> Map.from_struct() |> contains_request?(depth - 1)
  end

  defp contains_request?(map, depth) when is_map(map) do
    Enum.any?(map, fn {_k, v} -> contains_request?(v, depth - 1) end)
  end

  defp contains_request?(list, depth) when is_list(list) do
    Enum.any?(list, &contains_request?(&1, depth - 1))
  end

  defp contains_request?(tuple, depth) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> contains_request?(depth)
  end

  defp contains_request?(_term, _depth), do: false
end
