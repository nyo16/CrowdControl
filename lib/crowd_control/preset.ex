defmodule CrowdControl.Preset do
  @moduledoc """
  Ready-made service specs for the strict two-tier browser layout: the
  sandbox has no egress at all, a browser shares a network with it, and only
  an allowlist proxy that the sandbox cannot reach goes out.

      sbx (internal)          brw (internal)          egress
      sandbox ── browser ──── egress-proxy ─────────── internet (allowlist)

  Every preset returns a plain service map — the shape both
  `CrowdControl.Provider.Compose` and `CrowdControl.Backend.Kubernetes` take
  in `:services` — already checked by `CrowdControl.Service.normalize/2`, so a
  bad option raises `ArgumentError` where it was written rather than at
  provision time:

    * `CrowdControl.Preset.EgressProxy` — Smokescreen;
    * `CrowdControl.Preset.Browser` — Chromium behind Playwright's
      `launchServer` and `playwright mcp`;
    * `CrowdControl.Preset.LogShipper` — Vector, redacting and shipping the
      capture.

  `browser_stack/1` wires the first two together for either substrate.
  """

  alias CrowdControl.Preset.Browser
  alias CrowdControl.Preset.EgressProxy

  @default_network "brw"

  @doc """
  The browser and its proxy, wired together, for `:compose` or
  `:kubernetes`. Returns `{services, networks, sandbox_overrides}`:

    * `services` — `[proxy, browser]`, for the stack's (Compose) or backend's
      (Kubernetes) `:services`. On Kubernetes both are `placement: :separate`.
    * `networks` — `[%{name: "brw"}]` for Compose's `:networks`; `[]` on
      Kubernetes, where a membership is only a NetworkPolicy edge.
    * `sandbox_overrides` — session options:
      `CrowdControl.Preset.Browser.sandbox_overrides/1` (the WebSocket env,
      the inline MCP config, `strict_mcp_config`, the system-prompt line),
      plus `sandbox_ports:` on Kubernetes when `:app_ports` is given.

  Options:

    * `:substrate` — `:compose` or `:kubernetes`, required.
    * `:proxy` — `CrowdControl.Preset.EgressProxy` options; `:image` and
      `:allow_domains` are required.
    * `:browser` — `CrowdControl.Preset.Browser` options; `:image` is
      required.
    * `:network` — the browser↔proxy network, default `"brw"`.
    * `:app_ports` — ports of an app the agent runs in the sandbox for the
      browser to test. The browser then bypasses the proxy for `sandbox`
      (the proxy would refuse a private address), and on Kubernetes the
      sandbox Pod admits the browser on exactly these ports.

  Composing it, on Compose:

      {services, networks, overrides} =
        CrowdControl.Preset.browser_stack(
          substrate: :compose,
          proxy: [image: "crowd_control/smokescreen:dev", allow_domains: ["example.com"], nc: true],
          browser: [image: "crowd_control/browser:dev"]
        )

      CrowdControl.run(prompt,
        overrides ++
          [backend: {CrowdControl.Backend.Sandboxd,
                     provider: {CrowdControl.Provider.Compose,
                                image: "crowd_control/sandbox-browser:dev",
                                services: services ++ my_services,
                                networks: networks}}]
      )

  Merge the overrides' `:env`, `:mcp_config` and `:extra_args` into the
  session's own rather than letting one keyword shadow the other.
  """
  @spec browser_stack(keyword()) :: {[map()], [map()], keyword()}
  def browser_stack(opts) do
    substrate = substrate!(opts)
    network = Keyword.get(opts, :network, @default_network)
    app_ports = app_ports!(opts)
    placement = if substrate == :kubernetes, do: [placement: :separate], else: []

    proxy =
      opts
      |> keyword!(:proxy)
      |> Keyword.merge([network: network] ++ placement)
      |> EgressProxy.spec()

    browser_opts = keyword!(opts, :browser)

    bypass =
      if app_ports == [],
        do: Keyword.get(browser_opts, :proxy_bypass, []),
        else: Enum.uniq(Keyword.get(browser_opts, :proxy_bypass, []) ++ ["sandbox"])

    browser =
      browser_opts
      |> Keyword.merge(
        [proxy: EgressProxy.url(proxy), proxy_network: network, proxy_bypass: bypass] ++
          placement
      )
      |> Browser.spec()

    networks = if substrate == :compose, do: [%{name: network}], else: []

    sandbox_ports =
      if substrate == :kubernetes and app_ports != [], do: [sandbox_ports: app_ports], else: []

    {[proxy, browser], networks, Browser.sandbox_overrides(browser) ++ sandbox_ports}
  end

  defp substrate!(opts) do
    case Keyword.get(opts, :substrate) do
      substrate when substrate in [:compose, :kubernetes] ->
        substrate

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: :substrate must be :compose or :kubernetes, " <>
                "got: #{inspect(other)}"
    end
  end

  defp keyword!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_list(value) ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: #{inspect(key)} options are required, got: #{inspect(other)}"
    end
  end

  defp app_ports!(opts) do
    ports = Keyword.get(opts, :app_ports, [])

    if is_list(ports) and Enum.all?(ports, &(is_integer(&1) and &1 in 1..65_535)),
      do: ports,
      else: raise(ArgumentError, "#{inspect(__MODULE__)}: bad :app_ports #{inspect(ports)}")
  end

  # --- shared by the presets ---

  @doc false
  @spec required_string!(keyword(), atom(), module()) :: String.t()
  def required_string!(opts, key, preset) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(preset)}: #{inspect(key)} is required, got: #{inspect(other)}"
    end
  end

  @doc false
  @spec put_placement(map(), term()) :: map()
  def put_placement(spec, nil), do: spec
  def put_placement(spec, placement), do: Map.put(spec, :placement, placement)

  @doc false
  # The same check both substrates run, so a preset never hands back a spec
  # `acquire/1` or `provision/1` would refuse for its shape.
  @spec validate!(map(), module()) :: map()
  def validate!(spec, preset) do
    case CrowdControl.Service.normalize(spec, :sidecar) do
      {:ok, _service} ->
        spec

      {:error, reason} ->
        raise ArgumentError, "#{inspect(preset)}: invalid spec: #{inspect(reason)}"
    end
  end

  @doc false
  @spec cidr?(term()) :: boolean()
  def cidr?(cidr) when is_binary(cidr) do
    with [ip, bits] <- String.split(cidr, "/"),
         {:ok, address} <- :inet.parse_strict_address(String.to_charlist(ip)),
         {bits, ""} <- Integer.parse(bits) do
      bits >= 0 and bits <= if(tuple_size(address) == 4, do: 32, else: 128)
    else
      _ -> false
    end
  end

  def cidr?(_cidr), do: false
end
