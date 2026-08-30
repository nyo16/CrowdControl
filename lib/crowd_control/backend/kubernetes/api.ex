defmodule CrowdControl.Backend.Kubernetes.API do
  @moduledoc """
  Every `kubereq` call in the project, and the error vocabulary built on top of it.

  This module plays the same role for `CrowdControl.Backend.Kubernetes` that
  `CrowdControl.Backend.Docker.API` plays for the Docker backend: one file to
  audit when the client library moves. That confinement earns more here than it
  does there, because `kubereq` 0.4.4 is young and has sharp edges the backend
  must never see:

    * `Kubereq.list/3` with `into: :stream` silently applies `limit: 10` and
      silently truncates on a mid-pagination error. `list_all/4` paginates by
      hand instead — see the comment there for why a truncated list is the most
      dangerous value this module can return.
    * `Kubereq.PodExec.open?/1` is broken: `Kubereq.Connect.handle_call(:open?, …)`
      returns a malformed two-tuple GenServer reply and crashes the connection
      process. Nothing here calls it; liveness is a monitor's job.
    * `Kubereq.PodExec.start_link/1` **raises `MatchError`** rather than
      returning `{:error, _}` when the websocket upgrade fails, and it links to
      whoever starts it and stops with the transport error as its exit reason.
      `open_exec/5` contains both: it starts the channel from a dedicated
      trapping owner, so neither the raise nor a later blip can reach the caller,
      and callers get `{:exec_down, pid, reason}` instead of an exit signal.

  ## Non-2xx is `{:ok, _}`

  `kubereq` installs only a *request* step (`Req.Request.prepend_request_steps`),
  so nothing converts HTTP status into an error. A 404 arrives as
  `{:ok, %Req.Response{status: 404, body: %{"kind" => "Status", …}}}`. Every
  `{:error, {:k8s, _}}` in this backend is produced by `normalize/1` below —
  this module is where the vocabulary is created, not glue around one that
  already exists. `{:error, _}` out of `kubereq` itself means a transport
  failure or a `%Kubereq.Error.StepError{}`.
  """

  # :kubereq is an optional dependency, so this module must still COMPILE
  # without it -- hence no struct patterns against any Kubereq or Req module
  # anywhere below (struct expansion needs the module at compile time; plain
  # `%{__struct__: Mod}` map patterns do not).
  # CrowdControl.Backend.Kubernetes.provision/1 raises a clear message at
  # runtime if kubereq is genuinely missing.
  @compile {:no_warn_undefined,
            [
              Kubereq,
              Kubereq.Kubeconfig,
              Kubereq.Kubeconfig.Default,
              Kubereq.PodExec,
              Kubereq.PodLogs
            ]}

  @default_timeout 30_000
  @default_exec_timeout 15_000

  # v4 rather than v5: v5 adds only close-stdin signalling, which nothing here
  # needs, and every extra requested subprotocol is another thing an older
  # apiserver can fail to offer. v4 has been served since Kubernetes 1.7.
  @exec_subprotocol "v4.channel.k8s.io"

  # One page is 500 rather than the API server's 500-ish default because the
  # common case -- one owner's live sandboxes -- fits in a single round trip.
  @page_limit 500

  # A log fetch is a diagnostic, so it is bounded twice: by lines for
  # readability and by bytes so one chatty container cannot put a megabyte into
  # a crash report.
  @default_log_lines 50
  @default_log_bytes 64 * 1024

  @pod_api [api_version: "v1", kind: "Pod"]
  @netpol_api [api_version: "networking.k8s.io/v1", kind: "NetworkPolicy"]

  # kubereq raises rather than returns in several places: a malformed kubeconfig
  # (`Kubereq.Kubeconfig.load/1`, `Step.TLS.ca_cert!/1`), an unknown resource,
  # and PodExec's MatchError. Everything this module exposes returns a value.
  #
  # A macro rather than a `defp guard(fun)` taking a closure, for a reason worth
  # knowing: one shared higher-order helper gets ONE success typing, unioned
  # across every closure handed to it. `wait_until/4` and `exec_stdin/4` return
  # a bare `:ok`, so dialyzer then reported `:ok` as missing from the spec of
  # nine unrelated functions that cannot return it. Inlining types each call
  # site on its own, and costs one fewer closure per request.
  defmacrop guard(do: body) do
    quote do
      try do
        unquote(body)
      rescue
        e -> {:error, {:k8s, unquote(__MODULE__).exception_reason(e)}}
      catch
        :exit, reason -> {:error, {:k8s, {:exit, reason}}}
      end
    end
  end

  @doc false
  # The websocket upgrade path produces the worst error term in this codebase,
  # and it must never reach a log line intact. The chain, all of it inside
  # kubereq 0.4.4:
  #
  #   1. `Kubereq.Connect.connect/1` returns `{req, error}` on failure.
  #   2. That matches none of `init/1`'s `else` clauses, so Elixir raises
  #      `WithClauseError`, and `GenServer.start_link/3` returns
  #      `{:error, {{:else_clause, {req, error}}, stacktrace}}`.
  #   3. `Kubereq.Connect.start_link/4`'s own `{:ok, resp} = Req.request(...)`
  #      then raises a `MatchError` whose **term** is that whole structure.
  #
  # `Exception.message/1` on that inlines the inspected `%Req.Request{}` — which
  # carries the kubeconfig's TLS client certificate in `:connect_options` — into
  # a multi-kilobyte string. Observed against a live cluster: a `404` on the
  # exec subresource logged ~2 KB including `cert: <<48, 130, 1, 144, ...>>`.
  #
  # So the real cause is dug out for the shape we know, and every other
  # exception message is capped. Two defences rather than one, because the
  # truncation point of an unrecognised term is not something to bet secrets on.
  @spec exception_reason(Exception.t()) :: term()
  def exception_reason(%{__struct__: MatchError, term: term}) do
    case upgrade_cause(term) do
      nil -> {:exception, {:match_error, bounded_inspect(term)}}
      cause -> cause
    end
  end

  # The same term, raised one layer earlier. `Kubereq.Connect.create_stream/4`
  # can raise the `WithClauseError` itself — during `Enum` evaluation of a stream,
  # not inside `init/1` — in which case nothing wraps it into a `MatchError` and
  # this clause is the only thing standing between a `%Mint.HTTP1{}` (which holds
  # the socket and, transitively, the connection's transport options) and a log
  # line. Length-capping `Exception.message/1` is not good enough: the cap is a
  # character count, and what must be bounded is the *structure*.
  def exception_reason(%{__struct__: WithClauseError, term: term}) do
    case upgrade_cause(term) do
      nil -> {:exception, {:else_clause, bounded_inspect(term)}}
      cause -> cause
    end
  end

  def exception_reason(exception), do: {:exception, summarize(Exception.message(exception))}

  # Bounds the term **structurally**, not just by length. `limit: 3` elides all
  # but the first few fields of a struct and all but the first few bytes of a
  # binary, so a secret nested inside `%Req.Request{}`'s `:connect_options` is
  # unreachable regardless of where a character cap would happen to fall — while
  # "a MatchError on a %Req.Response{}" survives, which is the part worth having.
  defp bounded_inspect(term) do
    term
    |> inspect(limit: 3, printable_limit: 64)
    |> String.slice(0, 200)
  end

  # Walks the two nestings GenServer/Elixir add around the cause. Matched on
  # `__struct__` rather than struct patterns for the optional-dep reason above.
  defp upgrade_cause({:error, reason}), do: upgrade_cause(reason)
  defp upgrade_cause({{:else_clause, {_req, cause}}, _stacktrace}), do: cause_reason(cause)
  defp upgrade_cause({:else_clause, {_req, cause}}), do: cause_reason(cause)

  # A `WithClauseError` raised directly carries the bare 2-tuple `connect/1`
  # returned, with no `:else_clause` wrapper: `{%Req.Request{}, cause}` on the
  # upgrade path, or `{%Mint.HTTP1{}, cause}` from `create_stream/4`. Recognising
  # it turns the term into the same `{:upgrade_failed, status}` vocabulary instead
  # of an inspected connection struct.
  defp upgrade_cause({left, cause}) when is_struct(left) and is_struct(cause),
    do: cause_reason(cause)

  defp upgrade_cause(_other), do: nil

  # A 404 here is the interesting one: it means the Pod, the container, or the
  # `exec` subresource itself was not there when the upgrade was attempted —
  # which is what a deleted or restarted Pod looks like from the client side.
  defp cause_reason(%{__struct__: Mint.WebSocket.UpgradeFailureError, status_code: status}),
    do: {:upgrade_failed, status}

  defp cause_reason(%{__struct__: struct, reason: reason})
       when struct in [Mint.TransportError, Mint.HTTPError],
       do: {:transport, reason}

  # Known nesting, unknown cause: still never inspect it wholesale.
  defp cause_reason(%{__struct__: struct}), do: {:upgrade_failed, struct}
  defp cause_reason(_other), do: {:upgrade_failed, :unknown}

  @typedoc """
  Cluster connection config.

  `:kubeconfig`, `:namespace`, `:timeout`, `:exec_timeout`, and the `:req_adapter`
  test seam.
  """
  @type config :: keyword()

  # --- connection ---

  @doc """
  A `Req.Request` with `kubereq` attached, pointed at `resource`.

  `Kubereq.attach/2` loads the kubeconfig **eagerly** — file reads, and possibly
  an `exec` auth plugin subprocess — every time it is called with a pipeline
  module. Every call in this module goes through here, and the reaper calls in a
  loop, so the loaded `%Kubereq.Kubeconfig{}` is cached in `:persistent_term`
  and the *struct* is what gets passed to `attach/2`.
  """
  @spec client(config(), keyword()) :: Req.Request.t()
  def client(config, resource) do
    # Req's default `retry: :safe_transient` turns one refused connection into
    # 1s + 2s + 4s of backoff. Every caller here already treats {:error, _} as
    # authoritative -- the Reaper's fail-open path most of all -- so a prompt,
    # deterministic failure is worth more than a retried GET. It applies to the
    # test seam too: a stubbed 5xx that silently retries makes the hermetic test
    # behave unlike the code it exists to exercise.
    [receive_timeout: timeout(config), retry: false]
    |> maybe_put_adapter(config[:req_adapter])
    |> Req.new()
    |> Kubereq.attach([kubeconfig: kubeconfig(config)] ++ resource)
  end

  @doc """
  A `client/2` for the `exec` subresource, negotiating `v4.channel.k8s.io`.

  Requesting the subprotocol is what makes exec **exit codes** available at all.
  Without this header the API server falls back to v1 `channel.k8s.io`, whose
  channel 3 carries a human string produced by the container *runtime* —
  measured: `"command terminated with non-zero exit code: Error executing in
  Docker Container: 7"` under this cluster's runtime, but
  `"command terminated with exit code 7"` under containerd. Parsing that is
  parsing a runtime's prose.

  Under v4 the same channel carries a JSON `Status` object instead, so the exit
  code is a field. Measured against v1.35.6+orb1: `exit 7` yields
  `%{"status" => "Failure", "reason" => "NonZeroExitCode",
     "details" => %{"causes" => [%{"reason" => "ExitCode", "message" => "7"}]}}`,
  and a clean exit yields `%{"metadata" => %{}, "status" => "Success"}` — note
  that success also produces a frame, which is what makes "no news is good news"
  the wrong reading of channel 3.

  `kubereq` never sets this itself, but `Kubereq.Connect.connect/1` passes
  `req.headers` straight into `Mint.WebSocket.upgrade/4`, so a header put here
  reaches the wire.
  """
  @spec exec_client(config()) :: Req.Request.t()
  def exec_client(config) do
    config
    |> client(@pod_api)
    |> Req.Request.put_header("sec-websocket-protocol", @exec_subprotocol)
  end

  @doc false
  # Decodes a channel-3 frame under `v4.channel.k8s.io`.
  #
  # Public so the whole table is assertable without an API server; the frames
  # here are verbatim from a live cluster.
  @spec exec_status(binary()) :: :ok | {:error, term()}
  def exec_status(payload) when is_binary(payload) do
    case JSON.decode(payload) do
      {:ok, %{"status" => "Success"}} ->
        :ok

      {:ok, %{"status" => "Failure"} = status} ->
        {:error, {:k8s, failure_reason(status)}}

      # Not JSON: the server fell back to v1 and sent runtime prose. Keep it,
      # bounded — it is still the only evidence of what happened.
      _ ->
        {:error, {:k8s, {:exec_failed, summarize(payload)}}}
    end
  end

  defp failure_reason(%{"details" => %{"causes" => causes}} = status) do
    causes
    |> List.wrap()
    |> Enum.find_value(fn
      %{"reason" => "ExitCode", "message" => code} -> parse_exit_code(code)
      _ -> nil
    end)
    |> case do
      nil -> {:exec_failed, summarize(status)}
      code -> {:exit_status, code}
    end
  end

  defp failure_reason(status), do: {:exec_failed, summarize(status)}

  defp parse_exit_code(code) when is_integer(code), do: code

  defp parse_exit_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_exit_code(_code), do: nil

  defp maybe_put_adapter(opts, nil), do: opts
  defp maybe_put_adapter(opts, adapter), do: [{:adapter, adapter} | opts]

  @doc """
  The loaded kubeconfig for `config`.

  Accepts a `%Kubereq.Kubeconfig{}` struct, a pipeline module, or a
  `{module, opts}` tuple under `:kubeconfig`; defaults to
  `Kubereq.Kubeconfig.Default`, which covers both a developer's `~/.kube/config`
  and an in-cluster ServiceAccount with no caller input.
  """
  @spec kubeconfig(config()) :: Kubereq.Kubeconfig.t()
  def kubeconfig(config) do
    case config[:kubeconfig] do
      nil -> load_cached(Kubereq.Kubeconfig.Default)
      %{__struct__: Kubereq.Kubeconfig} = loaded -> loaded
      pipeline -> load_cached(pipeline)
    end
  end

  defp load_cached(pipeline) do
    key = {__MODULE__, :kubeconfig, pipeline}

    case :persistent_term.get(key, nil) do
      nil ->
        loaded = Kubereq.Kubeconfig.load(pipeline)
        :persistent_term.put(key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  @doc """
  The namespace to operate in.

  `:namespace`, else the current kubeconfig context's own namespace, else
  `"default"`. Requiring the option would be friction on the dev path for no
  safety gain: the context namespace is what `kubectl` would use, and in-cluster
  `Kubereq.Kubeconfig.ServiceAccount` populates it from the projected
  `namespace` file. Both topologies land on the right answer unasked.
  """
  @spec namespace(config()) :: String.t()
  def namespace(config) do
    config[:namespace] || kubeconfig(config).current_namespace || "default"
  end

  @doc "The API server URL of the current context — the enforcement-cache key."
  @spec cluster_url(config()) :: String.t() | nil
  def cluster_url(config) do
    case kubeconfig(config).current_cluster do
      %{"server" => server} -> server
      _ -> nil
    end
  end

  # --- pods ---

  @doc "GET a Pod by name."
  @spec get_pod(config(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_pod(config, name) do
    run(fn -> Kubereq.get(client(config, @pod_api), namespace(config), name) end)
  end

  @doc "POST a Pod manifest."
  @spec create_pod(config(), map()) :: {:ok, map()} | {:error, term()}
  def create_pod(config, manifest) do
    run(fn -> Kubereq.create(client(config, @pod_api), manifest) end)
  end

  @doc """
  DELETE a Pod with no grace period.

  `kubereq` has no `DeleteOptions` option, so `gracePeriodSeconds` goes through
  as a plain Req param. Zero because the sandbox holds no state worth draining
  and a lingering terminating Pod is still a billed Pod.
  """
  @spec delete_pod(config(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_pod(config, name) do
    run(fn ->
      Kubereq.delete(client(config, @pod_api), namespace(config), name,
        params: [gracePeriodSeconds: 0]
      )
    end)
  end

  @doc """
  Every Pod matching `label_selectors`, following `continue` to the last page.

  **Never** `Kubereq.list/3`, and never its `into: :stream` form. Both are
  wrong here, in the same silent direction:

    * the plain form returns one page and no indication that there were more;
    * `do_list_into_stream/4` does `Keyword.put_new(params, :limit, 10)` and its
      stream `{:halt, :ok}`s on a mid-pagination error, so a partial list is
      indistinguishable from a complete one.

  A short list is not a cosmetic bug. `CrowdControl.Reaper` reads this as *the*
  evidence of what is live: under the reconciliation table, a live sandbox
  missing from this list is `live? = no, stored? = yes`, and the reaper deletes
  the store record of a running, billed sandbox — orphaning it permanently.
  Truncation must therefore be impossible, and any page failure must surface as
  `{:error, _}` rather than a shorter list.
  """
  @spec list_all(config(), String.t() | nil, keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_all(config, namespace \\ nil, opts \\ []) do
    guard do
      paginate(client(config, @pod_api), namespace || namespace(config), opts, nil, [])
    end
  end

  @doc """
  The container's logs, as a single binary.

  This is the diagnostic channel the backend had none of. A sandbox that dies
  during provisioning previously produced `{:k8s, {:pod_not_ready,
  "CrashLoopBackOff"}}` and nothing else — the operator's next step was
  `kubectl logs` by hand, which is only possible if the Pod still exists, and
  `destroy/1` has usually removed it by then.

  Bounded by construction, because a log fetch is a diagnostic and must never
  become the reason a teardown hangs:

    * `follow: false` — **always**, never overridable. `Kubereq.logs/4`'s own
      docs say `follow: true` "keeps the connection alive which blocks the
      current process"; that is `Kubereq.PodLogs`' job, not this one.
    * `tailLines` (default #{@default_log_lines}) and `limitBytes`
      (default #{@default_log_bytes}) so a chatty container cannot return a
      megabyte into a crash report.
    * `:previous` for the case that matters most — a container that already
      restarted, whose *current* logs are empty precisely because the
      interesting run is the previous one.

  Built on `Kubereq.PodLogs`, **not** `Kubereq.logs/4`. The latter looks like the
  obvious call and is a trap three ways: its body is a lazy `Stream`, so a
  rejected upgrade raises at `Enum` time rather than at the call and escapes the
  `guard` around it; enumerating it can raise `WithClauseError` from
  `Kubereq.Connect.create_stream/4`, whose message inspects a `%Mint.HTTP1{}`;
  and its `:follow` defaults to **true**, so the obvious call blocks forever.

  Returns `{:ok, ""}` when a container has genuinely produced nothing, so a
  caller can tell "nothing to say" from "could not ask". A Pod whose container
  never started answers `400` rather than an empty body — there is nothing to
  read — so `CrowdControl.Backend.Kubernetes` falls back to the Pod's own
  `state.waiting.message` for that case.
  """
  @spec logs(config(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def logs(config, pod_name, opts \\ []) do
    params = log_params(opts)

    bounded(config, fn ->
      # PodLogs links to its caller and raises MatchError on a rejected upgrade.
      # Inside bounded/2 the caller is this task, so trapping keeps a 400 from
      # killing it before `guard` can turn it into a value.
      Process.flag(:trap_exit, true)

      guard do
        args =
          [
            req: client(config, @pod_api),
            namespace: namespace(config),
            name: pod_name,
            into: self()
          ] ++
            params

        {:ok, pid} = Kubereq.PodLogs.start_link(args)
        collect_logs(pid, [])
      end
    end)
  end

  @doc false
  # Public so the bounds are assertable without a cluster. `Kubereq.PodLogs`
  # cannot be reached through the `:req_adapter` seam — kubereq overwrites the
  # adapter on the websocket path — so the params are the only part of this that
  # is unit-testable, and they are the part that matters: `follow: false` is what
  # stops a diagnostic from blocking forever.
  @spec log_params(keyword()) :: keyword()
  def log_params(opts) do
    [
      # Never overridable, and not merged from opts. See logs/3.
      follow: false,
      tailLines: Keyword.get(opts, :tail_lines, @default_log_lines),
      limitBytes: Keyword.get(opts, :limit_bytes, @default_log_bytes),
      previous: Keyword.get(opts, :previous, false)
    ]
    |> maybe_container(opts[:container])
  end

  # PodLogs sends `{:stdout, binary}` per frame, then usually
  # `{:close, code, reason}`, then exits. It does not send `:connected`, unlike
  # PodExec. The empty first frame is kubereq's priming artefact and is dropped —
  # for logs, unlike exec, there is no channel byte, so an empty frame is
  # genuinely empty.
  #
  # An abnormal exit **after** bytes have arrived is success, not failure. With
  # `follow: false` the server writes the body and drops the connection, and
  # kubereq surfaces that as an `:ssl_closed`-driven
  # `%Mint.TransportError{reason: :closed}` exit rather than a close frame —
  # measured against a live cluster on a running Pod. Reporting that as an error
  # threw away logs we had already received, which is the opposite of the point.
  # Only a close with nothing in hand is a failure.
  defp collect_logs(pid, acc) do
    receive do
      {:stdout, ""} ->
        collect_logs(pid, acc)

      {:stdout, data} ->
        collect_logs(pid, [data | acc])

      {:close, _code, _reason} ->
        {:ok, finish_logs(acc)}

      {:EXIT, ^pid, :normal} ->
        {:ok, finish_logs(acc)}

      {:EXIT, ^pid, _reason} when acc != [] ->
        {:ok, finish_logs(acc)}

      # An empty body is not a failure. With `follow: false` the server writes
      # whatever there is and drops the connection, which kubereq surfaces as a
      # `:closed` transport exit — so a container that logged nothing, or a
      # `previous: true` fetch on a Pod whose prior container said nothing, ends
      # exactly like a successful one with no bytes. Reporting that as an error
      # made "there is nothing to say" indistinguishable from "the fetch failed",
      # in the one code path whose entire job is diagnosis.
      {:EXIT, ^pid, %{__struct__: Mint.TransportError, reason: :closed}} ->
        {:ok, finish_logs(acc)}

      {:EXIT, ^pid, reason} ->
        {:error, {:k8s, {:logs_closed, summarize(inspect(reason))}}}

      _other ->
        collect_logs(pid, acc)
    end
  end

  defp finish_logs(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp paginate(req, namespace, opts, continue, acc) do
    params = if continue, do: [limit: @page_limit, continue: continue], else: [limit: @page_limit]

    case normalize(Kubereq.list(req, namespace, Keyword.put(opts, :params, params))) do
      {:ok, %{"items" => items} = body} ->
        acc = [items | acc]

        case get_in(body, ["metadata", "continue"]) do
          next when is_binary(next) and next != "" ->
            paginate(req, namespace, opts, next, acc)

          _ ->
            {:ok, acc |> Enum.reverse() |> Enum.concat()}
        end

      {:ok, other} ->
        {:error, {:k8s, {:unexpected_list_response, summarize(other)}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Poll/watch a Pod until `callback` returns true, or `:timeout` ms elapse.

  `Kubereq.wait_until/5`'s `:timeout` is a Req `receive_timeout` on the watch,
  not a wall-clock deadline — the caller supplies that.
  """
  @spec wait_until(
          config(),
          String.t(),
          (map() | :deleted -> boolean() | {:error, term()}),
          timeout()
        ) ::
          :ok | {:error, term()}
  def wait_until(config, name, callback, timeout) do
    guard do
      case Kubereq.wait_until(client(config, @pod_api), namespace(config), name, callback,
             timeout: timeout
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, {:k8s, wait_reason(reason)}}
      end
    end
  end

  # `Kubereq.wait_until/5` is spec'd `:ok | {:error, :watch_timeout}`, but its
  # body also propagates whatever the initial `list` returned -- a StepError, a
  # transport exception. The spec is narrower than the behaviour, so dialyzer
  # calls the other clauses dead and they are not: dropping them would turn a
  # real transport failure into a FunctionClauseError.
  @dialyzer {:nowarn_function, wait_reason: 1}
  defp wait_reason(:watch_timeout), do: :provision_timeout
  defp wait_reason({:k8s, reason}), do: reason
  defp wait_reason(reason), do: reason

  # --- network policies ---

  @doc "GET a NetworkPolicy by name."
  @spec get_network_policy(config(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_network_policy(config, name) do
    run(fn -> Kubereq.get(client(config, @netpol_api), namespace(config), name) end)
  end

  @doc "POST a NetworkPolicy manifest."
  @spec create_network_policy(config(), map()) :: {:ok, map()} | {:error, term()}
  def create_network_policy(config, manifest) do
    run(fn -> Kubereq.create(client(config, @netpol_api), manifest) end)
  end

  @doc "DELETE a NetworkPolicy by name."
  @spec delete_network_policy(config(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_network_policy(config, name) do
    run(fn -> Kubereq.delete(client(config, @netpol_api), namespace(config), name) end)
  end

  # --- exec ---

  @doc """
  Run `command` to completion and return everything it wrote to stdout.

  Bounded by `:exec_timeout` (default 15s). `Kubereq.exec/4` blocks on a stream
  whose only deadline is the 10s HTTP-101 upgrade; after the upgrade its
  `Mint.WebSocket.recv/3` waits `:infinity`. `write/2` runs inside the session's
  own call path, so an unbounded exec here would wedge the session forever.

  Exec **exit codes are not available**: `kubereq` never negotiates
  `v4.channel.k8s.io`, so channel 3 arrives as an undecoded `{:error, binary}`.
  This is parity with Docker, whose detached exec also never reports status —
  not a regression, but it does mean a successful return proves the command was
  *started*, not that it succeeded.
  """
  @spec exec_once(config(), String.t(), [String.t()], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def exec_once(config, pod_name, command, opts \\ []) do
    bounded(config, fn -> guard(do: do_exec_once(config, pod_name, command, opts)) end)
  end

  defp do_exec_once(config, pod_name, command, opts) do
    params = exec_params(command, Keyword.put_new(opts, :stdin, false))

    case Kubereq.exec(exec_client(config), namespace(config), pod_name, params) do
      {:ok, %{status: 101, body: stream}} -> collect_exec(stream)
      other -> normalize(other)
    end
  end

  # Channel 3 is consumed, not discarded. Discarding it is how a command that
  # exited non-zero returned `{:ok, ""}`: `Backend.Kubernetes.exec/4` and
  # `write/2` both read `{:ok, _}` as success, so a failed launch pipeline or a
  # full FIFO looked exactly like a working one.
  #
  # Frame order across channels is not guaranteed — a `{:stderr, _}` before the
  # first `{:stdout, _}` was observed live — so the stream is drained fully and
  # the status decided at the end rather than short-circuiting on the first
  # channel-3 frame.
  defp collect_exec(stream) do
    {stdout, status} =
      Enum.reduce(stream, {[], :ok}, fn
        {:stdout, data}, {acc, status} -> {[data | acc], status}
        {:error, payload}, {acc, status} -> {acc, merge_status(status, exec_status(payload))}
        _other, acc_status -> acc_status
      end)

    case status do
      :ok -> {:ok, stdout |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, reason} -> {:error, reason}
    end
  end

  # First failure wins: a later `Success` frame must not overwrite an earlier
  # non-zero exit.
  defp merge_status({:error, _} = failure, _next), do: failure
  defp merge_status(:ok, next), do: next

  @doc """
  Run `command` and feed `payload` to its stdin over the exec websocket.

  This is the secret channel. The Kubernetes exec API has **no `env` parameter**
  — `pods/exec` has no such field and `kubectl exec` has no `--env` — so
  Docker's first-class `Env` array has no counterpart. The three ways to get a
  provider key into a sandbox and why only one survives:

    * `env` in the Pod spec: puts the key in the Pod object, i.e. in etcd,
      readable by anyone with `get pods`. Trades an in-sandbox `ps` leak for a
      cluster-wide one.
    * `Secret` + `envFrom`: same etcd residency, plus `secrets` RBAC and a
      second object to leak on crash.
    * **stdin**: the bytes travel on websocket channel 0. They never enter argv,
      never enter the API object, and never appear in `kubectl describe`.

  `opts` takes `:container`, and passing it is not optional in practice: every
  other exec in this module pins the container, this one did not, and on a Pod
  with more than one container the API server picks. The env file is the secret
  channel, so "whichever container the server picked" is the wrong place for it.
  The sandbox Pod happens to have one container plus an already-exited init
  container, so the omission worked by luck rather than by construction.

  ## `command` must terminate on its own

  It must **not** rely on stdin EOF — no bare `cat > file`. Closing the websocket
  to signal EOF makes the API server tear the exec down before it writes the
  channel-3 `Status`, so the command's exit code never arrives and every failure
  reads as success. Measured on v1.35.6+orb1, same Pod, `cat > /no-such-dir/x`:

      with a client-side close:    [:connected, {:close, 1000, ""}]        — no channel 3
      without a client-side close: [:connected, {:error, "…ExitCode…1"}, …] — channel 3 present

  So bound the read instead. `head -c <byte_size(payload)> > file` consumes
  exactly the payload and exits, the server sends the status, and the close frame
  arrives on its own. This is why the caller passes a byte count rather than
  letting the shell read to EOF.

  Bounded by `:exec_timeout` like `exec_once/4`.
  """
  @spec exec_stdin(config(), String.t(), [String.t()], iodata(), keyword()) ::
          :ok | {:error, term()}
  def exec_stdin(config, pod_name, command, payload, opts \\ []) do
    bounded(config, fn ->
      # PodExec links to whoever called start_link/1, which inside bounded/2 is
      # this task. Trap so a transport failure closes the exec rather than
      # killing the task out from under Task.yield/2.
      Process.flag(:trap_exit, true)
      guard(do: do_exec_stdin(config, pod_name, command, payload, opts))
    end)
  end

  defp do_exec_stdin(config, pod_name, command, payload, opts) do
    with {:ok, pid} <- open_exec(config, pod_name, command, self(), [stdin: true] ++ opts) do
      # Not matched on `:ok`: a command that has already exited — which is what a
      # failed redirect looks like — makes this write land on a socket the server
      # is tearing down, and that is a status to be read from channel 3, not a
      # crash.
      _ = Kubereq.PodExec.send_stdin(pid, IO.iodata_to_binary(payload))

      # No `PodExec.close/1` before this: see the moduledoc above. The command
      # ends itself, so the status arrives first and the close frame follows.
      status = await_close(pid, :ok)
      _ = close_exec(pid)
      status
    end
  end

  # The one exec whose failure used to be invisible.
  #
  # This wrote the env file — the provider key — and returned `:ok` on the first
  # close frame, discarding channel 3 entirely. A `sh` that could not create the
  # file (read-only mount, full disk, wrong container per above) reported success,
  # and the CLI then started with no credentials and failed later, somewhere else,
  # for a reason that named none of this.
  #
  # Channel 3 arrives regardless of the `stderr` parameter (measured), so the
  # status is always available; it just was not read. `exec_status/1` is the same
  # decoder `exec_once/4` uses, so both paths share one vocabulary.
  defp await_close(pid, status) do
    receive do
      {:error, payload} when is_binary(payload) ->
        await_close(pid, merge_status(status, exec_status(payload)))

      {:close, _code, _reason} ->
        status

      # `open_exec/5` owns the link now and reports the channel's death as a
      # message; an `{:EXIT, pid, _}` here would never arrive and this would
      # block until the bounded/2 deadline.
      {:exec_down, ^pid, :normal} ->
        status

      {:exec_down, ^pid, reason} ->
        merge_status(status, {:error, {:k8s, {:exec_closed, reason}}})

      _other ->
        await_close(pid, status)
    end
  end

  @doc """
  Start a long-lived `Kubereq.PodExec` delivering frames to `into`.

  The channel is **not** linked to the caller. Two `kubereq` 0.4.4 hazards make
  that the only safe contract, and both are handled here and nowhere else:

    * On a failed websocket upgrade Kubereq.Connect's `init/1` raises a
      `WithClauseError`, `GenServer.start_link/3` returns `{:error, _}`, and
      Kubereq.Connect's own `{:ok, pid} = …` turns that into a `MatchError` in
      the *starting* process. A `rescue` only reaches that if the starter traps
      exits: otherwise `proc_lib`'s `sync_wait` never converts the child's
      abnormal exit into a value and the link signal kills the starter outright,
      before any rescue can run.
      (Written unlinked on purpose: that module is `@moduledoc false`, so an
      autolink to it is a broken doc reference.)
    * The returned process stops with the transport error as its exit reason, so
      a routine websocket blip would kill a linked caller mid-session.

  So the channel is started by a dedicated owner process, spawned *unlinked*,
  which traps exits and holds the only link. The caller gets a plain value back
  and cannot be killed by either hazard. When the channel dies the owner sends
  `into` a `{:exec_down, pid, reason}` message, which carries the same
  information the old `{:EXIT, pid, reason}` did — a consumer that wants to know
  still learns immediately rather than at its next poll.

  The owner monitors `into` and closes the channel if it dies, so the channel
  cannot outlive its consumer. It is deliberately not supervised: an exec channel
  has no meaningful restart, and a supervisor would keep one alive after its
  reader was gone.
  """
  @spec open_exec(config(), String.t(), [String.t()], pid(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def open_exec(config, pod_name, command, into, opts \\ []) do
    args =
      [
        req: exec_client(config),
        namespace: namespace(config),
        name: pod_name,
        into: into
      ] ++ exec_params(command, opts)

    caller = self()
    tag = make_ref()

    # spawn_monitor, not spawn_link: the monitor is how a caller learns the owner
    # itself failed, and it costs nothing to be defensive about a process whose
    # whole job is to keep failures away from the caller.
    {owner, mon} = spawn_monitor(fn -> own_exec(args, into, caller, tag) end)

    receive do
      {^tag, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^owner, reason} ->
        {:error, {:k8s, {:exec_owner_down, summarize(inspect(reason))}}}
    end
  end

  defp own_exec(args, into, caller, tag) do
    Process.flag(:trap_exit, true)

    # The MatchError now happens *here*, in a process that traps and whose death
    # reaches nobody. `guard` turns it into the normalized reason.
    result =
      guard do
        {:ok, pid} = Kubereq.PodExec.start_link(args)
        {:ok, pid}
      end

    send(caller, {tag, result})

    case result do
      {:ok, exec} -> watch_exec(exec, into)
      {:error, _reason} -> :ok
    end
  end

  defp watch_exec(exec, into) do
    mon = Process.monitor(into)

    receive do
      {:EXIT, ^exec, reason} ->
        send(into, {:exec_down, exec, reason})

      {:DOWN, ^mon, :process, ^into, _reason} ->
        # Nobody left to deliver frames to. Closing is what keeps a dead reader
        # from leaving an exec stream open against the API server.
        close_exec(exec)
    end
  end

  @doc false
  # Public so the parameter table is assertable without an API server. It cannot
  # be reached through the `:req_adapter` seam: `:adapter` is overwritten on every
  # `:connect` operation, so a stubbed adapter never sees an exec at all.
  @spec exec_params([String.t()], keyword()) :: keyword()
  def exec_params(command, opts) do
    [
      command: command,
      stdin: Keyword.get(opts, :stdin, false),
      stdout: true,
      stderr: Keyword.get(opts, :stderr, false),
      tty: false
    ]
    |> maybe_container(opts[:container])
  end

  defp maybe_container(params, nil), do: params
  defp maybe_container(params, container), do: [{:container, container} | params]

  @doc """
  Send a close frame to a `PodExec` started by `open_exec/5`.

  Never `Kubereq.PodExec.open?/1` first: in 0.4.4
  `Kubereq.Connect.handle_call(:open?, _, _)` returns a malformed two-tuple
  GenServer reply, which crashes the very process being probed.
  """
  @spec close_exec(pid() | nil) :: :ok
  def close_exec(nil), do: :ok

  def close_exec(pid) do
    if Process.alive?(pid), do: Kubereq.PodExec.close(pid)
    :ok
  end

  # --- error vocabulary ---

  @doc false
  # Public only so `kubernetes_unit_test.exs` can drive the whole table without
  # an API server. Structurally the same as Docker.API's normalizer, but driven
  # by kubereq's "non-2xx is {:ok, _}" shape rather than Req's.
  @spec normalize(term()) :: {:ok, term()} | {:error, term()}
  def normalize({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  def normalize({:ok, %{status: 404, body: body}}) do
    {:error, {:k8s, {:not_found, summarize(body)}}}
  end

  # RBAC failures get their own shape rather than a generic 4xx. A cluster that
  # will not let us create Pods is an operator problem with a specific fix, and
  # "http_status 403" in a crash report buries the one thing worth reading.
  def normalize({:ok, %{status: 403, body: body}}) do
    {:error, {:k8s, {:forbidden, summarize(body)}}}
  end

  def normalize({:ok, %{status: status, body: body}}) do
    {:error, {:k8s, {:http_status, status, summarize(body)}}}
  end

  # Matched via __struct__ rather than struct patterns so this module still
  # compiles with :kubereq and :req absent -- the module names are plain atoms.
  def normalize({:error, %{__struct__: Kubereq.Error.StepError, code: code}}) do
    {:error, {:k8s, {:step, code}}}
  end

  def normalize({:error, %{__struct__: struct, reason: reason}})
      when struct in [Req.TransportError, Mint.TransportError] do
    {:error, {:k8s, {:transport, reason}}}
  end

  def normalize({:error, exception}) do
    {:error, {:k8s, {:exception, Exception.message(exception)}}}
  end

  @doc false
  # Kubernetes error bodies are a `Status` object with a "message". Keep them
  # short for the same reason Docker.API does: these strings reach crash reports
  # and must never carry a response payload -- or an echoed secret -- into logs.
  #
  # 200 *characters*, not bytes, and deliberately so: `binary_part/3` would cut
  # a multi-byte codepoint in half and hand the logger invalid UTF-8. The
  # difference only matters for a non-ASCII Status message, where the ceiling
  # becomes ~800 bytes -- still nowhere near a payload.
  @spec summarize(term()) :: String.t()
  def summarize(%{"message" => message}) when is_binary(message),
    do: String.slice(message, 0, 200)

  def summarize(body) when is_binary(body), do: String.slice(body, 0, 200)

  # A v4 channel-3 `Status` with no "message" — e.g. a Failure whose detail is
  # only in `details.causes` — would otherwise summarize to "" and lose the one
  # thing worth reporting. Bounded structurally for the reason bounded_inspect/1
  # exists.
  def summarize(%{"status" => _} = status),
    do: status |> inspect(limit: 5) |> String.slice(0, 200)

  def summarize(_), do: ""

  # --- Private ---

  defp run(fun), do: guard(do: normalize(fun.()))

  defp bounded(config, fun) do
    task = Task.async(fun)

    case Task.yield(task, exec_timeout(config)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:k8s, :exec_timeout}}
      {:exit, reason} -> {:error, {:k8s, {:exit, reason}}}
    end
  end

  defp timeout(config), do: config[:timeout] || @default_timeout
  defp exec_timeout(config), do: config[:exec_timeout] || @default_exec_timeout
end
