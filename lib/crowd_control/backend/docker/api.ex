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
    with {:ok, transport} <- transport(host(config)) do
      transport
      |> Keyword.merge(
        method: method,
        url: path,
        receive_timeout: config[:timeout] || @default_timeout,
        retry: false,
        decode_body: true
      )
      |> Keyword.merge(opts)
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
    with {:ok, transport} <- transport(host(config)) do
      result =
        transport
        |> Keyword.merge(
          method: method,
          url: path,
          receive_timeout: config[:timeout] || @default_timeout,
          retry: false
        )
        |> Keyword.merge(opts)
        |> Req.request()

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
  defp transport_reason(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Mint.TransportError],
       do: {:transport, reason}

  defp transport_reason(%{__exception__: true} = e), do: {:exception, Exception.message(e)}
  defp transport_reason(other), do: other

  # Docker error bodies are `{"message": "..."}`. Keep them short: they end up
  # in crash reports and must never carry a large response payload -- or an
  # echoed secret -- into the logs.
  defp summarize(%{"message" => message}) when is_binary(message),
    do: String.slice(message, 0, 200)

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(_), do: ""
end
