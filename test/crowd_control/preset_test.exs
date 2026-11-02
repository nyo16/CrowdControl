defmodule CrowdControl.PresetTest do
  # Pure: every preset is a function from options to a service map, and every
  # rendered file is checked by parsing it back.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.Services
  alias CrowdControl.CLI
  alias CrowdControl.Preset
  alias CrowdControl.Preset.Browser
  alias CrowdControl.Preset.EgressProxy
  alias CrowdControl.Preset.LogShipper

  doctest CrowdControl.Preset.EgressProxy
  doctest CrowdControl.Preset.Browser
  doctest CrowdControl.Preset.LogShipper

  @proxy [image: "smokescreen:1", allow_domains: ["example.com", "*.github.com"]]
  @browser [image: "browser:1", proxy: "http://egress-proxy:4750"]
  @k8s_sink {:vector, address: "http://vector-aggregator.logging.svc:6000"}
  @aggregator %{
    namespace_selector: %{"kubernetes.io/metadata.name" => "logging"},
    pod_selector: %{"app" => "vector-aggregator"},
    ip: "10.96.12.7"
  }

  describe "EgressProxy (blocker: a proxy that forwards anything, or never starts)" do
    test "config.yaml: no mTLS, so allow_missing_role, and the ACL by path" do
      spec = EgressProxy.spec(@proxy)

      assert yaml(file(spec, "/etc/smokescreen/config.yaml")) == %{
               "allow_missing_role" => true,
               "acl_file" => "/etc/smokescreen/acl.yaml"
             }
    end

    test "acl.yaml: one enforcing default rule with exactly the allowlist" do
      acl = yaml(file(EgressProxy.spec(@proxy), "/etc/smokescreen/acl.yaml"))

      assert acl == %{
               "version" => "v1",
               "services" => [],
               "default" => %{
                 "name" => "default",
                 "project" => "crowd_control",
                 "action" => "enforce",
                 "allowed_domains" => ["example.com", "*.github.com"]
               }
             }
    end

    test "the allowlist is required, non-empty and hostname-shaped" do
      for domains <- [nil, [], ["https://example.com"], ["example.com\nservices: x"], ["*"]] do
        assert_raise ArgumentError, fn ->
          EgressProxy.spec(Keyword.put(@proxy, :allow_domains, domains))
        end
      end
    end

    test "egress: :allow on brw only; stderr goes to the decision log through sh" do
      spec = EgressProxy.spec(Keyword.put(@proxy, :extra_deny_ranges, ["203.0.113.0/24"]))

      assert spec.egress == :allow
      assert spec.networks == ["brw"]
      assert spec.ports == [4750]
      assert spec.user == "65532:65532"

      assert ["/bin/sh", "-c", script] = spec.entrypoint
      assert script =~ ~r/^exec smokescreen '--config-file' '\/etc\/smokescreen\/config.yaml'/
      assert script =~ "'--listen-ip' '0.0.0.0' '--listen-port' '4750'"
      assert script =~ "'--deny-range' '203.0.113.0/24'"
      assert String.ends_with?(script, " 2>>/var/log/proxy/decisions.jsonl")

      # The log directory is writable under a read-only rootfs.
      assert spec.host_config.tmpfs["/var/log/proxy"] =~ "size=16m"
    end

    test ":stderr leaves the image's entrypoint and passes flags as the command" do
      spec = EgressProxy.spec(Keyword.put(@proxy, :decision_log, :stderr))

      refute Map.has_key?(spec, :entrypoint)
      assert ["--config-file", "/etc/smokescreen/config.yaml" | _] = spec.command
    end

    test "readiness: TCP for Kubernetes always, nc for Compose only when asked" do
      assert EgressProxy.spec(@proxy).ready == %{tcp_port: 4750}

      assert EgressProxy.spec(Keyword.put(@proxy, :nc, true)).ready == %{
               tcp_port: 4750,
               test: ["CMD", "nc", "-z", "127.0.0.1", "4750"]
             }
    end

    test "a decision-log volume is Compose-only" do
      spec = EgressProxy.spec(Keyword.put(@proxy, :log_volume, "ccproxylog"))
      assert spec.volumes == [%{name: "ccproxylog", target: "/var/log/proxy"}]

      assert_raise ArgumentError, ~r/Compose-only/, fn ->
        EgressProxy.spec(@proxy ++ [log_volume: "ccproxylog", placement: :separate])
      end
    end

    test "bad deny ranges and a missing image are refused" do
      assert_raise ArgumentError, fn -> EgressProxy.spec(@proxy ++ [extra_deny_ranges: ["x"]]) end

      assert_raise ArgumentError, ~r/:image/, fn ->
        EgressProxy.spec(Keyword.delete(@proxy, :image))
      end
    end
  end

  describe "Browser (blocker: a browser that bypasses the proxy)" do
    test "env: a ccpw_ token, the proxy, the MCP host — and no bypass, so never localhost" do
      spec = Browser.spec(@browser)

      assert "ccpw_" <> _ = spec.env["PW_WS_TOKEN"]
      assert spec.env["PW_PROXY_SERVER"] == "http://egress-proxy:4750"
      assert spec.env["MCP_ALLOWED_HOSTS"] == "browser:8931"

      # Unset is what makes Playwright add `<-loopback>`, sending loopback
      # through the proxy (which denies it).
      refute Map.has_key?(spec.env, "PW_PROXY_BYPASS")
      refute inspect(spec.env) =~ "localhost"
    end

    test "a loopback bypass is refused in every spelling" do
      for host <- [
            "localhost",
            "LOCALHOST",
            "127.0.0.1",
            "::1",
            "[::1]",
            "<-loopback>",
            "x.localhost"
          ] do
        assert_raise ArgumentError, ~r/loopback/, fn ->
          Browser.spec(@browser ++ [proxy_bypass: [host]])
        end
      end

      spec = Browser.spec(@browser ++ [proxy_bypass: ["sandbox"]])
      assert spec.env["PW_PROXY_BYPASS"] == "sandbox"
    end

    test "egress: :none, on sbx and brw, ports and readiness on both" do
      spec = Browser.spec(@browser)

      assert spec.egress == :none
      assert spec.networks == ["sbx", "brw"]
      assert spec.ports == [3000, 8931]
      assert spec.ready.tcp_port == 8931
      assert ["CMD", "node", "-e", check] = spec.ready.test
      assert check =~ "[3000,8931]"
      assert spec.user == "10001:10001"

      assert spec.host_config == %{
               shm_size: 1_073_741_824,
               init: true,
               tmpfs: %{"/tmp" => "rw,nosuid,size=512m"}
             }
    end

    test "the proxy is required; false is a browser with no route out at all" do
      assert_raise ArgumentError, ~r/:proxy is required/, fn ->
        Browser.spec(image: "browser:1")
      end

      spec = Browser.spec(image: "browser:1", proxy: false)
      assert spec.networks == ["sbx"]
      refute Map.has_key?(spec.env, "PW_PROXY_SERVER")
    end

    test "every spec mints its own token" do
      refute Browser.spec(@browser).env["PW_WS_TOKEN"] ==
               Browser.spec(@browser).env["PW_WS_TOKEN"]

      assert_raise ArgumentError, fn -> Browser.spec(@browser ++ [token: "short"]) end
    end

    test "the sandbox wiring is valid CLI input: endpoint env, typed inline MCP, prompt line" do
      spec = Browser.spec(@browser)
      token = spec.env["PW_WS_TOKEN"]
      overrides = Browser.sandbox_overrides(spec)

      assert overrides[:env] == %{
               "PW_WS_ENDPOINT" => "ws://browser:3000/#{token}",
               "PW_TEST_CONNECT_WS_ENDPOINT" => "ws://browser:3000/#{token}"
             }

      assert overrides[:mcp_config] == %{
               "mcpServers" => %{
                 "playwright" => %{"type" => "http", "url" => "http://browser:8931/mcp"}
               }
             }

      {_executable, args, env} = CLI.build_command(overrides)

      assert env["PW_WS_ENDPOINT"] == "ws://browser:3000/#{token}"
      assert "--strict-mcp-config" in args

      mcp = args |> Enum.drop_while(&(&1 != "--mcp-config")) |> Enum.at(1)
      assert JSON.decode!(mcp) == overrides[:mcp_config]

      prompt = args |> Enum.drop_while(&(&1 != "--append-system-prompt")) |> Enum.at(1)
      assert prompt =~ "playwright-cli"
      assert prompt =~ "http://sandbox:<port>"
      refute prompt =~ token
    end
  end

  describe "LogShipper config (blocker: a shipper that leaks or drops the transcript)" do
    test "the default filters include ccst_ and ccpw_, rendered as static VRL raw strings" do
      source = transcript_vrl(LogShipper.config(sink: :console, capture_volume: "cclog"))

      for pattern <- LogShipper.default_filters() do
        assert source =~ "r'#{pattern}'"
      end

      assert source =~ ~S"r'ccst_[A-Za-z0-9_\-]{16,}'"
      assert source =~ ~S"r'ccpw_[A-Za-z0-9_\-]{16,}'"
      assert source =~ ~S"r'sk-ant-[a-z]+[0-9]{2}-[A-Za-z0-9_\-]{20,}'"
      assert source =~ ~s(redactor: {"type": "sha2", "variant": "SHA-256", "encoding": "base16"})

      # Redaction runs on the raw line, before parsing.
      assert index(source, "redact(") < index(source, "parse_json(")
      refute source =~ "${"
    end

    test "the file source matches the session's line cap and never rotates anything" do
      config = yaml(LogShipper.config(sink: :console, capture_volume: "cclog"))
      transcript = config["sources"]["transcript"]

      assert transcript["include"] == ["/var/log/cc/out.jsonl"]
      assert transcript["read_from"] == "beginning"
      assert transcript["max_line_bytes"] == 1_048_576
      assert transcript["offset_key"] == "offset"
      refute Map.has_key?(transcript, "remove_after_secs")

      bigger =
        yaml(LogShipper.config(sink: :console, capture_volume: "c", max_line_bytes: 4_194_304))

      assert bigger["sources"]["transcript"]["max_line_bytes"] == 4_194_304
    end

    test "fail closed, acknowledgements on, checkpoints on a Vector-only dir" do
      config = yaml(LogShipper.config(sink: :console, capture_volume: "cclog"))
      remap = config["transforms"]["transcript_redacted"]

      assert remap["drop_on_error"] == true
      assert remap["drop_on_abort"] == true
      assert config["acknowledgements"] == %{"enabled" => true}
      assert config["data_dir"] == "/var/lib/vector"
      assert config["sinks"]["out"]["inputs"] == ["transcript_redacted"]
    end

    test "the API: loopback on Compose, off on Kubernetes (the Pod's loopback is the sandbox's)" do
      compose = yaml(LogShipper.config(sink: :console, capture_volume: "cclog"))
      assert compose["api"] == %{"enabled" => true, "address" => "127.0.0.1:8686"}

      k8s = yaml(LogShipper.config(placement: :pod, sink: @k8s_sink, aggregator: @aggregator))
      assert k8s["api"] == %{"enabled" => false}

      # Regression: a bare `host:port` never connects in Vector 0.61 (found by
      # kubernetes_browser_test.exs); the scheme is required.
      assert k8s["sinks"]["out"] == %{
               "type" => "vector",
               "inputs" => ["transcript_redacted"],
               "address" => "http://vector-aggregator.logging.svc:6000"
             }

      ipv6 = [
        placement: :pod,
        sink: {:vector, address: "[fd00::7]:6000"},
        aggregator: @aggregator
      ]

      assert yaml(LogShipper.config(ipv6))["sinks"]["out"]["address"] == "http://[fd00::7]:6000"
    end

    test "proxy decisions become a second, redacted source" do
      config =
        yaml(LogShipper.config(sink: :console, capture_volume: "cc", proxy_log_volume: "ccproxy"))

      assert config["sources"]["proxy_decisions"]["include"] == ["/var/log/proxy/decisions.jsonl"]
      assert config["transforms"]["proxy_redacted"]["source"] =~ "CANONICAL-PROXY-DECISION"
      assert config["sinks"]["out"]["inputs"] == ["transcript_redacted", "proxy_redacted"]
    end

    test "labels are literal, and only safe ones are accepted" do
      source =
        transcript_vrl(
          LogShipper.config(sink: :console, capture_volume: "c", labels: %{"team" => "platform"})
        )

      assert source =~ ~s("labels": {"team":"platform"})

      assert_raise ArgumentError, fn ->
        LogShipper.config(sink: :console, capture_volume: "c", labels: %{"team" => ~s(a"b)})
      end
    end
  end

  describe "LogShipper refusals (blocker: posture inferred)" do
    test "on Kubernetes any sink but the aggregator is refused" do
      for sink <- [
            :console,
            {:http, uri: "https://logs.example.com"},
            {:loki, endpoint: "http://loki:3100"}
          ] do
        assert_raise ArgumentError, ~r/only \{:vector, address: aggregator\}/, fn ->
          LogShipper.spec(placement: :pod, sink: sink, aggregator: @aggregator)
        end
      end
    end

    test "an https aggregator address is refused, not downgraded to plain text" do
      assert_raise ArgumentError, ~r/bad vector sink address/, fn ->
        LogShipper.spec(
          placement: :pod,
          sink: {:vector, address: "https://10.96.12.7:6000"},
          aggregator: @aggregator
        )
      end
    end

    test "on Kubernetes the aggregator must be named, and reachable without DNS" do
      assert_raise ArgumentError, ~r/:aggregator/, fn ->
        LogShipper.spec(placement: :pod, sink: @k8s_sink)
      end

      assert_raise ArgumentError, ~r/no DNS/, fn ->
        LogShipper.services(
          placement: :pod,
          sink: @k8s_sink,
          aggregator: Map.delete(@aggregator, :ip)
        )
      end

      assert [_vector, _aggregator] =
               LogShipper.services(
                 placement: :pod,
                 sink: {:vector, address: "10.96.12.7:6000"},
                 aggregator: Map.delete(@aggregator, :ip)
               )
    end

    test "redact: false must be typed out twice" do
      assert_raise ArgumentError, ~r/ship_unredacted: true/, fn ->
        LogShipper.spec(sink: :console, capture_volume: "c", redact: false)
      end

      config =
        LogShipper.config(
          sink: :console,
          capture_volume: "c",
          redact: false,
          ship_unredacted: true
        )

      refute config =~ "redact("
    end

    test "a custom regex cannot break out of its VRL literal; unknown filters are refused" do
      assert_raise ArgumentError, fn ->
        LogShipper.spec(sink: :console, capture_volume: "c", redact: [{:regex, "a'b"}])
      end

      assert_raise ArgumentError, fn ->
        LogShipper.spec(sink: :console, capture_volume: "c", redact: [:nope])
      end

      config =
        LogShipper.config(
          sink: :console,
          capture_volume: "c",
          redact: [:anthropic, {:regex, "tok_[0-9]+"}]
        )

      assert config =~ "r'tok_[0-9]+'"
      refute config =~ "ccst_"
    end

    test "Compose needs the capture volume; a separate Pod cannot read the capture" do
      assert_raise ArgumentError, ~r/:capture_volume/, fn -> LogShipper.spec(sink: :console) end

      assert_raise ArgumentError, ~r/only :pod/, fn ->
        LogShipper.spec(placement: :separate, sink: @k8s_sink, aggregator: @aggregator)
      end
    end

    test "a Compose shipper with egress may not sit on sbx" do
      assert_raise ArgumentError, ~r/sbx/, fn ->
        LogShipper.spec(
          sink: {:http, uri: "https://x.example"},
          capture_volume: "c",
          network: "sbx"
        )
      end
    end
  end

  describe "LogShipper spec (blocker: SIGKILL mid-flush, root, a writable capture)" do
    test "Compose: read-only capture, non-root, drained, after the sandbox" do
      spec = LogShipper.spec(sink: :console, capture_volume: "cclog")

      assert spec.image == "timberio/vector:0.61.0-distroless-libc"
      assert spec.user == "65532:65532"
      assert spec.egress == :none
      refute Map.has_key?(spec, :networks)
      assert spec.depends_on == ["sandbox"]
      assert spec.volumes == [%{name: "cclog", target: "/var/log/cc", read_only: true}]
      assert spec.host_config.tmpfs["/var/lib/vector"] =~ "size=8m"
      assert {spec.drain, spec.shutdown_limit} == {3_000, 20}
      assert spec.env == %{"VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS" => "20"}
      assert spec.command == ["--config", "/etc/vector/vector.yaml"]
      assert [%{path: "/etc/vector/vector.yaml", mode: 0o444}] = spec.files
    end

    # Regression: Docker copies the image's root-owned 0755 `/var/lib/vector`
    # up into the tmpfs, so Vector running as 65532 could not create its
    # checkpoints and exited at start (found by compose_browser_test.exs).
    test "Compose: the data dir tmpfs belongs to the user Vector runs as" do
      tmpfs = fn opts ->
        spec = LogShipper.spec([sink: :console, capture_volume: "c"] ++ opts)
        spec.host_config.tmpfs["/var/lib/vector"]
      end

      assert tmpfs.([]) == "rw,noexec,nosuid,size=8m,uid=65532,gid=65532,mode=0700"
      assert tmpfs.(user: "1000") == "rw,noexec,nosuid,size=8m,uid=1000,mode=0700"
      assert tmpfs.(user: "vector") == "rw,noexec,nosuid,size=8m,mode=1777"
    end

    test "Compose with a network sink: egress on its own network" do
      spec = LogShipper.spec(sink: {:http, uri: "https://logs.example.com"}, capture_volume: "c")

      assert spec.egress == :allow
      assert spec.networks == ["log"]
    end

    test "Kubernetes: a :pod sidecar plus an external aggregator the backend accepts" do
      services = LogShipper.services(placement: :pod, sink: @k8s_sink, aggregator: @aggregator)
      [vector, aggregator] = services

      assert vector.placement == :pod
      assert vector.egress == :none

      assert aggregator.placement ==
               {:external, Map.put(@aggregator, :host, "vector-aggregator.logging.svc")}

      assert aggregator.ports == [6000]

      # The backend's own validation, and the edge it produces.
      handle = %Kubernetes{
        pod_name: "cc-k",
        namespace: "ns",
        tee_path: "/var/log/cc/out.jsonl",
        session_key: "k",
        owner: "o"
      }

      ctx = Kubernetes.service_context(handle)
      assert {:ok, normalized} = Services.normalize([services: services], ctx)
      assert [_ | _] = Services.sandbox_rules(ctx, normalized, [])["egress"]

      assert Services.host_aliases(:sandbox, normalized, %{}) == [
               %{
                 "ip" => "10.96.12.7",
                 "hostnames" => ["aggregator", "vector-aggregator.logging.svc"]
               }
             ]
    end
  end

  describe "browser_stack/1 (blocker: two presets wired inconsistently)" do
    test "Compose: proxy and browser share brw, the browser points at the proxy" do
      {[proxy, browser], networks, overrides} =
        Preset.browser_stack(substrate: :compose, proxy: @proxy, browser: [image: "browser:1"])

      assert networks == [%{name: "brw"}]
      assert proxy.networks == ["brw"]
      assert browser.networks == ["sbx", "brw"]
      assert browser.env["PW_PROXY_SERVER"] == EgressProxy.url(proxy)
      refute Map.has_key?(proxy, :placement)
      refute Map.has_key?(browser, :placement)
      assert overrides[:env]["PW_WS_ENDPOINT"] == Browser.ws_endpoint(browser)
      refute Keyword.has_key?(overrides, :sandbox_ports)
    end

    test "Kubernetes: :separate, no network declarations, the backend accepts it" do
      {services, networks, overrides} =
        Preset.browser_stack(
          substrate: :kubernetes,
          proxy: @proxy,
          browser: [image: "browser:1"],
          app_ports: [5173]
        )

      assert networks == []
      assert Enum.all?(services, &(&1.placement == :separate))
      assert overrides[:sandbox_ports] == [5173]

      browser = Enum.find(services, &(&1.name == "browser"))
      assert browser.env["PW_PROXY_BYPASS"] == "sandbox"

      handle = %Kubernetes{
        pod_name: "cc-k",
        namespace: "ns",
        tee_path: "/var/log/cc/out.jsonl",
        session_key: "k",
        owner: "o"
      }

      assert {:ok, _} =
               Services.normalize([services: services], Kubernetes.service_context(handle))
    end

    test "the substrate is required" do
      assert_raise ArgumentError, ~r/:substrate/, fn ->
        Preset.browser_stack(proxy: @proxy, browser: [image: "browser:1"])
      end
    end
  end

  # --- helpers ---

  defp file(spec, path), do: Enum.find_value(spec.files, &(&1.path == path && &1.content))

  defp yaml(text), do: YamlElixir.read_from_string!(text)

  defp transcript_vrl(config), do: yaml(config)["transforms"]["transcript_redacted"]["source"]

  defp index(string, part) do
    {index, _length} = :binary.match(string, part)
    index
  end
end
