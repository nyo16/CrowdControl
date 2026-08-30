defmodule Sandboxd.Application do
  @moduledoc """
  Boots the agent from environment variables only.

  | Variable | Default | Purpose |
  |---|---|---|
  | `CC_SANDBOXD_TOKEN` | — | bearer token every route but `/v1/health` requires |
  | `CC_SANDBOXD_PORT` | `8080` | listen port |
  | `CC_SANDBOXD_BIND` | `127.0.0.1` | listen address |
  | `CC_SANDBOXD_CAPTURE` | `/var/log/cc/out.jsonl` | capture file path |

  No config file, no `runtime.exs`, no arguments. A release that reads its
  configuration from the environment can be dropped into a container image or
  fetched onto a bare VM by a startup script without either of them having to
  know anything about Elixir's config system.

  ## Binding to loopback is the default, and widening it is explicit

  `CC_SANDBOXD_BIND` exists because the Docker provider publishes the agent
  port on the host's `127.0.0.1` — which requires the agent to listen on the
  container's own external interface, since the published port is forwarded
  from outside the container. A GCE sandbox never widens it: the agent listens
  on `127.0.0.1` and is reached only through an SSH tunnel.

  Nothing here makes the port routable; that is a property of the provider's
  network, and every provider keeps it non-routable.

  ## Startup fails closed on a missing token

  A missing `CC_SANDBOXD_TOKEN` is a hard boot failure, not a warning that
  degrades into an unauthenticated remote-exec endpoint.
  """

  use Application

  require Logger

  @default_port 8080
  @default_bind "127.0.0.1"

  @impl true
  def start(_type, _args) do
    Sandboxd.Auth.put_token(token!())

    ip = bind!()
    port = port!()
    capture = Sandboxd.Capture.default_path()

    children = [
      {Sandboxd.Capture, path: capture},
      Sandboxd.Exec,
      {Bandit, plug: Sandboxd.Router, scheme: :http, ip: ip, port: port}
    ]

    # The token is not logged, and neither is anything derived from it.
    Logger.info("sandboxd listening on #{:inet.ntoa(ip)}:#{port}, capture #{capture}")

    Supervisor.start_link(children, strategy: :one_for_one, name: Sandboxd.Supervisor)
  end

  defp token! do
    case System.get_env("CC_SANDBOXD_TOKEN") do
      token when is_binary(token) and byte_size(token) > 0 ->
        token

      _ ->
        raise """
        CC_SANDBOXD_TOKEN is not set.

        sandboxd refuses to start without it: every route except /v1/health
        requires a bearer token, and starting without one would expose an
        unauthenticated process-exec endpoint on this sandbox's agent port.
        """
    end
  end

  defp port! do
    case Integer.parse(System.get_env("CC_SANDBOXD_PORT", to_string(@default_port))) do
      {port, ""} when port >= 0 and port <= 65_535 -> port
      _ -> raise "CC_SANDBOXD_PORT must be an integer between 0 and 65535"
    end
  end

  defp bind! do
    address = System.get_env("CC_SANDBOXD_BIND", @default_bind)

    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> ip
      {:error, _} -> raise "CC_SANDBOXD_BIND must be an IP address, got: #{address}"
    end
  end
end
