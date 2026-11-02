defmodule CrowdControl.Backend.KubernetesBrowserTest do
  # The strict two-tier browser layout on a live cluster, from the presets.
  # Excluded by default (see test_helper.exs); run with
  #
  #     mix test --only k8s test/crowd_control/backend/kubernetes_browser_test.exs
  #
  # The cluster is named, never inherited: `CC_K8S_CONTEXT` (default
  # `orbstack`) from `~/.kube/config`; see CrowdControl.Test.K8sLive. Needs
  # Kubernetes >= 1.30 (native sidecars, preStop sleep), nodes that can run
  # the images Compose uses (see compose_browser_test.exs for the builds; a
  # local cluster sharing the Docker image store, as OrbStack does, needs no
  # registry), `@vector_image` (pinned by digest), `busybox:1.36`, and
  # internet egress from the proxy Pod.
  #
  # Two kinds of check, split by what they need from the cluster:
  #
  #   * The deny checks — the sandbox has no egress and cannot reach the
  #     proxy, the browser's only way out is the proxy — mean nothing on a
  #     cluster whose CNI ignores NetworkPolicy, so they are skipped unless
  #     the backend's enforcement probe passes, with its verdict as the
  #     reason. OrbStack fails the probe: measured, it does enforce policies
  #     pod-to-pod and to the internet, but not on the path to the API
  #     server the probe tests, so the probe (rightly) refuses to vouch.
  #   * Everything else runs everywhere: DNS-free discovery through
  #     `hostAliases` and ClusterIPs, the dev server through `:sandbox_ports`,
  #     the proxy allowlist, MCP and run-server, WebRTC, Vector shipping
  #     through the drain to an in-cluster aggregator, `list_live/1` ignoring
  #     service Pods, and the orphan sweep. Where the probe fails those run
  #     with `network_probe: false`; where it passes the probe runs too. On a
  #     cluster that enforces (OrbStack included) they also prove the
  #     policies admit every path the layout needs.
  use ExUnit.Case, async: false

  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Backend.Kubernetes.Services
  alias CrowdControl.Preset
  alias CrowdControl.Preset.LogShipper
  alias CrowdControl.Store
  alias CrowdControl.Test.BrowserProbes, as: P
  alias CrowdControl.Test.K8sLive

  @moduletag :k8s
  @moduletag timeout: 900_000

  @sandbox_image "crowd_control/sandbox-browser:dev"
  @browser_image "crowd_control/browser:dev"
  @proxy_image "crowd_control/smokescreen:dev"
  @vector_image "timberio/vector:0.61.0-distroless-libc@" <>
                  "sha256:1a3451978644d5cd4b99a0b28c990791e2f7e1efbea4184122f1c59a56448143"

  @app_port 5173
  @stun_port 3478
  @udp_log "/tmp/udp.log"
  @aggregator_port 6000

  # Evaluated while this module compiles, and only when `:k8s` is included:
  # ExUnit has no runtime skip.
  @policy_skip K8sLive.policy_skip_reason()

  setup_all do
    {:ok, kubeconfig: K8sLive.kubeconfig(), enforced?: @policy_skip == nil}
  end

  setup context do
    owner = "cc-kbrw-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

    config = [
      kubeconfig: context.kubeconfig,
      owner: owner,
      timeout: 60_000,
      exec_timeout: 120_000
    ]

    on_exit(fn -> destroy_all(config) end)
    {:ok, owner: owner, config: config}
  end

  describe "the browser stack (runs on any cluster)" do
    test "discovery, proxy, MCP, WebRTC, list_live and Vector through the drain", ctx do
      aggregator = start_aggregator(ctx.config)
      on_exit(fn -> stop_aggregator(ctx.config, aggregator) end)

      shipper =
        LogShipper.services(
          placement: :pod,
          sink: {:vector, address: "#{aggregator.ip}:#{@aggregator_port}"},
          aggregator: %{pod_selector: %{"app" => aggregator.name}}
        )

      {services, [], overrides} = browser_stack()
      env = Keyword.fetch!(overrides, :env)
      endpoint = Map.fetch!(env, "PW_WS_ENDPOINT")
      "ws://browser:3000/" <> token = endpoint

      {:ok, handle} = provision(ctx, services ++ shipper, overrides)
      config = handle.config
      sandbox = handle.pod_name
      browser = Services.object_name(handle.session_key, "browser")
      proxy = Services.object_name(handle.session_key, "egress-proxy")

      # list_live/1 reports the sandbox and never a service Pod, though all
      # three carry the same owner and session labels.
      owned = owner_pods(config)
      assert Enum.sort([sandbox, browser, proxy]) == Enum.sort(Map.keys(owned))
      assert {:ok, [live]} = Kubernetes.list_live(config)
      assert live.pod_name == sandbox
      assert live.session_key == handle.session_key

      {:ok, handle} = Kubernetes.exec(handle, "/bin/sh", ["-c", P.fake_cli()], env)

      marker = "cc-dev-#{System.unique_integer([:positive])}"
      detach(config, sandbox, "cc", ["node", "-e", P.dev_server(), @app_port, marker])
      detach(config, sandbox, "cc", ["node", "-e", P.udp_listener(), @stun_port, @udp_log])

      eventually(fn ->
        sh(config, sandbox, "cc", "test -e #{@udp_log}.ready && echo y") == "y\n"
      end)

      sandbox_ip = pod_ip(config, sandbox)

      # provision/1 returns once every Pod is Ready, but a ClusterIP only
      # forwards once kube-proxy has programmed the EndpointSlice, which can
      # trail readiness by seconds (measured on OrbStack: ECONNREFUSED on the
      # browser's ClusterIP right after provision, fine a moment later). The
      # sandbox Service's endpoints only appear once the sandbox Pod is Ready.
      tcp = &node(config, &1, &2, P.probe(), ["tcp" | &3])
      eventually(fn -> tcp.(sandbox, "cc", ["browser", 3000]) == "REACHABLE" end, 30_000)

      eventually(
        fn -> tcp.(browser, "browser", ["sandbox", @app_port]) == "REACHABLE" end,
        30_000
      )

      out =
        config
        |> node(sandbox, "cc", P.client(), [
          endpoint,
          "http://sandbox:#{@app_port}/",
          sandbox_ip,
          @stun_port
        ])
        |> JSON.decode!()

      refute Map.has_key?(out, "fatal"), "client failed: #{out["fatal"]}"

      # The browser reaches the sandbox's dev server as `sandbox:<port>`: a
      # hostAliases entry for the :sandbox_ports Service, no DNS.
      assert %{"status" => 200, "title" => "cc-dev", "body" => ^marker} = out["app"]

      # (c) through the proxy, found by hostAliases as well.
      assert %{"status" => 200, "title" => "Example Domain"} = out["allowed"]
      assert out["denied"]["error"] =~ "net::ERR_PROXY_AUTH_UNSUPPORTED"

      # B8.3: Chromium sent no UDP to the STUN listener. The control datagram
      # is the sandbox's own, to its Pod IP, so the listener provably answers
      # on the address the page was given. (Measured on OrbStack: a datagram
      # from the browser Pod never arrives, because the sandbox's policy
      # admits only TCP to its app ports — the policies are enforced
      # pod-to-pod there even though the enforcement probe fails.)
      refute Enum.any?(out["candidates"], &(&1 =~ ~r/\budp\b/i)),
             "UDP ICE candidates: #{inspect(out["candidates"])}"

      assert cat(config, sandbox, "cc", @udp_log) == ""
      node(config, sandbox, "cc", P.udp_send(), [sandbox_ip, @stun_port])
      eventually(fn -> cat(config, sandbox, "cc", @udp_log) == "#{sandbox_ip} 7\n" end)

      # (d) and (e), sandbox to browser by hostAliases.
      upgrade =
        &node(config, sandbox, "cc", P.ws_upgrade(), [
          "browser",
          3000,
          "/" <> token,
          P.user_agent(&1)
        ])

      assert upgrade.("1.63.0") == "428"
      assert upgrade.(P.playwright_version()) == "101"

      mcp =
        &(config
          |> node(sandbox, "cc", P.mcp_initialize(), ["browser", 8931, &1])
          |> JSON.decode!())

      assert %{"status" => 200, "body" => body} = mcp.("browser:8931")
      assert body =~ ~s("serverInfo":{"name":"Playwright")
      assert %{"status" => 403} = mcp.("evil:8931")

      # Proxy decisions are recorded in the proxy Pod. (LogShipper ships them
      # on Compose only: a :pod shipper cannot read another Pod's files.)
      decisions =
        config
        |> cat(proxy, "egress-proxy", "/var/log/proxy/decisions.jsonl")
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_json/1)
        |> Enum.filter(&(&1["msg"] == "CANONICAL-PROXY-DECISION"))
        |> Enum.map(&{&1["requested_host"], &1["allow"]})

      assert {"example.com:443", true} in decisions
      assert {"wikipedia.org:443", false} in decisions

      # The transcript, through the :pod Vector sidecar to the aggregator: a
      # secret, then a last line written the instant before teardown.
      secret = "sk-ant-api03-" <> String.duplicate("AbCd1234", 6)
      last = "cc-last-line-#{System.unique_integer([:positive])}"

      :ok =
        Kubernetes.write(
          handle,
          JSON.encode!(%{type: "assistant", text: "key " <> secret}) <> "\n"
        )

      :ok = Kubernetes.write(handle, JSON.encode!(%{type: "result", result: last}) <> "\n")
      assert :ok = Kubernetes.destroy(handle)

      shipped = fn -> aggregator_log(config, aggregator) end

      eventually(fn -> shipped.() =~ last end, 90_000)
      assert eventually(fn -> not Map.has_key?(owner_pods(config), sandbox) end, 120_000)
      output = shipped.()

      refute output =~ secret
      refute output =~ token
      assert output =~ sha256(secret)
      assert output =~ sha256(token)

      transcript =
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_json/1)
        |> Enum.filter(&(get_in(&1, ["cc", "stream"]) == "transcript"))

      assert Enum.any?(transcript, &(get_in(&1, ["event", "subtype"]) == "init"))
      assert List.last(transcript)["event"] == %{"type" => "result", "result" => last}
      assert Enum.all?(transcript, &(get_in(&1, ["cc", "host"]) == sandbox))
    end

    test "a crash between the service objects and the sandbox Pod is swept", ctx do
      {services, [], overrides} = browser_stack()
      parent = self()

      # Provision in a process killed as soon as the browser Pod exists: the
      # service Pods are still becoming Ready, so the sandbox Pod — and the
      # annotation destroy/1 derives every name from — never gets created.
      pid = spawn(fn -> send(parent, {:provisioned, provision(ctx, services, overrides)}) end)

      eventually(
        fn -> Enum.any?(owner_pods(ctx.config), fn {_, role} -> role == "service" end) end,
        60_000
      )

      Process.exit(pid, :kill)
      refute_received {:provisioned, _}

      objects = owner_objects(ctx.config)
      assert objects.pods != [] and objects.services != [] and objects.policies != []

      refute Enum.any?(Map.values(owner_pods(ctx.config)), &(&1 != "service")),
             "the sandbox Pod was created; the crash came too late"

      # No sandbox, so nothing to report: service Pods are never live.
      assert {:ok, []} = Kubernetes.list_live(ctx.config)

      # Young objects are an in-flight provision and are left alone. The
      # floor is `:provision_timeout` + 60 s, so a 1 s timeout makes it 61 s.
      sweep = Keyword.put(ctx.config, :provision_timeout, 1_000)
      assert {:ok, 0} = Kubernetes.sweep_orphans(sweep)
      assert owner_objects(ctx.config) == objects

      Process.sleep(62_000)

      assert {:ok, swept} = Kubernetes.sweep_orphans(sweep)
      total = objects |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      assert swept == total

      assert eventually(
               fn ->
                 owner_objects(ctx.config) == %{
                   pods: [],
                   services: [],
                   policies: [],
                   config_maps: []
                 }
               end,
               60_000
             )
    end
  end

  describe "the deny checks (need a NetworkPolicy-enforcing CNI)" do
    @tag skip: @policy_skip
    test "sandbox has no egress and no proxy; the browser leaves only by the proxy", ctx do
      {services, [], overrides} = browser_stack()
      {:ok, handle} = provision(ctx, services, overrides)
      config = handle.config
      sandbox = handle.pod_name
      browser = Services.object_name(handle.session_key, "browser")
      proxy = Services.object_name(handle.session_key, "egress-proxy")
      probe = &node(config, &1, &2, P.probe(), &3)

      # (a) No route out, and no DNS: kube-dns is not in the sandbox's policy.
      assert probe.(sandbox, "cc", ["tcp", "1.1.1.1", 443]) == "BLOCKED"
      assert probe.(sandbox, "cc", ["dns", "example.com"]) == "NO-DNS"

      # (b) Not the proxy's Service, and not its Pod.
      {:ok, service} = API.get_service(config, proxy)
      proxy_ip = get_in(service, ["spec", "clusterIP"])
      assert probe.(sandbox, "cc", ["tcp", proxy_ip, 4750]) == "BLOCKED"
      assert probe.(sandbox, "cc", ["tcp", pod_ip(config, proxy), 4750]) == "BLOCKED"

      # The browser: no direct egress, no DNS, but the proxy answers it.
      assert probe.(browser, "browser", ["tcp", "1.1.1.1", 443]) == "BLOCKED"
      assert probe.(browser, "browser", ["dns", "example.com"]) == "NO-DNS"
      assert probe.(browser, "browser", ["tcp", "egress-proxy", 4750]) == "REACHABLE"

      Kubernetes.destroy(handle)
    end
  end

  # --- the stack ---

  defp browser_stack do
    Preset.browser_stack(
      substrate: :kubernetes,
      proxy: [image: @proxy_image, allow_domains: ["example.com"]],
      browser: [image: @browser_image],
      app_ports: [@app_port]
    )
  end

  defp provision(ctx, services, overrides) do
    Kubernetes.provision(
      ctx.config ++
        [
          image: @sandbox_image,
          session_key: Store.new_key(),
          network: :deny_all,
          network_probe: ctx.enforced?,
          services: services,
          sandbox_ports: Keyword.fetch!(overrides, :sandbox_ports),
          provision_timeout: 300_000
        ]
    )
  end

  # --- the aggregator: a plain Vector Pod printing what it receives ---

  defp start_aggregator(config) do
    name = "cc-agg-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    labels = %{"app" => name}
    metadata = %{"name" => name, "namespace" => API.namespace(config), "labels" => labels}

    yaml = """
    data_dir: /var/lib/vector
    sources:
      in:
        type: vector
        address: 0.0.0.0:#{@aggregator_port}
    sinks:
      out:
        type: console
        inputs: [in]
        encoding:
          codec: json
    """

    {:ok, _} =
      API.create_config_map(config, %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => metadata,
        "data" => %{"vector.yaml" => yaml}
      })

    {:ok, _} =
      API.create_pod(config, %{
        "apiVersion" => "v1",
        "kind" => "Pod",
        "metadata" => metadata,
        "spec" => %{
          "automountServiceAccountToken" => false,
          "containers" => [
            %{
              "name" => "vector",
              "image" => @vector_image,
              "args" => ["--config", "/etc/vector/vector.yaml"],
              "ports" => [%{"containerPort" => @aggregator_port}],
              "readinessProbe" => %{
                "tcpSocket" => %{"port" => @aggregator_port},
                "periodSeconds" => 1
              },
              "volumeMounts" => [%{"name" => "config", "mountPath" => "/etc/vector"}]
            }
          ],
          "volumes" => [%{"name" => "config", "configMap" => %{"name" => name}}]
        }
      })

    {:ok, service} =
      API.create_service(config, %{
        "apiVersion" => "v1",
        "kind" => "Service",
        "metadata" => metadata,
        "spec" => %{
          "selector" => labels,
          "ports" => [%{"port" => @aggregator_port, "targetPort" => @aggregator_port}]
        }
      })

    eventually(fn -> ready?(config, name) end, 120_000)
    %{name: name, ip: get_in(service, ["spec", "clusterIP"])}
  end

  defp stop_aggregator(config, %{name: name}) do
    API.delete_pod(config, name)
    API.delete_service(config, name)
    API.delete_config_map(config, name)
  end

  defp aggregator_log(config, %{name: name}) do
    case API.logs(config, name, tail_lines: 100_000, limit_bytes: 16 * 1024 * 1024) do
      {:ok, log} -> log
      {:error, _} -> ""
    end
  end

  defp ready?(config, name) do
    case API.get_pod(config, name) do
      {:ok, pod} ->
        pod
        |> get_in(["status", "conditions"])
        |> List.wrap()
        |> Enum.any?(&(&1["type"] == "Ready" and &1["status"] == "True"))

      _ ->
        false
    end
  end

  # --- cluster helpers ---

  defp owner_selector(config),
    do: [{"crowd_control.owner_hash", Kubernetes.owner_label(config[:owner])}]

  # name => crowd_control.role, for every Pod of this owner, any phase.
  defp owner_pods(config) do
    {:ok, pods} = API.list_all(config, nil, label_selectors: owner_selector(config))

    Map.new(pods, &{name(&1), get_in(&1, ["metadata", "labels", "crowd_control.role"])})
  end

  defp owner_objects(config) do
    selector = owner_selector(config)
    {:ok, pods} = API.list_all(config, nil, label_selectors: selector)
    {:ok, services} = API.list_services(config, selector)
    {:ok, policies} = API.list_network_policies(config, selector)
    {:ok, config_maps} = API.list_config_maps(config, selector)

    %{
      pods: pods |> Enum.reject(&deleting?/1) |> names(),
      services: names(services),
      policies: names(policies),
      config_maps: names(config_maps)
    }
  end

  defp deleting?(object), do: get_in(object, ["metadata", "deletionTimestamp"]) != nil

  defp names(objects), do: objects |> Enum.map(&name/1) |> Enum.sort()

  defp name(object), do: get_in(object, ["metadata", "name"])

  # Everything this owner left, by label and in any phase: list_live/1 sees
  # Running sandboxes only.
  defp destroy_all(config) do
    with {:ok, live} <- Kubernetes.list_live(config), do: Enum.each(live, &Kubernetes.destroy/1)

    objects = owner_objects(config)
    Enum.each(objects.pods, &API.delete_pod(config, &1))
    Enum.each(objects.services, &API.delete_service(config, &1))
    Enum.each(objects.policies, &API.delete_network_policy(config, &1))
    Enum.each(objects.config_maps, &API.delete_config_map(config, &1))
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp pod_ip(config, pod) do
    {:ok, json} = API.get_pod(config, pod)
    get_in(json, ["status", "podIP"])
  end

  defp exec(config, pod, container, cmd) do
    {:ok, out} = API.exec_once(config, pod, Enum.map(cmd, &to_string/1), container: container)
    out
  end

  defp node(config, pod, container, script, args) do
    config |> exec(pod, container, ["node", "-e", script | args]) |> String.trim()
  end

  defp sh(config, pod, container, script), do: exec(config, pod, container, ["sh", "-c", script])

  defp cat(config, pod, container, path),
    do: sh(config, pod, container, "cat #{path} 2>/dev/null || true")

  # An exec returns when its stdout closes, so the child is forked off with
  # its streams on /dev/null.
  defp detach(config, pod, container, cmd) do
    exec(config, pod, container, [
      "sh",
      "-c",
      ~S|setsid -f "$@" >/dev/null 2>&1 </dev/null|,
      "sh" | cmd
    ])
  end

  defp eventually(fun, deadline \\ 15_000) do
    cond do
      fun.() ->
        true

      deadline <= 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(500)
        eventually(fun, deadline - 500)
    end
  end

  defp decode_json(line) do
    case JSON.decode(line) do
      {:ok, map} when is_map(map) -> [map]
      _ -> []
    end
  end

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
