defmodule CrowdControl.Provider.Endpoint do
  @moduledoc """
  How to reach one sandbox's `sandboxd` agent, right now.

  Produced by `c:CrowdControl.Provider.acquire/1` and
  `c:CrowdControl.Provider.reconnect/1`, consumed by
  `CrowdControl.Backend.Sandboxd.API`, and **never persisted** — see the third
  load-bearing contract in `CrowdControl.Provider`.

  Every field here is ephemeral for a different reason:

    * `base_url` — a loopback port assigned per-connection. Docker publishes
      the agent on `127.0.0.1:0` and the daemon picks the port; a GCE tunnel
      opens a fresh local listener each time. Persisting it means reattaching
      to whatever else claimed that port.
    * `token` — derived, not stored. See `CrowdControl.Provider.token/1`.
    * `headers` — extra request headers, merged **over** the `authorization`
      header built from `token`. This exists so a provider whose transport
      already claims `authorization` (the Kubernetes API server's pod proxy)
      can say so, rather than the transport silently sending the wrong
      credential.
    * `req_options` — transport-specific `Req` options: `:unix_socket`,
      `:connect_options`, custom CA certs. Merged into `Req.new/1` by
      `CrowdControl.Backend.Sandboxd.API`.
    * `transport` — a resource whose lifetime equals the endpoint's, such as an
      `:ssh` connection ref for a forwarded port. Closed by
      `c:CrowdControl.Provider.release/1`. A pid or ref here is precisely why
      this struct cannot round-trip through `:erlang.term_to_binary/1`
      usefully.

  `Inspect` is overridden to redact `token` and `headers`, because endpoints
  end up in `Logger` metadata and error tuples on every failure path.
  """

  @enforce_keys [:base_url, :token]
  defstruct base_url: nil, token: nil, headers: [], req_options: [], transport: nil

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: String.t(),
          headers: [{String.t(), String.t()}],
          req_options: keyword(),
          transport: term()
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(endpoint, opts) do
      redacted = %{
        base_url: endpoint.base_url,
        token: "[REDACTED]",
        headers: redact_headers(endpoint.headers),
        req_options: Keyword.keys(endpoint.req_options),
        transport: endpoint.transport
      }

      concat(["#CrowdControl.Provider.Endpoint<", to_doc(redacted, opts), ">"])
    end

    defp redact_headers([]), do: []
    defp redact_headers(headers), do: Enum.map(headers, fn {name, _} -> {name, "[REDACTED]"} end)
  end
end
