defmodule CrowdControl.Backend.Credentials do
  @moduledoc """
  Credential rewriting shared by every remote backend that fronts an egress proxy.

  This exists as one module, used by every backend, for the same reason
  `CrowdControl.Backend.Shell` does. `Backend.Docker` passes the rewritten env
  through the exec API's `Env` array; `Backend.Kubernetes` renders it into an
  env file shipped over the exec stdin channel. The transport differs, the
  rewrite must not: the whole documented purpose of `apply_credentials/2` is
  that the real provider key is *removed* rather than overridden, and a second,
  subtly different copy is precisely how one of them ends up merely overriding
  it.
  """

  @doc """
  Rewrite the CLI's credential env for egress-proxy mode.

  When `:proxy_url` is set, the sandbox is pointed at the proxy and given a
  per-session token instead of the real key:

      ANTHROPIC_BASE_URL = proxy_url
      ANTHROPIC_API_KEY  = session_token

  **The real `:api_key` is removed, not merely overridden.** Leaving it in place
  would hand the sandbox a working provider credential even though every request
  is nominally routed through the proxy — which defeats the entire point of
  running the sandbox on an isolated network. That silent double-injection is
  the failure mode this function exists to prevent, and `docker_test.exs`
  asserts it directly.

  With no `:proxy_url`, the env is returned untouched.
  """
  @spec apply_credentials(map(), keyword()) :: map()
  def apply_credentials(env, config) do
    case config[:proxy_url] do
      nil ->
        env

      proxy_url ->
        env
        |> Map.delete("ANTHROPIC_API_KEY")
        |> Map.put("ANTHROPIC_BASE_URL", proxy_url)
        |> put_token(config[:session_token])
    end
  end

  defp put_token(env, nil), do: env
  defp put_token(env, token), do: Map.put(env, "ANTHROPIC_API_KEY", token)
end
