defmodule Sandboxd.Auth do
  @moduledoc """
  Bearer-token plug for every route except `GET /v1/health`.

  ## What the token is actually for

  It authenticates the **external caller**, and it grants code running inside
  the sandbox nothing whatsoever that it does not already have — that code
  *is* the thing the agent runs, and it can read `CC_SANDBOXD_TOKEN` from its
  own environment anyway. The token exists so that nothing else which can reach
  the agent's port can drive the CLI.

  Defence in depth is the provider's job, not this plug's: the port is
  published on `127.0.0.1` for Docker and Compose, and reached only through an
  SSH tunnel for GCE. No provider ever makes it routable.

  ## Comparison is constant-time

  `Plug.Crypto.secure_compare/2`. A byte-wise comparison here leaks the token
  one byte at a time to anything that can time responses, which for a
  loopback-published port includes every process on the host.

  ## Nothing is logged

  Not the token, not a prefix of it, not the supplied value on failure, not the
  header. A `401` has an empty body for the same reason: a distinct message for
  "no header" versus "wrong token" tells an attacker which half to work on.

  ## Two accepted header names

  `authorization: Bearer <token>` is the norm. `x-cc-authorization` is accepted
  identically, because a provider may reach the agent through an intermediary
  that consumes `authorization` for its own authentication — the Kubernetes API
  server's pod proxy does exactly that. Same token, same comparison; only the
  carrier differs.
  """

  import Plug.Conn

  @behaviour Plug

  @token_key {__MODULE__, :token}

  @doc """
  Store the expected token, read once at boot from `CC_SANDBOXD_TOKEN`.

  `:persistent_term` rather than a GenServer: this is read on every request and
  written exactly once, which is the access pattern `:persistent_term` exists
  for. It is also readable by in-sandbox code, which changes nothing — see the
  moduledoc.
  """
  @spec put_token(String.t() | nil) :: :ok
  def put_token(token), do: :persistent_term.put(@token_key, token)

  @doc "The expected token, or `nil` when none was configured."
  @spec token() :: String.t() | nil
  def token, do: :persistent_term.get(@token_key, nil)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if authorized?(conn, token()) do
      conn
    else
      conn
      |> send_resp(401, "")
      |> halt()
    end
  end

  # No configured token means no caller can ever authenticate. Failing closed is
  # the only safe reading of a missing CC_SANDBOXD_TOKEN: the alternative is an
  # unauthenticated remote-exec endpoint whenever a provider forgets to inject
  # one.
  defp authorized?(_conn, nil), do: false
  defp authorized?(_conn, ""), do: false

  defp authorized?(conn, expected) do
    conn
    |> presented_tokens()
    |> Enum.any?(&Plug.Crypto.secure_compare(&1, expected))
  end

  defp presented_tokens(conn) do
    for name <- ["authorization", "x-cc-authorization"],
        value <- get_req_header(conn, name),
        token = bearer(value),
        is_binary(token),
        do: token
  end

  defp bearer("Bearer " <> token), do: String.trim(token)
  defp bearer("bearer " <> token), do: String.trim(token)
  defp bearer(_other), do: nil
end
