defmodule CrowdControl.Provider.ComposeBrowserTest do
  # The strict two-tier browser layout on a live Docker daemon, assembled from
  # the presets exactly as a caller would. Excluded by default (see
  # test_helper.exs); run with `mix test --only compose`. Needs the example
  # images, none of which is published:
  #
  #     docker build --target sandbox-browser -t crowd_control/sandbox-browser:dev .
  #     docker build --build-arg PLAYWRIGHT_VERSION=$(cat PLAYWRIGHT_VERSION) \
  #       -t crowd_control/browser:dev examples/images/browser
  #     docker build -t crowd_control/smokescreen:dev examples/images/smokescreen
  #
  # plus `@vector_image` (LogShipper's default, pinned by digest) and internet
  # access for the proxy (example.com and wikipedia.org). No API key: the
  # "CLI" is a shell loop launched through sandboxd, so the transcript Vector
  # ships is one the real capture path wrote.
  #
  #     sbx (internal)                     brw (internal)        egress
  #     sandbox ── browser ─────────────── egress-proxy ──────── internet
  #        │                                    │
  #     cclog ── vector (console) ── proxylog ──┘
  #
  # Every probe runs from inside the stack, from the container whose posture
  # it is about, and by IP literal wherever a name could make a blocked path
  # look like a DNS miss.
  use ExUnit.Case, async: false

  alias CrowdControl.Backend.Docker.API
  alias CrowdControl.Backend.Docker.Demux
  alias CrowdControl.Backend.Sandboxd
  alias CrowdControl.Preset
  alias CrowdControl.Preset.LogShipper
  alias CrowdControl.Provider.Compose
  alias CrowdControl.Test.BrowserProbes, as: P

  @moduletag :compose
  @moduletag timeout: 600_000

  @sandbox_image "crowd_control/sandbox-browser:dev"
  @browser_image "crowd_control/browser:dev"
  @proxy_image "crowd_control/smokescreen:dev"
  @vector_image "timberio/vector:0.61.0-distroless-libc@" <>
                  "sha256:1a3451978644d5cd4b99a0b28c990791e2f7e1efbea4184122f1c59a56448143"
  @forwarder_image "alpine/socat:1.8.1.3"

  @app_port 5173
  @stun_port 3478
  @udp_log "/tmp/udp.log"

  setup_all do
    missing =
      Enum.reject(
        [@sandbox_image, @browser_image, @proxy_image, @vector_image, @forwarder_image],
        &match?({:ok, _}, API.request(config(), :get, "/images/#{&1}/json"))
      )

    if missing != [],
      do: raise("missing images #{inspect(missing)}; see this module's header for the builds")

    :ok
  end

  setup do
    previous = Application.get_env(:crowd_control, :sandboxd_secret)
    Application.put_env(:crowd_control, :sandboxd_secret, "compose-browser-secret-32-bytes!!")

    owner = "cc-cbrw-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
    session = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    on_exit(fn ->
      case Compose.list_live(owner: owner, timeout: 30_000) do
        {:ok, handles} -> Enum.each(handles, &Compose.release/1)
        _ -> :ok
      end

      if previous,
        do: Application.put_env(:crowd_control, :sandboxd_secret, previous),
        else: Application.delete_env(:crowd_control, :sandboxd_secret)
    end)

    {:ok, owner: owner, session: session}
  end

  test "browser, proxy and log shipper around a sandbox with no egress", context do
    {services, networks, overrides} =
      Preset.browser_stack(
        substrate: :compose,
        proxy: [
          image: @proxy_image,
          allow_domains: ["example.com"],
          nc: true,
          log_volume: "proxylog"
        ],
        browser: [image: @browser_image],
        app_ports: [@app_port]
      )

    vector =
      LogShipper.spec(sink: :console, capture_volume: "cclog", proxy_log_volume: "proxylog")

    # The sandbox-browser image's default entrypoint is the library's own
    # iex; as a Compose sandbox it runs the sandboxd release it also carries.
    sandbox = %{
      name: "sandbox",
      image: @sandbox_image,
      entrypoint: ["/opt/sandboxd/bin/sandboxd"],
      command: ["start"],
      volumes: [%{name: "cclog", target: "/var/log/cc"}]
    }

    provider_opts = [
      image: @sandbox_image,
      forwarder_image: @forwarder_image,
      services: [sandbox | services] ++ [vector],
      networks: networks,
      volumes: [%{name: "cclog"}, %{name: "proxylog"}],
      timeout: 30_000,
      ready_timeout: 120_000,
      health_timeout: 120_000
    ]

    env = Keyword.fetch!(overrides, :env)
    endpoint = Map.fetch!(env, "PW_WS_ENDPOINT")
    "ws://browser:3000/" <> token = endpoint

    {:ok, handle} =
      Sandboxd.provision(
        provider: {Compose, provider_opts},
        owner: context.owner,
        session_key: context.session
      )

    stack = handle.provider_handle
    sandbox_id = container(stack, "sandbox")
    browser_id = container(stack, "browser")
    vector_id = container(stack, "vector")

    {:ok, _} = Sandboxd.exec(handle, "/bin/sh", ["-c", P.fake_cli()], env)

    # (a) The sandbox has no egress: no route and no upstream DNS.
    assert node(sandbox_id, P.probe(), ["tcp", "1.1.1.1", 443]) == "BLOCKED"
    assert node(sandbox_id, P.probe(), ["dns", "example.com"]) == "NO-DNS"

    # (b) The sandbox cannot reach the proxy: not by name, and not at the
    # proxy's own address on brw, the network the sandbox is not on.
    proxy_ip = ip(container(stack, "egress-proxy"), "#{stack.project}-brw")
    assert node(sandbox_id, P.probe(), ["dns", "egress-proxy"]) == "NO-DNS"
    assert node(sandbox_id, P.probe(), ["tcp", proxy_ip, 4750]) == "BLOCKED"

    # The browser has no direct egress either: the proxy is its only way out.
    assert node(browser_id, P.probe(), ["tcp", "1.1.1.1", 443]) == "BLOCKED"

    # The agent's dev server, and the STUN listener for the WebRTC check.
    marker = "cc-dev-#{System.unique_integer([:positive])}"
    exec_detached(sandbox_id, ["node", "-e", P.dev_server(), "#{@app_port}", marker])
    exec_detached(sandbox_id, ["node", "-e", P.udp_listener(), "#{@stun_port}", @udp_log])

    eventually(fn ->
      exec(sandbox_id, ["sh", "-c", "test -e #{@udp_log}.ready && echo y"]) == "y\n"
    end)

    sandbox_ip = ip(sandbox_id, stack.sandbox_network)

    out =
      sandbox_id
      |> node(P.client(), [endpoint, "http://sandbox:#{@app_port}/", sandbox_ip, @stun_port])
      |> JSON.decode!()

    refute Map.has_key?(out, "fatal"), "client failed: #{out["fatal"]}"

    # The browser reaches the sandbox's dev server (bypassing the proxy).
    assert %{"status" => 200, "title" => "cc-dev", "body" => ^marker} = out["app"]

    # (c) A client at the pinned version loads an allowlisted page through the
    # proxy, and a page off the allowlist is a 407 that Chromium names
    # ERR_PROXY_AUTH_UNSUPPORTED.
    assert %{"status" => 200, "title" => "Example Domain"} = out["allowed"]
    assert out["denied"]["error"] =~ "net::ERR_PROXY_AUTH_UNSUPPORTED"

    # B8.3: WebRTC sends no UDP around the proxy. No candidate is UDP, and the
    # STUN listener saw nothing from Chromium. (Measured: the same page in a
    # Chromium launched without --force-webrtc-ip-handling-policy sends six
    # 20-byte STUN binding requests to this listener.)
    refute Enum.any?(out["candidates"], &(&1 =~ ~r/\budp\b/i)),
           "UDP ICE candidates: #{inspect(out["candidates"])}"

    assert read_file(sandbox_id, @udp_log) == ""

    # ...though a plain UDP datagram from the browser container does arrive,
    # so the silence above is Chromium's policy, not an unreachable listener.
    node(browser_id, P.udp_send(), [sandbox_ip, @stun_port])
    browser_ip = ip(browser_id, stack.sandbox_network)
    eventually(fn -> read_file(sandbox_id, @udp_log) == "#{browser_ip} 7\n" end)

    # (d) A client of another minor version is refused with 428; the matching
    # version upgrades.
    upgrade = &node(sandbox_id, P.ws_upgrade(), ["browser", 3000, "/" <> token, P.user_agent(&1)])
    assert upgrade.("1.63.0") == "428"
    assert upgrade.(P.playwright_version()) == "101"

    # (e) MCP answers `initialize` for its own Host and 403s any other.
    mcp = &(sandbox_id |> node(P.mcp_initialize(), ["browser", 8931, &1]) |> JSON.decode!())
    assert %{"status" => 200, "body" => body} = mcp.("browser:8931")
    assert body =~ ~s("serverInfo":{"name":"Playwright")
    assert %{"status" => 403} = mcp.("evil:8931")

    # The transcript: a secret, then a last line written the instant before
    # teardown. Vector must ship both, redacted, through the drain.
    secret = "sk-ant-api03-" <> String.duplicate("AbCd1234", 6)
    last = "cc-last-line-#{System.unique_integer([:positive])}"

    :ok =
      Sandboxd.write(handle, JSON.encode!(%{type: "assistant", text: "key " <> secret}) <> "\n")

    logs = Task.async(fn -> follow_logs(vector_id) end)
    Process.sleep(1_000)

    :ok = Sandboxd.write(handle, JSON.encode!(%{type: "result", result: last}) <> "\n")
    assert :ok = Sandboxd.destroy(handle)

    {output, vector_log} = Task.await(logs, 120_000)
    events = output |> String.split("\n", trim: true) |> Enum.flat_map(&decode_event/1)

    refute output =~ secret
    refute output =~ token
    assert output =~ sha256(secret), "nothing redacted was shipped; Vector said:\n#{vector_log}"
    assert output =~ sha256(token)

    transcript = Enum.filter(events, &(get_in(&1, ["cc", "stream"]) == "transcript"))
    assert Enum.any?(transcript, &(get_in(&1, ["event", "subtype"]) == "init"))

    assert List.last(transcript)["event"] == %{"type" => "result", "result" => last},
           "the last line did not survive teardown: #{inspect(List.last(transcript))}"

    # Proxy decisions are shipped, the denial included.
    decisions =
      for %{"type" => "proxy_decision", "event" => event} <- events,
          do: {event["requested_host"], event["allow"]}

    assert {"example.com:443", true} in decisions
    assert {"wikipedia.org:443", false} in decisions
  end

  # --- helpers ---

  defp container(stack, service) do
    {^service, id} = List.keyfind(stack.containers, service, 0)
    id
  end

  defp ip(id, network) do
    {:ok, json} = API.request(config(), :get, "/containers/#{id}/json")
    get_in(json, ["NetworkSettings", "Networks", network, "IPAddress"])
  end

  defp node(id, script, args) do
    id |> exec(["node", "-e", script | Enum.map(args, &to_string/1)]) |> String.trim()
  end

  defp read_file(id, path), do: exec(id, ["sh", "-c", "cat #{path} 2>/dev/null || true"])

  defp eventually(fun, deadline \\ 10_000) do
    cond do
      fun.() ->
        :ok

      deadline <= 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(200)
        eventually(fun, deadline - 200)
    end
  end

  # Same shape as compose_test.exs: create an exec, start it undetached,
  # demux the multiplexed stream (stdout only).
  defp exec(id, cmd) do
    {:ok, %{"Id" => exec_id}} =
      API.request(config(), :post, "/containers/#{id}/exec",
        json: %{"AttachStdout" => true, "AttachStderr" => true, "Tty" => false, "Cmd" => cmd}
      )

    {:ok, raw} =
      API.request(config(), :post, "/exec/#{exec_id}/start",
        json: %{"Detach" => false, "Tty" => false},
        decode_body: false,
        receive_timeout: 120_000
      )

    {payloads, _state} = Demux.feed(Demux.new(), raw)
    IO.iodata_to_binary(payloads)
  end

  defp exec_detached(id, cmd) do
    {:ok, %{"Id" => exec_id}} =
      API.request(config(), :post, "/containers/#{id}/exec", json: %{"Cmd" => cmd})

    {:ok, _} =
      API.request(config(), :post, "/exec/#{exec_id}/start",
        json: %{"Detach" => true, "Tty" => false},
        decode_body: false
      )
  end

  # Returns once the container stops, which is the point: everything Vector
  # printed, including what it flushed during the drain. Stdout is the console
  # sink; stderr, Vector's own log, only explains a failure.
  defp follow_logs(id) do
    {:ok, raw} =
      API.request(config(), :get, "/containers/#{id}/logs",
        params: [follow: true, stdout: true, stderr: true],
        decode_body: false,
        receive_timeout: 120_000
      )

    split_streams(raw, [], [])
  end

  defp split_streams(<<type, _::24, len::32-big, data::binary-size(len), rest::binary>>, out, err) do
    case type do
      1 -> split_streams(rest, [out, data], err)
      _ -> split_streams(rest, out, [err, data])
    end
  end

  defp split_streams(_rest, out, err), do: {IO.iodata_to_binary(out), IO.iodata_to_binary(err)}

  defp decode_event(line) do
    case JSON.decode(line) do
      {:ok, event} when is_map(event) -> [event]
      _ -> []
    end
  end

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp config, do: [timeout: 30_000]
end
