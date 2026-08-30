defmodule CrowdControl.Backend.Sandboxd.API do
  @moduledoc """
  Every HTTP call to a `sandboxd` agent, and the one error vocabulary they
  produce.

  Client confinement, exactly as `CrowdControl.Backend.Docker.API` and
  `CrowdControl.Backend.Kubernetes.API` do it: no other module builds a `Req`
  request to an agent, and no other module invents an error shape.
  `CrowdControl.Session` only ever sees `{:error, {:sandboxd, _}}`.

  ## Vocabulary

    * `{:sandboxd, :unauthorized}` — `401`. On reattach this most likely means
      `:sandboxd_secret` was rotated, so the derived token no longer matches
      the one the sandbox was started with. That fails closed, deliberately.
    * `{:sandboxd, :not_found}` — `404`.
    * `{:sandboxd, :already_executed}` — `409` from `POST /v1/exec`. One exec
      per sandbox lifetime.
    * `{:sandboxd, :not_started}` — `409` from `POST /v1/stdin` before any exec.
    * `{:sandboxd, {:conflict, error}}` — any other `409`.
    * `{:sandboxd, {:http_status, status, message}}` — anything else non-2xx.
    * `{:sandboxd, {:transport, reason}}` — the connection failed.
    * `{:sandboxd, {:unexpected_body, body}}` — a 2xx whose shape is wrong.
    * `{:sandboxd, :ready_timeout}` — from `await_health/2` only.

  ## Authentication

  `authorization: Bearer <endpoint.token>`, then `endpoint.headers` merged
  **over** it. That order matters: a provider whose transport claims
  `authorization` for its own authentication (the Kubernetes API server's pod
  proxy) sets it in `headers` and moves the agent token to
  `x-cc-authorization`, which the agent accepts identically.

  ## Test seam

  Transport configuration, including `:adapter`, rides in
  `endpoint.req_options` and is merged into the `Req` call. A hermetic test
  builds an endpoint with `req_options: [adapter: fn req -> ... end]` and needs
  no daemon, no container, and no socket.

  Retries are off. `Req`'s default `retry: :safe_transient` turns one refused
  connection into 1s + 2s + 4s of backoff, and every caller here treats
  `{:error, _}` as authoritative — the reaper's fail-open path most of all.
  """

  # :req is optional, so this module must still compile without it. No
  # %Req.Response{} struct patterns anywhere below; plain map patterns need
  # nothing loaded. Backend.Sandboxd.provision/1 raises at runtime if it is
  # genuinely missing. Finch and Mint are req's own transitive deps and are
  # named only in guards, which needs nothing loaded either.
  @compile {:no_warn_undefined, [Req, Finch.TransportError, Mint.TransportError]}

  alias CrowdControl.Provider.Endpoint

  @default_timeout 30_000
  @health_poll_interval 100

  # Longer than the agent's 25s idle stream window, on purpose. See stream/2.
  @stream_idle_timeout 40_000

  @typedoc "Agent status, as reported by `GET /v1/status`."
  @type status :: %{
          alive: boolean(),
          exit_status: integer() | nil,
          bytes: non_neg_integer(),
          started: boolean()
        }

  @doc """
  Fold a mid-stream failure into this module's error vocabulary.

  `Req.parse_message/2` hands back a raw `%Finch.TransportError{}` for a
  connection that died under an open stream, and that is the one path where a
  failure reaches the reader without passing through `normalize/1`. Without
  this, the module's promise that callers only ever see `{:sandboxd, _}` would
  hold everywhere except the failure mode most likely to end up in a log.
  """
  @spec stream_error(term()) :: {:sandboxd, term()}
  def stream_error(reason), do: {:sandboxd, transport_reason_of(reason)}

  defp transport_reason_of(%{__struct__: _} = exception), do: transport_reason(exception)
  defp transport_reason_of(other), do: other

  @doc """
  `GET /v1/health`. The only unauthenticated route, and it returns no state.
  """
  @spec health(Endpoint.t(), keyword()) :: :ok | {:error, term()}
  def health(%Endpoint{} = endpoint, opts \\ []) do
    case request(endpoint, :get, "/v1/health", Keyword.merge([timeout: 2_000], opts)) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, body} -> {:error, {:sandboxd, {:unexpected_body, body}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Poll `GET /v1/health` until it answers, or `timeout` elapses.

  This is what makes `c:CrowdControl.Provider.acquire/1`'s contract satisfiable:
  provisioning that reports success before the agent answers is the single
  largest source of flaky remote backends.
  """
  @spec await_health(Endpoint.t(), timeout()) :: :ok | {:error, term()}
  def await_health(%Endpoint{} = endpoint, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_health(endpoint, deadline)
  end

  defp poll_health(endpoint, deadline) do
    case health(endpoint) do
      :ok ->
        :ok

      {:error, reason} ->
        if System.monotonic_time(:millisecond) + @health_poll_interval < deadline do
          Process.sleep(@health_poll_interval)
          poll_health(endpoint, deadline)
        else
          # The last failure is carried, not discarded: "ready_timeout" alone
          # cannot distinguish a slow boot from a wrong token or a closed port.
          {:error, {:sandboxd, {:ready_timeout, reason}}}
        end
    end
  end

  @doc """
  `POST /v1/exec`. Env travels in the JSON **body**, never in argv or a query
  string, and is never logged.
  """
  @spec exec(Endpoint.t(), String.t(), [String.t()], %{optional(String.t()) => String.t()}) ::
          :ok | {:error, term()}
  def exec(%Endpoint{} = endpoint, executable, args, env) do
    body = %{"executable" => executable, "args" => args, "env" => env}

    case request(endpoint, :post, "/v1/exec", json: body) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, body} -> {:error, {:sandboxd, {:unexpected_body, body}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`POST /v1/stdin`, base64-encoded so arbitrary bytes survive JSON."
  @spec write(Endpoint.t(), iodata()) :: :ok | {:error, term()}
  def write(%Endpoint{} = endpoint, data) do
    body = %{"data" => Base.encode64(IO.iodata_to_binary(data))}

    case request(endpoint, :post, "/v1/stdin", json: body) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, body} -> {:error, {:sandboxd, {:unexpected_body, body}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `GET /v1/status`, optionally long-polled for up to `wait_ms` server-side.

  A long poll is what stops a session from spinning on a live sandbox that has
  simply not produced output yet.
  """
  @spec status(Endpoint.t(), non_neg_integer()) :: {:ok, status()} | {:error, term()}
  def status(%Endpoint{} = endpoint, wait_ms \\ 0) do
    opts = [params: [wait_ms: wait_ms], timeout: wait_ms + @default_timeout]

    case request(endpoint, :get, "/v1/status", opts) do
      {:ok, %{"alive" => alive, "bytes" => bytes} = body} ->
        {:ok,
         %{
           alive: alive,
           bytes: bytes,
           exit_status: body["exit_status"],
           started: body["started"] || false
         }}

      {:ok, body} ->
        {:error, {:sandboxd, {:unexpected_body, body}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  `GET /v1/stream?offset=N` as an `into: :self` response.

  Returns the raw `Req.Response` because the caller must keep it to call
  `Req.parse_message/2` and `Req.cancel_async_response/1` — the same
  cancel-and-resume backpressure loop `CrowdControl.Backend.Docker` uses.
  Offsets are 0-indexed: the agent serves a byte offset directly, with none of
  `tail -c +N`'s 1-indexed hazard.

  ## `:receive_timeout` is the silent-sandbox watchdog

  It is the *only* thing that turns "container is up, agent answers nothing,
  ever" into an `:eof` — nothing else in the stack notices, because the
  connection stays open and no bytes are owed. When it fires, `Req` delivers a
  normal `{:error, %Finch.TransportError{reason: :timeout}}` message rather than
  raising, so the reader's existing error path handles it.

  It is set to `#{div(@stream_idle_timeout, 1000)}s`, deliberately longer than
  the agent's own idle stream window: the agent should end an idle response
  first, so an ordinary interactive pause produces a clean `:done` and a
  re-request rather than looking like a dead sandbox.
  """
  @spec stream(Endpoint.t(), non_neg_integer()) :: {:ok, Req.Response.t()} | {:error, term()}
  def stream(%Endpoint{} = endpoint, offset) do
    result =
      endpoint
      |> req_options(:get, "/v1/stream",
        params: [offset: offset],
        into: :self,
        timeout: @stream_idle_timeout
      )
      |> Req.request()

    case result do
      {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp}
      {:ok, %{status: status, body: body}} -> {:error, http_error(status, body)}
      {:error, reason} -> {:error, {:sandboxd, transport_reason(reason)}}
    end
  end

  @doc """
  `PUT /v1/files/*path`. Writes `body` inside the sandbox at `mode`.

  Traversal is rejected here as well as by the agent. Two checks for one
  property is not redundancy: the client-side one is the only reason a caller
  gets a comprehensible error instead of a `400`, and the server-side one is
  the only one that holds against a caller that is not this library.
  """
  @spec put_file(Endpoint.t(), Path.t(), iodata(), non_neg_integer()) :: :ok | {:error, term()}
  def put_file(%Endpoint{} = endpoint, path, body, mode \\ 0o600) do
    with {:ok, safe} <- safe_path(path) do
      opts = [
        body: IO.iodata_to_binary(body),
        params: [mode: octal(mode)],
        headers: [{"content-type", "application/octet-stream"}]
      ]

      case request(endpoint, :put, "/v1/files" <> safe, opts) do
        {:ok, %{"ok" => true}} -> :ok
        {:ok, body} -> {:error, {:sandboxd, {:unexpected_body, body}}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reject a path with `.`/`..` segments or a null byte, and require it absolute.

  Public and pure so the check is testable without an agent.
  """
  @spec safe_path(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_path(path) when is_binary(path) do
    segments = path |> String.split("/") |> Enum.reject(&(&1 == ""))

    cond do
      not String.starts_with?(path, "/") ->
        {:error, {:sandboxd, {:bad_path, "must be absolute"}}}

      segments == [] ->
        {:error, {:sandboxd, {:bad_path, "must not be empty"}}}

      Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, {:sandboxd, {:bad_path, "must not contain . or .. segments"}}}

      String.contains?(path, "\0") ->
        {:error, {:sandboxd, {:bad_path, "must not contain null bytes"}}}

      true ->
        {:ok, "/" <> Enum.join(segments, "/")}
    end
  end

  @doc """
  `POST /v1/shutdown`. Kills the CLI and halts the agent.

  Destroying the *sandbox* is the provider's job. A `404` or a transport error
  is success here: an agent that cannot be reached is already not running.
  """
  @spec shutdown(Endpoint.t()) :: :ok
  def shutdown(%Endpoint{} = endpoint) do
    _ = request(endpoint, :post, "/v1/shutdown", timeout: 5_000)
    :ok
  end

  # --- Private ---

  defp request(endpoint, method, path, opts) do
    endpoint
    |> req_options(method, path, opts)
    |> Req.request()
    |> normalize()
  end

  defp req_options(endpoint, method, path, opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)

    # :headers is popped and merged separately, never left to Keyword.merge/2.
    # Keyword.merge REPLACES a key wholesale, so a caller passing
    # `headers: [{"content-type", ...}]` would silently drop the authorization
    # header and get a 401 — which is exactly what PUT /v1/files did until the
    # integration test caught it.
    {extra_headers, opts} = Keyword.pop(opts, :headers, [])

    [
      base_url: endpoint.base_url,
      method: method,
      url: path,
      receive_timeout: timeout,
      retry: false,
      decode_body: true
    ]
    |> Keyword.merge(endpoint.req_options)
    |> Keyword.merge(opts)
    |> Keyword.put(:headers, headers(endpoint, extra_headers))
  end

  # Precedence, innermost first: the token-derived authorization header, then
  # per-request headers, then endpoint.headers. endpoint.headers wins because a
  # provider whose transport claims `authorization` for its own credential must
  # be able to say so and move the agent token to `x-cc-authorization`.
  defp headers(endpoint, extra) do
    (extra ++ endpoint.headers)
    |> Enum.reduce(%{"authorization" => "Bearer " <> endpoint.token}, fn {name, value}, acc ->
      Map.put(acc, String.downcase(name), value)
    end)
    |> Enum.to_list()
  end

  defp normalize({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp normalize({:ok, %{status: status, body: body}}) do
    {:error, http_error(status, body)}
  end

  defp normalize({:error, reason}), do: {:error, {:sandboxd, transport_reason(reason)}}

  defp http_error(401, _body), do: {:sandboxd, :unauthorized}
  defp http_error(404, _body), do: {:sandboxd, :not_found}

  defp http_error(409, %{"error" => "already_executed"}), do: {:sandboxd, :already_executed}
  defp http_error(409, %{"error" => "not_started"}), do: {:sandboxd, :not_started}
  defp http_error(409, body), do: {:sandboxd, {:conflict, summarize(body)}}

  defp http_error(status, body), do: {:sandboxd, {:http_status, status, summarize(body)}}

  # Three structs, one vocabulary, because the phase decides which one arrives:
  # `Req.get/2`'s *return* carries `%Req.TransportError{}` for a connect-phase
  # failure, while a mid-stream failure arrives as a message carrying
  # `%Finch.TransportError{source: %Mint.TransportError{}}`. A caller that only
  # folded the first would see a raw struct leak out of the backend the moment a
  # sandbox died mid-session.
  #
  # Matched via __struct__ rather than a struct pattern so this module compiles
  # without the optional :req dependency. Same discipline as Docker.API.
  defp transport_reason(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Finch.TransportError, Mint.TransportError],
       do: {:transport, reason}

  defp transport_reason(exception), do: {:exception, Exception.message(exception)}

  # Kept short: these land in crash reports, and must never carry a large
  # response payload — or an echoed secret — into the logs.
  defp summarize(%{"error" => error}) when is_binary(error), do: String.slice(error, 0, 200)
  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(_), do: ""

  defp octal(mode), do: "0" <> Integer.to_string(mode, 8)
end
