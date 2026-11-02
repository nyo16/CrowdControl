defmodule CrowdControl.Backend.Docker.API do
  @moduledoc """
  Thin HTTP layer over the Docker Engine API.

  Handles transport selection (Unix socket or TCP), JSON encoding, and error
  normalization. Nothing here knows what CrowdControl uses Docker *for* — that
  is `CrowdControl.Backend.Docker`'s job.

  ## Error normalization

  Every function returns `{:ok, term}` or `{:error, reason}`. Transport failures
  (`%Req.TransportError{}`), non-2xx statuses, and timeouts are all flattened
  into `{:error, {:docker, reason}}` shapes here, so that by the time a failure
  reaches `CrowdControl.Session` it looks like every other backend failure. See
  `CrowdControl.Backend.safe/2` for why that normalization belongs in the
  backend rather than in the session.
  """

  # :req is an optional dependency, so this module must still COMPILE without
  # it -- hence no `%Req.Response{}` struct patterns anywhere below (struct
  # expansion needs the module at compile time; plain map patterns do not).
  # CrowdControl.Backend.Docker.provision/1 raises a clear message at runtime if
  # Req is genuinely missing.
  @compile {:no_warn_undefined, Req}

  alias CrowdControl.ReqAdapter

  @default_host "unix:///var/run/docker.sock"
  @default_timeout 30_000

  @typedoc "Docker connection config: `:docker_host`, `:timeout`."
  @type config :: keyword()

  @doc """
  Build Req options for the configured Docker host.

  Accepts `unix://<path>`, `http://host:port`, and `tcp://host:port`.

      iex> CrowdControl.Backend.Docker.API.transport("unix:///var/run/docker.sock")
      {:ok, [base_url: "http://localhost", unix_socket: "/var/run/docker.sock"]}

      iex> CrowdControl.Backend.Docker.API.transport("tcp://10.0.0.5:2375")
      {:ok, [base_url: "http://10.0.0.5:2375"]}
  """
  @spec transport(String.t()) :: {:ok, keyword()} | {:error, term()}
  def transport("unix://" <> path) when byte_size(path) > 0 do
    {:ok, [base_url: "http://localhost", unix_socket: path]}
  end

  def transport("tcp://" <> hostport), do: {:ok, [base_url: "http://" <> hostport]}
  def transport("http://" <> _ = url), do: {:ok, [base_url: url]}
  def transport("https://" <> _ = url), do: {:ok, [base_url: url]}
  def transport(other), do: {:error, {:docker, {:bad_host, other}}}

  @doc "The configured Docker host, defaulting to the standard Unix socket."
  @spec host(config()) :: String.t()
  def host(config) do
    config[:docker_host] || Application.get_env(:crowd_control, :docker_host) || @default_host
  end

  @doc """
  Issue a request, returning the decoded body on 2xx.

  `opts` are merged into the Req call, so `:json`, `:params`, and `:into` all
  work as usual.
  """
  @spec request(config(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(config, method, path, opts \\ []) do
    with {:ok, base} <- base_options(config, method, path) do
      base
      |> Keyword.merge(decode_body: true)
      |> Keyword.merge(opts)
      |> ReqAdapter.new()
      |> Req.request()
      |> normalize()
    end
  end

  @doc """
  Like `request/4` but returns the raw `Req.Response` rather than the body.

  Needed for streaming (`into: :self`), where the caller must keep the response
  struct in order to call `Req.parse_message/2` and
  `Req.cancel_async_response/1`.
  """
  @spec stream(config(), atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def stream(config, method, path, opts \\ []) do
    with {:ok, base} <- base_options(config, method, path) do
      result = base |> Keyword.merge(opts) |> ReqAdapter.new() |> Req.request()

      case result do
        {:ok, %{status: status} = resp} when status in 200..299 ->
          {:ok, resp}

        {:ok, %{status: status, body: body}} ->
          {:error, {:docker, {:http_status, status, summarize(body)}}}

        {:error, reason} ->
          {:error, {:docker, transport_reason(reason)}}
      end
    end
  end

  @doc """
  The daemon's Engine version as `{major, minor, patch}` (`GET /version`).

  Cached per `docker_host` in `:persistent_term`, the same trade as the
  Kubernetes enforcement probe: a daemon does not change version under a live
  VM often enough to pay a round trip per acquire, and a VM restart re-reading
  it once is the correct cost. Only a parsed answer is cached; a failed or
  unparseable one is returned and asked again next time.
  """
  @spec server_version(config()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def server_version(config) do
    key = {__MODULE__, :server_version, host(config)}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, body} <- request(config, :get, "/version"),
             {:ok, version} <- parse_version(body) do
          :persistent_term.put(key, version)
          {:ok, version}
        end

      version ->
        {:ok, version}
    end
  end

  @doc false
  # Public so the table of real-world version strings is assertable without a
  # daemon: "26.1.4", "25.0.5-ce", "28.0.0-rc.1", and the patch-less "27.1".
  @spec parse_version(term()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def parse_version(%{"Version" => version}) when is_binary(version) do
    case Regex.run(~r/^v?(\d+)\.(\d+)(?:\.(\d+))?/, version) do
      [_, major, minor, patch] -> {:ok, {int(major), int(minor), int(patch)}}
      [_, major, minor] -> {:ok, {int(major), int(minor), 0}}
      nil -> {:error, {:docker, {:unparseable_version, String.slice(version, 0, 64)}}}
    end
  end

  def parse_version(_body), do: {:error, {:docker, {:unparseable_version, nil}}}

  defp int(digits), do: String.to_integer(digits)

  # `:req_adapter` is a test seam, threaded in exactly as
  # CrowdControl.Backend.Kubernetes.API does it: a hermetic test supplies a
  # function that answers Engine API calls, and needs no daemon, no container,
  # and no socket. Nothing in production sets it. It stays a function this far
  # and becomes a module adapter in `ReqAdapter.new/1` above — see
  # CrowdControl.ReqAdapter.
  defp base_options(config, method, path) do
    with {:ok, transport} <- transport(host(config)) do
      options =
        Keyword.merge(transport,
          method: method,
          url: path,
          receive_timeout: config[:timeout] || @default_timeout,
          retry: false
        )

      {:ok, Keyword.merge(options, ReqAdapter.req_options(config[:req_adapter]))}
    end
  end

  # --- Private ---

  defp normalize({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp normalize({:ok, %{status: 404, body: body}}) do
    {:error, {:docker, {:not_found, summarize(body)}}}
  end

  defp normalize({:ok, %{status: status, body: body}}) do
    {:error, {:docker, {:http_status, status, summarize(body)}}}
  end

  defp normalize({:error, reason}), do: {:error, {:docker, transport_reason(reason)}}

  # Remote backends fail in shapes a local subprocess never does. Flattening
  # them here is what lets Session keep a single failure vocabulary.
  #
  # Matched via __struct__ rather than a struct pattern so this module still
  # compiles when the optional :req dependency is absent -- the module names are
  # plain atoms in a guard, which needs nothing loaded.
  #
  # There is deliberately no catch-all clause. `Req.request/1` is spec'd
  # `{:ok, Req.Response.t()} | {:error, Exception.t()}`, so the second clause
  # already covers every value that can reach here; a third would be dead code
  # (dialyzer on OTP 27 flags it as pattern_match_cov, though OTP 29 does not).
  defp transport_reason(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Mint.TransportError],
       do: {:transport, reason}

  defp transport_reason(exception), do: {:exception, Exception.message(exception)}

  # Docker error bodies are `{"message": "..."}`. Keep them short: they end up
  # in crash reports and must never carry a large response payload -- or an
  # echoed secret -- into the logs.
  defp summarize(%{"message" => message}) when is_binary(message),
    do: String.slice(message, 0, 200)

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(_), do: ""
end
