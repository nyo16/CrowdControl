defmodule CrowdControl.Preset.Browser do
  @moduledoc """
  A headless Chromium the sandboxed agent drives from another container: a
  Playwright `launchServer` WebSocket on 3000 for `playwright-cli` and scripts,
  and `playwright mcp` on 8931 bound to that same browser.

      browser = CrowdControl.Preset.Browser.spec(
        image: "crowd_control/browser:dev",
        proxy: "http://egress-proxy:4750"
      )

      CrowdControl.Preset.Browser.sandbox_overrides(browser)
      #=> [env: %{"PW_WS_ENDPOINT" => "ws://browser:3000/ccpw_…", …},
      #    mcp_config: %{"mcpServers" => %{"playwright" => …}}, …]

  The browser has `egress: :none`. It sits on `sbx` with the sandbox and on
  the proxy's network (`"brw"`), so the only way out is the proxy, and a page
  that is not on the allowlist fails with `net::ERR_PROXY_AUTH_UNSUPPORTED`.
  The proxy is fixed server-side at launch — a `run-server` client could pick
  its own — but that is defence in depth: **the network is the boundary**, and
  neither port has authentication beyond the per-session WebSocket path.

  ## Image contract (`examples/images/browser` meets it)

    * reads `PW_WS_TOKEN` (the `wsPath`), `PW_PROXY_SERVER` and, when set,
      `PW_PROXY_BYPASS`, and passes Chromium
      `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`, so WebRTC
      cannot send UDP around the proxy;
    * serves MCP with `--allowed-hosts <name>:8931` (`MCP_ALLOWED_HOSTS` carries
      the value) — Playwright MCP 403s any other `Host`;
    * starts MCP only once the WebSocket server listens, which is why a TCP
      check on 8931 is the Kubernetes readiness;
    * has `node` on `PATH` (the Compose healthcheck connects to both ports) and
      an init (`tini`), since Kubernetes has no `Init` flag.

  ## Options

    * `:image` — required.
    * `:proxy` — required: the proxy URL (`CrowdControl.Preset.EgressProxy.url/1`),
      or `false` for a browser with no route out at all.
    * `:proxy_network` — the network shared with the proxy, default `"brw"`.
    * `:proxy_bypass` — hosts Chromium reaches directly, e.g. `["sandbox"]` for
      a dev server under test. Never a loopback name: leaving the bypass free
      of them is what makes Playwright send loopback through the proxy (which
      denies it), and naming one turns that off.
    * `:token` — the WebSocket path; default `mint_token/0`. It is a
      capability: anyone who knows it and can reach port 3000 controls the
      browser, so it carries a `ccpw_` prefix that
      `CrowdControl.Preset.LogShipper` redacts by default.
    * `:name` — default `"browser"`; the sandbox reaches it as
      `ws://<name>:3000/<token>` and `http://<name>:8931/mcp`.
    * `:user` — default `"10001:10001"`, the example image's fixed uid.
    * `:placement` — Kubernetes only; `browser_stack/1` sets `:separate`.

  Resources follow playwright.dev's container advice: a 1 GiB `/dev/shm`
  (Compose `ShmSize`, Kubernetes an in-memory `emptyDir`), an init, and a
  512 MiB in-memory `/tmp`, where Chromium keeps its profile. The `/tmp` is
  `noexec,nosuid` on Compose only: on Kubernetes it is an `emptyDir`, which
  mounts exec (see SECURITY.md).
  """

  @ws_port 3000
  @mcp_port 8931
  @default_name "browser"
  @default_network "brw"
  @default_user "10001:10001"
  @shm_bytes 1_073_741_824
  @tmp_options "rw,noexec,nosuid,size=512m"

  # Every spelling Playwright's `shouldProxyLoopback` treats as "the caller
  # chose loopback handling", which turns its forced `<-loopback>` off.
  @loopback ["localhost", "127.0.0.1", "::1", "[::1]", "<loopback>", "<-loopback>"]

  @token ~r/\A[A-Za-z0-9_-]{16,}\z/
  @host ~r/\A(\*\.)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/

  # Both ports, from inside the container, with the one runtime the image is
  # guaranteed to have. Kubernetes uses `tcp_port` instead.
  @healthcheck "const n=require('net');let k=0;" <>
                 "for(const p of [#{@ws_port},#{@mcp_port}]){" <>
                 "const s=n.connect(p,'127.0.0.1',()=>{s.end();if(++k===2)process.exit(0)});" <>
                 "s.on('error',()=>process.exit(1))}"

  @doc """
  The service spec. Raises `ArgumentError` on a missing or malformed option.
  """
  @spec spec(keyword()) :: map()
  def spec(opts) do
    image = CrowdControl.Preset.required_string!(opts, :image, __MODULE__)
    name = Keyword.get(opts, :name, @default_name)
    token = token!(opts)
    proxy = proxy!(opts)
    bypass = bypass!(opts)
    network = Keyword.get(opts, :proxy_network, @default_network)

    env =
      %{"PW_WS_TOKEN" => token, "MCP_ALLOWED_HOSTS" => "#{name}:#{@mcp_port}"}
      |> put_env("PW_PROXY_SERVER", proxy || nil)
      |> put_env("PW_PROXY_BYPASS", if(bypass == [], do: nil, else: Enum.join(bypass, ",")))

    %{
      name: name,
      image: image,
      egress: :none,
      networks: if(proxy, do: ["sbx", network], else: ["sbx"]),
      env: env,
      ports: [@ws_port, @mcp_port],
      ready: %{tcp_port: @mcp_port, test: ["CMD", "node", "-e", @healthcheck]},
      host_config: %{shm_size: @shm_bytes, init: true, tmpfs: %{"/tmp" => @tmp_options}},
      user: Keyword.get(opts, :user, @default_user)
    }
    |> CrowdControl.Preset.put_placement(Keyword.get(opts, :placement))
    |> CrowdControl.Preset.validate!(__MODULE__)
  end

  @doc """
  A fresh WebSocket token: `ccpw_` and 24 random bytes, base64url.

      iex> "ccpw_" <> rest = CrowdControl.Preset.Browser.mint_token()
      iex> byte_size(rest)
      32
  """
  @spec mint_token() :: String.t()
  def mint_token,
    do: "ccpw_" <> (24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  @doc "`ws://<name>:3000/<token>` for a spec from `spec/1`."
  @spec ws_endpoint(map()) :: String.t()
  def ws_endpoint(%{name: name, env: %{"PW_WS_TOKEN" => token}}),
    do: "ws://#{name}:#{@ws_port}/#{token}"

  @doc "`http://<name>:8931/mcp` for a spec from `spec/1`."
  @spec mcp_url(map()) :: String.t()
  def mcp_url(%{name: name}), do: "http://#{name}:#{@mcp_port}/mcp"

  @doc """
  The session options that wire the sandbox to the browser `spec`, to merge
  into the session's own:

    * `env` — `PW_WS_ENDPOINT` (for `chromium.connect/1` and
      `playwright-cli attach`) and `PW_TEST_CONNECT_WS_ENDPOINT` (read by
      `@playwright/test`);
    * `mcp_config` — an inline `%{"mcpServers" => %{"playwright" => …}}` with
      `"type" => "http"`, without which Claude Code skips the entry;
    * `strict_mcp_config: true`;
    * `extra_args` — `--append-system-prompt` with `system_prompt/1`.

  A caller with its own `:env`, `:mcp_config` or `:extra_args` merges the
  values rather than replacing the keyword.
  """
  @spec sandbox_overrides(map()) :: keyword()
  def sandbox_overrides(spec) do
    endpoint = ws_endpoint(spec)

    [
      env: %{"PW_WS_ENDPOINT" => endpoint, "PW_TEST_CONNECT_WS_ENDPOINT" => endpoint},
      mcp_config: %{
        "mcpServers" => %{"playwright" => %{"type" => "http", "url" => mcp_url(spec)}}
      },
      strict_mcp_config: true,
      extra_args: ["--append-system-prompt", system_prompt(spec)]
    ]
  end

  @doc "The one system-prompt line that tells the agent how the browser is reached."
  @spec system_prompt(map()) :: String.t()
  def system_prompt(spec) do
    "A headless Chromium runs in a separate container. Drive it with " <>
      "`playwright-cli attach \"$PW_WS_ENDPOINT\"` (snapshots are files under " <>
      "`.playwright-cli/`), connect scripts with " <>
      "`chromium.connect(process.env.PW_WS_ENDPOINT)` (`@playwright/test` reads " <>
      "PW_TEST_CONNECT_WS_ENDPOINT), or use the `playwright` MCP tools at #{mcp_url(spec)}. " <>
      "The browser reaches an app you run here as http://sandbox:<port>; bind it to 0.0.0.0. " <>
      "Sites off the egress allowlist fail with net::ERR_PROXY_AUTH_UNSUPPORTED: " <>
      "that is policy, not a fault to work around."
  end

  defp token!(opts) do
    case Keyword.get_lazy(opts, :token, &mint_token/0) do
      token when is_binary(token) ->
        if Regex.match?(@token, token),
          do: token,
          else: raise(ArgumentError, "#{inspect(__MODULE__)}: :token must be 16+ [A-Za-z0-9_-]")

      other ->
        raise ArgumentError, "#{inspect(__MODULE__)}: bad :token #{inspect(other)}"
    end
  end

  defp proxy!(opts) do
    case Keyword.fetch(opts, :proxy) do
      {:ok, false} ->
        false

      {:ok, url} when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host, port: port}
          when scheme in ["http", "https"] and is_binary(host) and host != "" and
                 is_integer(port) ->
            url

          _ ->
            raise ArgumentError, "#{inspect(__MODULE__)}: bad :proxy #{inspect(url)}"
        end

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: :proxy is required — a proxy URL, or false for a " <>
                "browser with no route out at all"
    end
  end

  defp bypass!(opts) do
    case Keyword.get(opts, :proxy_bypass, []) do
      hosts when is_list(hosts) ->
        Enum.each(hosts, &bypass_host!/1)
        hosts

      other ->
        raise ArgumentError, "#{inspect(__MODULE__)}: bad :proxy_bypass #{inspect(other)}"
    end
  end

  defp bypass_host!(host) when is_binary(host) do
    lower = String.downcase(host)

    cond do
      lower in @loopback or String.ends_with?(lower, ".localhost") ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: :proxy_bypass may not name loopback (#{inspect(host)}): " <>
                "it would stop Playwright sending loopback through the proxy"

      not Regex.match?(@host, host) ->
        raise ArgumentError, "#{inspect(__MODULE__)}: bad :proxy_bypass host #{inspect(host)}"

      true ->
        :ok
    end
  end

  defp bypass_host!(host),
    do: raise(ArgumentError, "#{inspect(__MODULE__)}: bad :proxy_bypass host #{inspect(host)}")

  defp put_env(env, _key, nil), do: env
  defp put_env(env, key, value), do: Map.put(env, key, value)
end
