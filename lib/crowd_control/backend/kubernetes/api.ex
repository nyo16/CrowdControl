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
      its caller. `open_exec/5` rescues the first; the caller must trap exits
      for the second.

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
            [Kubereq, Kubereq.Kubeconfig, Kubereq.Kubeconfig.Default, Kubereq.PodExec]}

  @default_timeout 30_000
  @default_exec_timeout 15_000

  # One page is 500 rather than the API server's 500-ish default because the
  # common case -- one owner's live sandboxes -- fits in a single round trip.
  @page_limit 500

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
        e -> {:error, {:k8s, {:exception, Exception.message(e)}}}
      catch
        :exit, reason -> {:error, {:k8s, {:exit, reason}}}
      end
    end
  end

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

    case Kubereq.exec(client(config, @pod_api), namespace(config), pod_name, params) do
      {:ok, %{status: 101, body: stream}} -> {:ok, collect_stdout(stream)}
      other -> normalize(other)
    end
  end

  defp collect_stdout(stream) do
    stream
    |> Enum.reduce([], fn
      {:stdout, data}, acc -> [data | acc]
      _other, acc -> acc
    end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

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

  Bounded by `:exec_timeout` like `exec_once/4`.
  """
  @spec exec_stdin(config(), String.t(), [String.t()], iodata()) :: :ok | {:error, term()}
  def exec_stdin(config, pod_name, command, payload) do
    bounded(config, fn ->
      # PodExec links to whoever called start_link/1, which inside bounded/2 is
      # this task. Trap so a transport failure closes the exec rather than
      # killing the task out from under Task.yield/2.
      Process.flag(:trap_exit, true)
      guard(do: do_exec_stdin(config, pod_name, command, payload))
    end)
  end

  defp do_exec_stdin(config, pod_name, command, payload) do
    with {:ok, pid} <- open_exec(config, pod_name, command, self(), stdin: true) do
      :ok = Kubereq.PodExec.send_stdin(pid, IO.iodata_to_binary(payload))
      :ok = Kubereq.PodExec.close(pid)
      await_close(pid)
    end
  end

  defp await_close(pid) do
    receive do
      {:close, _code, _reason} -> :ok
      {:EXIT, ^pid, :normal} -> :ok
      {:EXIT, ^pid, reason} -> {:error, {:k8s, {:exec_closed, reason}}}
      _other -> await_close(pid)
    end
  end

  @doc """
  Start a long-lived `Kubereq.PodExec` delivering frames to `into`.

  Two `kubereq` 0.4.4 hazards are handled here and nowhere else:

    * On a failed websocket upgrade Kubereq.Connect's `init/1` raises a
      `WithClauseError`, `GenServer.start_link/3` returns `{:error, _}`, and
      Kubereq.Connect's own `{:ok, pid} = …` turns that into a `MatchError` in
      *this* process. The `guard` above converts it to `{:error, _}`.
      (Written unlinked on purpose: that module is `@moduledoc false`, so an
      autolink to it is a broken doc reference.)
    * The returned process is **linked to the caller** and stops with the
      transport error as its reason. The caller must be trapping exits, or a
      routine websocket blip kills it. `Backend.Kubernetes`'s reader does.
  """
  @spec open_exec(config(), String.t(), [String.t()], pid(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def open_exec(config, pod_name, command, into, opts \\ []) do
    guard do
      args =
        [
          req: client(config, @pod_api),
          namespace: namespace(config),
          name: pod_name,
          into: into
        ] ++ exec_params(command, opts)

      {:ok, pid} = Kubereq.PodExec.start_link(args)
      {:ok, pid}
    end
  end

  defp exec_params(command, opts) do
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
