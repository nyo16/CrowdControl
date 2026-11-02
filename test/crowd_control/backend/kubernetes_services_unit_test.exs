defmodule CrowdControl.Backend.KubernetesServicesUnitTest do
  # Hermetic: the version lookup, the ConfigMap resource and the delete grace
  # are answered by a `:req_adapter` recorder; the manifests are pure.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Backend.Kubernetes.Drain
  alias CrowdControl.Backend.Kubernetes.Files
  alias CrowdControl.Backend.Kubernetes.Services
  alias CrowdControl.Service

  doctest CrowdControl.Backend.Kubernetes.Drain
  doctest CrowdControl.Backend.Kubernetes.Files
  doctest CrowdControl.Backend.Kubernetes.Services

  @key "0123456789abcdef0123456789abcdef"

  describe "API.server_version/1 (blocker: a gate that cannot see the cluster's version)" do
    test "GET /version, parsed, then cached per cluster URL" do
      body = %{"major" => "1", "minor" => "30+", "gitVersion" => "v1.30.2-gke.1"}
      {config, log} = recorder(fn _req -> {200, body} end)

      assert API.server_version(config) == {:ok, {1, 30}}
      assert [%{method: :get, path: "/version"}] = log.()

      assert API.server_version(config) == {:ok, {1, 30}}
      assert length(log.()) == 1
    end

    test "parses managed-cluster spellings, falling back to gitVersion" do
      assert API.parse_server_version(%{"major" => "1", "minor" => "29"}) == {:ok, {1, 29}}
      assert API.parse_server_version(%{"major" => "1", "minor" => "31+"}) == {:ok, {1, 31}}

      assert API.parse_server_version(%{"major" => "", "minor" => "", "gitVersion" => "v1.32.0"}) ==
               {:ok, {1, 32}}

      assert {:error, {:k8s, {:unparseable_version, _}}} = API.parse_server_version(%{})
    end

    test "a failed lookup is returned and not cached" do
      {config, log} = recorder(fn _req -> {403, %{"message" => "forbidden"}} end)

      assert {:error, {:k8s, {:forbidden, "forbidden"}}} = API.server_version(config)
      assert {:error, _} = API.server_version(config)
      assert length(log.()) == 2
    end
  end

  describe "ensure_versions/2 (blocker: a half-built session on an old cluster)" do
    test "no gated feature makes no request" do
      config = [
        kubeconfig: kubeconfig(unique_server()),
        req_adapter: fn _req -> raise "the transport must not be reached" end
      ]

      assert Kubernetes.ensure_versions(config, []) == :ok
    end

    test "a cluster below the floor is refused with only /version asked" do
      {config, log} = recorder(fn _req -> {200, %{"major" => "1", "minor" => "28"}} end)

      assert Kubernetes.ensure_versions(config, [:pod_sidecars]) ==
               {:error, {:version, :kubernetes, {1, 28}, {1, 29}}}

      assert Enum.map(log.(), &{&1.method, &1.path}) == [{:get, "/version"}]
    end

    test "the drain needs 1.30 even where sidecars are fine" do
      {config, _log} = recorder(fn _req -> {200, %{"major" => "1", "minor" => "29"}} end)

      assert Kubernetes.ensure_versions(config, [:pod_sidecars]) == :ok

      assert Kubernetes.ensure_versions(config, [:pod_sidecars, :prestop_sleep]) ==
               {:error, {:version, :kubernetes, {1, 29}, {1, 30}}}
    end
  end

  describe "delete grace (blocker: a log shipper SIGKILLed mid-flush)" do
    test "delete_pod defaults to grace 0 and passes an explicit budget through" do
      {config, log} = recorder(fn _req -> {200, %{}} end)

      assert {:ok, _} = API.delete_pod(config, "cc-a")
      assert {:ok, _} = API.delete_pod(config, "cc-b", 28)

      assert [%{method: :delete, path: path_a, query: q_a}, %{query: q_b}] = log.()
      assert path_a == "/api/v1/namespaces/ns1/pods/cc-a"
      assert q_a["gracePeriodSeconds"] == "0"
      assert q_b["gracePeriodSeconds"] == "28"
    end

    test "destroy/1 of a session with no drained service keeps grace 0" do
      {config, log} = recorder(fn _req -> {200, %{}} end)

      handle = %Kubernetes{
        pod_name: "cc-" <> @key,
        namespace: "ns1",
        session_key: @key,
        owner: "o",
        config: config
      }

      assert Kubernetes.destroy(handle) == :ok

      pod_delete = Enum.find(log.(), &String.ends_with?(&1.path, "/pods/cc-" <> @key))
      assert pod_delete.query["gracePeriodSeconds"] == "0"
    end

    test "the budget is drain + shutdown limit + margin, largest wins" do
      vector = %Service{name: "vector", drain: 3_000, shutdown_limit: 20}
      proxy = %Service{name: "proxy", drain: 0, shutdown_limit: 40}
      browser = %Service{name: "browser"}

      assert Drain.grace_seconds([browser]) == 0
      assert Drain.grace_seconds([vector, browser]) == 28
      assert Drain.grace_seconds([vector, proxy]) == 45

      assert Drain.termination_grace_period([browser]) == nil
      assert Drain.termination_grace_period([vector]) == 28

      assert Drain.lifecycle(browser) == nil
      assert Drain.lifecycle(proxy) == %{"preStop" => %{"sleep" => %{"seconds" => 0}}}

      assert Drain.version_features([browser]) == []
      assert Drain.version_features([browser, vector]) == [:prestop_sleep]
    end
  end

  describe "ConfigMap resource (blocker: staged config with nowhere to live)" do
    test "create, get and delete address the namespaced configmaps path" do
      {config, log} = recorder(fn _req -> {200, %{"kind" => "ConfigMap"}} end)
      manifest = Files.manifest(session("o"), "proxy", [file("/cfg/a.yaml", "x")])

      assert {:ok, _} = API.create_config_map(config, manifest)
      assert {:ok, _} = API.get_config_map(config, "cc-x-proxy-files")
      assert {:ok, _} = API.delete_config_map(config, "cc-x-proxy-files")

      assert [
               %{method: :post, path: "/api/v1/namespaces/ns1/configmaps", body: body},
               # kubereq's `get` appends the (empty) subresource segment.
               %{method: :get, path: "/api/v1/namespaces/ns1/configmaps/cc-x-proxy-files/"},
               %{method: :delete, path: "/api/v1/namespaces/ns1/configmaps/cc-x-proxy-files"}
             ] = log.()

      assert body["metadata"]["name"] == "cc-#{@key}-proxy-files"
    end

    test "list by label follows continue to the last page" do
      pages = %{
        nil => {200, %{"items" => [%{"n" => 1}], "metadata" => %{"continue" => "next"}}},
        "next" => {200, %{"items" => [%{"n" => 2}], "metadata" => %{}}}
      }

      {config, log} = recorder(fn req -> Map.fetch!(pages, req.query["continue"]) end)

      assert {:ok, [%{"n" => 1}, %{"n" => 2}]} =
               API.list_config_maps(config, [{"crowd_control.role", "service-config"}])

      [first | _] = log.()
      assert first.query["labelSelector"] == "crowd_control.role=service-config"
      assert first.query["limit"] == "500"
    end
  end

  describe "ConfigMap manifest (blocker: config readable, unlabelled, or unreapable)" do
    test "named, labelled and annotated like every other session object" do
      manifest = Files.manifest(session("node-a"), "proxy", [file("/cfg/a.yaml", "x")])

      assert manifest["kind"] == "ConfigMap"
      assert manifest["metadata"]["namespace"] == "ns1"
      assert manifest["metadata"]["name"] == "cc-#{@key}-proxy-files"

      assert manifest["metadata"]["labels"] == %{
               "crowd_control.session" => @key,
               "crowd_control.owner_hash" => Kubernetes.owner_label("node-a"),
               "crowd_control.service" => "proxy",
               "crowd_control.role" => "service-config"
             }

      assert manifest["metadata"]["annotations"] == %{"crowd_control.owner" => "node-a"}
    end

    test "text goes in data, bytes in binaryData, one collision-free key per file" do
      files = [file("/a/config.yaml", "x: 1\n"), file("/b/config.yaml", <<255, 0>>)]
      manifest = Files.manifest(session("o"), "svc", files)

      assert manifest["data"] == %{"0-config.yaml" => "x: 1\n"}
      assert manifest["binaryData"] == %{"1-config.yaml" => Base.encode64(<<255, 0>>)}
    end

    test "the volume projects each file with its mode; mounts are read-only subPaths" do
      files = [file("/cfg/acl.yaml", "a", 0o440), file("/etc/x.conf", "b")]

      assert Files.volume(@key, "proxy", files) == %{
               "name" => "cc-files-proxy",
               "configMap" => %{
                 "name" => "cc-#{@key}-proxy-files",
                 "items" => [
                   %{"key" => "0-acl.yaml", "path" => "0-acl.yaml", "mode" => 0o440},
                   %{"key" => "1-x.conf", "path" => "1-x.conf", "mode" => 0o644}
                 ]
               }
             }

      assert Files.mounts("proxy", files) == [
               %{
                 "name" => "cc-files-proxy",
                 "mountPath" => "/cfg/acl.yaml",
                 "subPath" => "0-acl.yaml",
                 "readOnly" => true
               },
               %{
                 "name" => "cc-files-proxy",
                 "mountPath" => "/etc/x.conf",
                 "subPath" => "1-x.conf",
                 "readOnly" => true
               }
             ]
    end
  end

  # --- B5: :services with placement ---

  @browser %{
    name: "browser",
    image: "browser:1",
    egress: :none,
    networks: ["sbx", "brw"],
    ports: [3000, 8931],
    ready: %{tcp_port: 8931},
    user: "10001:10001",
    env: %{"PW_WS_TOKEN" => "ccpw_0123456789abcdef"},
    host_config: %{shm_size: 1_073_741_824, tmpfs: %{"/tmp" => "rw,nosuid,size=512m"}},
    placement: :separate
  }

  @proxy %{
    name: "proxy",
    image: "smokescreen:1",
    egress: :allow,
    networks: ["brw"],
    ports: [4750],
    ready: %{tcp_port: 4750},
    files: [%{path: "/etc/smokescreen/acl.yaml", content: "version: v1\n"}],
    placement: :separate
  }

  @vector %{
    name: "vector",
    image: "vector:1",
    egress: :none,
    command: ["--config", "/etc/vector/vector.yaml"],
    volumes: [%{name: "capture", target: "/var/log/cc", read_only: true}],
    files: [%{path: "/etc/vector/vector.yaml", content: "data_dir: x\n", mode: 0o444}],
    host_config: %{tmpfs: %{"/var/lib/vector" => "rw,size=8m"}},
    user: "65532:65532",
    drain: 3_000,
    shutdown_limit: 20,
    placement: :pod
  }

  @aggregator %{
    name: "aggregator",
    egress: :none,
    ports: [6000],
    placement:
      {:external,
       %{
         namespace_selector: %{"kubernetes.io/metadata.name" => "logging"},
         pod_selector: %{"app" => "vector-aggregator"},
         host: "vector-aggregator.logging.svc",
         ip: "10.96.0.50"
       }}
  }

  @stack [@vector, @browser, @proxy, @aggregator]
  @ips %{"browser" => "10.96.0.11", "proxy" => "10.96.0.12", "sandbox" => "10.96.0.13"}

  describe "placement is validated before anything exists (blocker: a half-built session)" do
    test ":pod with egress: :allow is refused — the Pod is one network namespace" do
      leaky = %{@vector | egress: :allow}

      assert {:error, {:k8s, {:pod_sidecar_egress_forbidden, "vector"}}} = normalize([leaky])

      # Through provision/1, with a transport that must never be reached.
      assert Kubernetes.provision(provision_opts(fn _ -> raise "no request" end, [leaky])) ==
               {:error, {:k8s, {:pod_sidecar_egress_forbidden, "vector"}}}
    end

    test "an :allow service may not share sbx with the sandbox (invariant 1)" do
      assert {:error, {:k8s, {:sandbox_shares_network_with_egress, {"proxy", "sbx"}}}} =
               normalize([Map.delete(@proxy, :networks)])
    end

    test "placement is required, never inferred" do
      assert {:error, {:k8s, {:placement_required, "browser"}}} =
               normalize([Map.delete(@browser, :placement)])
    end

    test "names: reserved, too long for cc-<key>-<name>, duplicated" do
      assert {:error, {:k8s, {:reserved_service_name, "sandbox"}}} =
               normalize([%{@browser | name: "sandbox"}])

      long = String.duplicate("a", 28)

      assert {:error, {:k8s, {:service_name_too_long, ^long}}} =
               normalize([%{@browser | name: long}])

      assert {:error, {:k8s, {:duplicate_service, "browser"}}} = normalize([@browser, @browser])
    end

    test "the capture is shared read-only, and only into the sandbox Pod" do
      writable = %{@vector | volumes: [%{name: "capture", target: "/var/log/cc"}]}
      assert {:error, {:k8s, {:capture_mount_writable, "vector"}}} = normalize([writable])

      separate = %{@vector | placement: :separate}
      assert {:error, {:k8s, {:capture_not_shared, "vector"}}} = normalize([separate])
    end

    test "an external needs ports and a selector or CIDR; it needs no image" do
      assert {:ok, [%Service{image: nil}]} = normalize([@aggregator])
      assert {:error, {:k8s, {:bad_external, _}}} = normalize([%{@aggregator | ports: []}])

      assert {:error, {:k8s, {:bad_external, _}}} =
               normalize([%{@aggregator | placement: {:external, %{host: "x"}}}])

      assert {:ok, _} =
               normalize([%{@aggregator | placement: {:external, %{ip_block: "10.20.0.0/16"}}}])
    end

    test "a numeric user only, and services need an explicit :network" do
      assert {:error, {:k8s, {:bad_user, {"browser", "browser"}}}} =
               normalize([%{@browser | user: "browser"}])

      opts =
        provision_opts(fn _ -> raise "no request" end, [@browser]) |> Keyword.delete(:network)

      assert Kubernetes.provision(opts) == {:error, {:k8s, :network_policy_required}}
    end
  end

  describe "the sandbox Pod (blocker: a sidecar with the sandbox's reach, or none of its own)" do
    test "a :pod service is a native sidecar after cc-init, hardened and drained" do
      spec = sandbox_manifest()["spec"]

      assert [%{"name" => "cc-init"}, sidecar] = spec["initContainers"]
      assert sidecar["name"] == "vector"
      assert sidecar["restartPolicy"] == "Always"
      assert sidecar["args"] == ["--config", "/etc/vector/vector.yaml"]

      assert sidecar["securityContext"] == %{
               "allowPrivilegeEscalation" => false,
               "capabilities" => %{"drop" => ["ALL"]},
               "seccompProfile" => %{"type" => "RuntimeDefault"},
               "runAsUser" => 65_532,
               "runAsGroup" => 65_532,
               "runAsNonRoot" => true
             }

      assert sidecar["lifecycle"] == %{"preStop" => %{"sleep" => %{"seconds" => 3}}}
      assert spec["terminationGracePeriodSeconds"] == 28

      # The capture is the sandbox's own emptyDir, read-only; the config comes
      # from the ConfigMap; checkpoints get a Vector-only in-memory dir.
      mounts = Map.new(sidecar["volumeMounts"], &{&1["mountPath"], &1})

      assert mounts["/var/log/cc"] == %{
               "name" => "cc-var-log-cc",
               "mountPath" => "/var/log/cc",
               "readOnly" => true
             }

      assert mounts["/etc/vector/vector.yaml"]["readOnly"] == true
      assert mounts["/var/lib/vector"]["name"] == "cc-vector-tmp-0"

      volumes = Map.new(spec["volumes"], &{&1["name"], &1})
      assert volumes["cc-files-vector"]["configMap"]["name"] == "cc-#{@key}-vector-files"

      assert volumes["cc-vector-tmp-0"]["emptyDir"] == %{
               "medium" => "Memory",
               "sizeLimit" => "8Mi"
             }

      refute Map.has_key?(volumes, "cc-vector-vol-0"), "the capture must not become a PVC"
    end

    test "role: sandbox, and the service refs ride on an annotation" do
      metadata = sandbox_manifest()["metadata"]

      assert metadata["labels"]["crowd_control.role"] == "sandbox"

      assert Services.decode_refs(metadata["annotations"]["crowd_control.services"]) == [
               %{name: "vector", placement: :pod, grace: 28},
               %{name: "browser", placement: :separate, grace: 0},
               %{name: "proxy", placement: :separate, grace: 0}
             ]
    end

    test "hostAliases pin every reachable peer to its ClusterIP, and never the proxy" do
      assert sandbox_manifest()["spec"]["hostAliases"] == [
               %{"ip" => "10.96.0.11", "hostnames" => ["browser"]},
               %{
                 "ip" => "10.96.0.50",
                 "hostnames" => ["aggregator", "vector-aggregator.logging.svc"]
               }
             ]
    end

    test "without services the Pod is exactly what it was" do
      spec = Kubernetes.pod_manifest(handle([]))["spec"]

      assert [%{"name" => "cc-init"}] = spec["initContainers"]
      refute Map.has_key?(spec, "hostAliases")
      refute Map.has_key?(spec, "terminationGracePeriodSeconds")
    end
  end

  describe "sandbox policy (blocker: DNS or the proxy reachable from the sandbox)" do
    test "the deny-all selector names role: sandbox, so it never selects a service Pod" do
      policy = Kubernetes.network_policy_manifest(handle([]))

      assert policy["spec"]["podSelector"] == %{
               "matchLabels" => %{
                 "crowd_control.session" => @key,
                 "crowd_control.role" => "sandbox"
               }
             }

      # And with no services it is still the canonical deny-all.
      refute Map.has_key?(policy["spec"], "egress")
      refute Map.has_key?(policy["spec"], "ingress")

      # The raw owner, which the orphan sweep checks before deleting it.
      assert policy["metadata"]["annotations"] == %{"crowd_control.owner" => "node-a"}
    end

    test "only the named allows: browser and aggregator out, browser in to the app ports" do
      handle = handle([], sandbox_ports: [5173])
      {:ok, services} = Services.normalize([services: @stack], Kubernetes.service_context(handle))
      spec = Kubernetes.network_policy_manifest(handle, services)["spec"]

      assert spec["egress"] == [
               %{
                 "to" => [%{"podSelector" => %{"matchLabels" => service_labels("browser")}}],
                 "ports" => tcp([3000, 8931])
               },
               %{
                 "to" => [
                   %{
                     "namespaceSelector" => %{
                       "matchLabels" => %{"kubernetes.io/metadata.name" => "logging"}
                     },
                     "podSelector" => %{"matchLabels" => %{"app" => "vector-aggregator"}}
                   }
                 ],
                 "ports" => tcp([6000])
               }
             ]

      assert spec["ingress"] == [
               %{
                 "from" => [%{"podSelector" => %{"matchLabels" => service_labels("browser")}}],
                 "ports" => tcp([5173])
               }
             ]

      refute inspect(spec) =~ "kube-dns"
      refute Enum.any?(spec["egress"], &(&1["ports"] |> Enum.any?(fn p -> p["port"] == 53 end)))
    end
  end

  describe "a :separate service (blocker: a browser with its own way out)" do
    setup do
      handle = handle([], sandbox_ports: [5173])
      ctx = Kubernetes.service_context(handle)
      {:ok, services} = Services.normalize([services: @stack], ctx)
      browser = Enum.find(services, &(&1.name == "browser"))
      proxy = Enum.find(services, &(&1.name == "proxy"))
      %{ctx: ctx, services: services, browser: browser, proxy: proxy}
    end

    test "its Pod: own name, role, probe, in-memory /dev/shm and /tmp, own uid, aliases",
         %{ctx: ctx, services: services, browser: browser} do
      aliases = Services.host_aliases(browser, services, @ips)
      pod = Services.pod_manifest(ctx, browser, aliases)

      assert pod["metadata"]["name"] == "cc-#{@key}-browser"
      assert pod["metadata"]["labels"]["crowd_control.role"] == "service"
      assert pod["metadata"]["labels"]["crowd_control.service"] == "browser"
      assert pod["metadata"]["annotations"] == %{"crowd_control.owner" => "node-a"}

      spec = pod["spec"]
      assert spec["automountServiceAccountToken"] == false
      assert spec["enableServiceLinks"] == false
      assert spec["restartPolicy"] == "Never"
      assert spec["securityContext"] == %{"fsGroup" => 10_001}

      # No DNS here either: the proxy and the sandbox by ClusterIP.
      assert spec["hostAliases"] == [
               %{"ip" => "10.96.0.12", "hostnames" => ["proxy"]},
               %{"ip" => "10.96.0.13", "hostnames" => ["sandbox"]}
             ]

      [container] = spec["containers"]
      assert container["readinessProbe"]["tcpSocket"] == %{"port" => 8931}
      assert container["securityContext"]["runAsUser"] == 10_001
      assert container["env"] == [%{"name" => "PW_WS_TOKEN", "value" => "ccpw_0123456789abcdef"}]

      volumes = Map.new(spec["volumes"], &{&1["name"], &1["emptyDir"]})
      assert volumes["cc-browser-shm"] == %{"medium" => "Memory", "sizeLimit" => "1073741824"}
      assert volumes["cc-browser-tmp-0"] == %{"medium" => "Memory", "sizeLimit" => "512Mi"}

      assert Enum.map(container["volumeMounts"], & &1["mountPath"]) == ["/tmp", "/dev/shm"]
    end

    test "its Service fronts its ports by its own labels", %{ctx: ctx, browser: browser} do
      service = Services.service_manifest(ctx, browser)

      assert service["kind"] == "Service"
      assert service["metadata"]["name"] == "cc-#{@key}-browser"
      assert service["metadata"]["labels"]["crowd_control.role"] == "service"
      assert service["spec"]["type"] == "ClusterIP"
      assert service["spec"]["selector"] == service_labels("browser")
      assert Enum.map(service["spec"]["ports"], & &1["port"]) == [3000, 8931]
    end

    test "the browser's policy: in from the sandbox, out to the proxy and the app only",
         %{ctx: ctx, services: services, browser: browser} do
      spec = Services.policy_manifest(ctx, browser, services, [5173])["spec"]
      sandbox = %{"podSelector" => %{"matchLabels" => sandbox_labels()}}

      assert spec["podSelector"] == %{"matchLabels" => service_labels("browser")}
      assert spec["policyTypes"] == ["Ingress", "Egress"]
      assert spec["ingress"] == [%{"from" => [sandbox], "ports" => tcp([3000, 8931])}]

      assert spec["egress"] == [
               %{
                 "to" => [%{"podSelector" => %{"matchLabels" => service_labels("proxy")}}],
                 "ports" => tcp([4750])
               },
               %{"to" => [sandbox], "ports" => tcp([5173])}
             ]

      refute inspect(spec) =~ "ipBlock"
      refute inspect(spec) =~ "kube-dns"
    end

    test "the proxy's policy: in from the browser only, out to DNS and public 443",
         %{ctx: ctx, services: services, proxy: proxy} do
      spec = Services.policy_manifest(ctx, proxy, services, [5173])["spec"]

      assert spec["ingress"] == [
               %{
                 "from" => [%{"podSelector" => %{"matchLabels" => service_labels("browser")}}],
                 "ports" => tcp([4750])
               }
             ]

      [dns, internet] = spec["egress"]

      assert dns["to"] == [
               %{
                 "namespaceSelector" => %{
                   "matchLabels" => %{"kubernetes.io/metadata.name" => "kube-system"}
                 },
                 "podSelector" => %{"matchLabels" => %{"k8s-app" => "kube-dns"}}
               }
             ]

      assert internet == %{
               "to" => [
                 %{
                   "ipBlock" => %{
                     "cidr" => "0.0.0.0/0",
                     "except" => [
                       "10.0.0.0/8",
                       "172.16.0.0/12",
                       "192.168.0.0/16",
                       "169.254.0.0/16",
                       "100.64.0.0/10"
                     ]
                   }
                 },
                 %{"ipBlock" => %{"cidr" => "::/0", "except" => ["fc00::/7", "fe80::/10"]}}
               ],
               "ports" => tcp([443])
             }
    end
  end

  describe "list_live (blocker: a browser Pod reattached as a sandbox)" do
    test "the selector excludes role=service and still matches unlabelled sandboxes" do
      sandbox =
        sandbox_manifest()
        |> put_in(["status"], %{"phase" => "Running"})

      {config, log} = recorder(fn _req -> {200, %{"items" => [sandbox], "metadata" => %{}}} end)

      assert {:ok, [handle]} = Kubernetes.list_live([{:owner, "node-a"} | config])

      [list] = log.()

      assert list.query["labelSelector"] ==
               "crowd_control.owner_hash=#{Kubernetes.owner_label("node-a")}," <>
                 "crowd_control.role!=service"

      # The rebuilt handle can still name every derived object.
      assert Enum.map(handle.services, & &1.name) == ["vector", "browser", "proxy"]
    end
  end

  describe "provision order and rollback (blocker: orphans after a failed create)" do
    test "version → ConfigMaps → policies → Services → service Pods → ready → sandbox" do
      {config, log} = recorder(&cluster/1)

      assert {:ok, handle} = Kubernetes.provision(provision_opts(config, @stack))
      assert Enum.map(handle.services, & &1.name) == ["vector", "browser", "proxy"]

      creates =
        for %{method: :post, path: path, body: body} <- log.(),
            do: {kind(path), body["metadata"]["name"]}

      assert creates == [
               {:configmaps, "cc-#{@key}-vector-files"},
               {:configmaps, "cc-#{@key}-proxy-files"},
               {:networkpolicies, "cc-#{@key}-deny-all"},
               {:networkpolicies, "cc-#{@key}-browser"},
               {:networkpolicies, "cc-#{@key}-proxy"},
               {:services, "cc-#{@key}-browser"},
               {:services, "cc-#{@key}-proxy"},
               {:pods, "cc-#{@key}-browser"},
               {:pods, "cc-#{@key}-proxy"},
               {:pods, "cc-#{@key}"}
             ]

      assert [%{path: "/version"} | _] = log.()

      # The sandbox's aliases carry the ClusterIPs the API server allocated.
      sandbox =
        Enum.find(log.(), &(&1.method == :post and &1.body["metadata"]["name"] == "cc-#{@key}"))

      assert %{"ip" => "10.96.1.1", "hostnames" => ["browser"]} in sandbox.body["spec"][
               "hostAliases"
             ]
    end

    test "a failed create deletes everything created so far, and the sandbox never starts" do
      {config, log} =
        recorder(fn
          %{
            method: :post,
            path: "/api/v1/namespaces/ns1/pods",
            body: %{"metadata" => %{"name" => name}}
          } = req ->
            if String.ends_with?(name, "-proxy"),
              do: {500, %{"message" => "admission webhook says no"}},
              else: cluster(req)

          req ->
            cluster(req)
        end)

      assert {:error, {:k8s, {:http_status, 500, _}}} =
               Kubernetes.provision(provision_opts(config, @stack))

      requests = log.()
      created = for %{method: :post, body: body} <- requests, do: body["metadata"]["name"]
      deleted = for %{method: :delete, path: path} <- requests, do: Path.basename(path)

      refute "cc-#{@key}" in created, "the sandbox Pod must not be created after a failure"

      for name <- created, name != "cc-#{@key}-proxy" do
        assert name in deleted, "#{name} was created and never deleted"
      end

      # The drained sidecar's grace applies to the sandbox Pod even on rollback.
      sandbox_delete =
        Enum.find(requests, &(&1.method == :delete and &1.path =~ ~r"/pods/cc-#{@key}$"))

      assert sandbox_delete.query["gracePeriodSeconds"] == "28"
    end

    test "destroy/1 of a rebuilt handle deletes every derived name, 404 being success" do
      {config, log} = recorder(fn _req -> {404, %{"message" => "gone"}} end)

      refs =
        Services.decode_refs(
          sandbox_manifest()["metadata"]["annotations"]["crowd_control.services"]
        )

      handle = handle(config, services: refs, sandbox_ports: [5173])

      assert Kubernetes.destroy(handle) == :ok

      deleted =
        for %{method: :delete, path: path} <- log.(), do: {kind(path), Path.basename(path)}

      for expected <- [
            {:pods, "cc-#{@key}"},
            {:pods, "cc-#{@key}-browser"},
            {:pods, "cc-#{@key}-proxy"},
            {:services, "cc-#{@key}-browser"},
            {:services, "cc-#{@key}-proxy"},
            {:services, "cc-#{@key}-sandbox"},
            {:networkpolicies, "cc-#{@key}-browser"},
            {:networkpolicies, "cc-#{@key}-proxy"},
            {:networkpolicies, "cc-#{@key}-deny-all"},
            {:configmaps, "cc-#{@key}-vector-files"},
            {:configmaps, "cc-#{@key}-browser-files"},
            {:configmaps, "cc-#{@key}-proxy-files"}
          ] do
        assert expected in deleted, "#{inspect(expected)} was not deleted"
      end
    end
  end

  describe "orphan sweep (blocker: a crash between service objects and the sandbox Pod)" do
    test "only old, owned objects of sessions with no live sandbox are deleted" do
      old = System.system_time(:millisecond) - 120_000
      young = System.system_time(:millisecond) - 5_000

      pods = [
        # Session "live" still has its sandbox: its browser stays.
        object("cc-live", "live", "sandbox", old, phase: "Running"),
        object("cc-live-browser", "live", "service", old),
        # Session "dead" has no sandbox: its objects go.
        object("cc-dead-browser", "dead", "service", old),
        # Too young: a provision may still be in flight.
        object("cc-new-browser", "new", "service", young),
        # The hash matched, the raw owner did not.
        object("cc-foreign-browser", "foreign", "service", old, owner: "node-b"),
        # A finished sandbox does not keep its services alive.
        object("cc-done", "done", "sandbox", old, phase: "Succeeded"),
        object("cc-done-browser", "done", "service", old)
      ]

      by_kind = %{
        pods: pods,
        services: [object("cc-dead-browser", "dead", "service", old)],
        # The sandbox's own deny-all is created before its Pod (role sandbox):
        # a crash orphans it like any service object (regression, found by
        # kubernetes_browser_test.exs), while a live sandbox keeps its own.
        networkpolicies: [
          object("cc-dead-browser", "dead", "service", old),
          object("cc-dead-deny-all", "dead", "sandbox", nil, created: old),
          object("cc-live-deny-all", "live", "sandbox", nil, created: old)
        ],
        configmaps: [object("cc-dead-proxy-files", "dead", "service-config", nil, created: old)]
      }

      {config, log} =
        recorder(fn
          %{method: :get, path: path} ->
            {200, %{"items" => by_kind[kind(path)], "metadata" => %{}}}

          %{method: :delete} ->
            {200, %{}}
        end)

      assert {:ok, 6} =
               Kubernetes.sweep_orphans([owner: "node-a", provision_timeout: 1_000] ++ config)

      requests = log.()

      deleted =
        for %{method: :delete, path: path} <- requests, do: {kind(path), Path.basename(path)}

      assert Enum.sort(deleted) == [
               {:configmaps, "cc-dead-proxy-files"},
               {:networkpolicies, "cc-dead-browser"},
               {:networkpolicies, "cc-dead-deny-all"},
               {:pods, "cc-dead-browser"},
               {:pods, "cc-done-browser"},
               {:services, "cc-dead-browser"}
             ]

      # Every list was scoped to this owner's hash, the service lists to roles.
      lists =
        for %{method: :get} = req <- requests, do: {kind(req.path), req.query["labelSelector"]}

      hash = Kubernetes.owner_label("node-a")

      assert {:pods, "crowd_control.owner_hash=#{hash}"} in lists
      assert {:services, "crowd_control.owner_hash=#{hash},crowd_control.role=service"} in lists
      assert {:networkpolicies, "crowd_control.owner_hash=#{hash}"} in lists

      assert {:configmaps, "crowd_control.owner_hash=#{hash},crowd_control.role=service-config"} in lists
    end

    test "a failed list deletes nothing (fail open)" do
      {config, log} =
        recorder(fn
          %{method: :get, path: "/api/v1/namespaces/ns1/services"} ->
            {403, %{"message" => "no list"}}

          %{method: :get} ->
            {200, %{"items" => [], "metadata" => %{}}}

          %{method: :delete} ->
            raise "nothing may be deleted"
        end)

      assert {:error, {:k8s, {:forbidden, "no list"}}} =
               Kubernetes.sweep_orphans([owner: "node-a"] ++ config)

      refute Enum.any?(log.(), &(&1.method == :delete))
    end
  end

  defp normalize(specs) do
    Services.normalize([services: specs], Kubernetes.service_context(handle([])))
  end

  defp handle(config, extra \\ []) do
    struct!(
      %Kubernetes{
        pod_name: "cc-" <> @key,
        namespace: "ns1",
        image: "sandbox:1",
        tee_path: "/var/log/cc/out.jsonl",
        fifo_path: "/var/run/cc.fifo",
        env_path: "/var/run/cc.env",
        session_key: @key,
        owner: "node-a",
        config: config
      },
      extra
    )
  end

  defp sandbox_manifest do
    handle = handle([])
    {:ok, services} = Services.normalize([services: @stack], Kubernetes.service_context(handle))
    Kubernetes.pod_manifest(handle, services, @ips)
  end

  defp provision_opts(adapter, services) when is_function(adapter) do
    provision_opts([kubeconfig: kubeconfig(unique_server()), req_adapter: adapter], services)
  end

  defp provision_opts(config, services) do
    config ++
      [
        image: "sandbox:1",
        session_key: @key,
        owner: "node-a",
        network: :deny_all,
        network_probe: false,
        provision_timeout: 2_000,
        services: services
      ]
  end

  # A cluster that accepts everything: 1.31, every create echoed (Services
  # with a ClusterIP), every Pod Running and Ready, every delete a 404.
  defp cluster(%{method: :get, path: "/version"}), do: {200, %{"major" => "1", "minor" => "31"}}

  defp cluster(%{method: :post, path: "/api/v1/namespaces/ns1/services", body: body}) do
    ip = if body["metadata"]["name"] =~ "browser", do: "10.96.1.1", else: "10.96.1.2"
    {201, put_in(body, ["spec", "clusterIP"], ip)}
  end

  defp cluster(%{method: :post, body: body}), do: {201, body}

  defp cluster(%{method: :get, path: "/api/v1/namespaces/ns1/pods", query: query}) do
    "metadata.name=" <> name = query["fieldSelector"]
    {200, %{"items" => [ready_pod(name)], "metadata" => %{"resourceVersion" => "1"}}}
  end

  defp cluster(%{method: :get, path: "/api/v1/namespaces/ns1/pods/" <> name}),
    do: {200, ready_pod(String.trim_trailing(name, "/"))}

  defp cluster(%{method: :delete}), do: {404, %{"message" => "not found"}}

  defp ready_pod(name) do
    %{
      "metadata" => %{"name" => name},
      "status" => %{
        "phase" => "Running",
        "conditions" => [%{"type" => "Ready", "status" => "True"}]
      }
    }
  end

  defp object(name, session, role, created_at, opts \\ []) do
    labels =
      %{
        "crowd_control.session" => session,
        "crowd_control.owner_hash" => Kubernetes.owner_label("node-a"),
        "crowd_control.role" => role
      }
      |> then(
        &if created_at,
          do: Map.put(&1, "crowd_control.created_at", to_string(created_at)),
          else: &1
      )

    metadata =
      %{
        "name" => name,
        "labels" => labels,
        "annotations" => %{"crowd_control.owner" => Keyword.get(opts, :owner, "node-a")}
      }
      |> then(fn metadata ->
        case opts[:created] do
          nil ->
            metadata

          ms ->
            Map.put(
              metadata,
              "creationTimestamp",
              ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
            )
        end
      end)

    %{"metadata" => metadata, "status" => %{"phase" => Keyword.get(opts, :phase, "Running")}}
  end

  defp kind(path) do
    cond do
      path =~ "/configmaps" -> :configmaps
      path =~ "/networkpolicies" -> :networkpolicies
      path =~ "/services" -> :services
      path =~ "/pods" -> :pods
      true -> :other
    end
  end

  defp service_labels(name) do
    %{
      "crowd_control.session" => @key,
      "crowd_control.role" => "service",
      "crowd_control.service" => name
    }
  end

  defp sandbox_labels,
    do: %{"crowd_control.session" => @key, "crowd_control.role" => "sandbox"}

  defp tcp(ports), do: Enum.map(ports, &%{"protocol" => "TCP", "port" => &1})

  defp session(owner), do: %{session_key: @key, owner: owner, namespace: "ns1"}

  # --- helpers ---

  defp file(path, content, mode \\ 0o644) do
    %{path: path, content: content, mode: mode, uid: 0, gid: 0}
  end

  # A cluster URL no other test uses, so the per-cluster version cache is this
  # test's alone. Never dialled: the adapter answers.
  defp unique_server, do: "https://k8s-#{System.unique_integer([:positive])}.test"

  defp kubeconfig(server) do
    Kubereq.Kubeconfig.new!(
      current_context: "t",
      current_cluster: %{"server" => server},
      current_user: %{},
      contexts: [],
      clusters: [],
      users: [],
      current_namespace: "ns1"
    )
  end

  defp recorder(respond) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    adapter = fn req ->
      entry = %{
        method: req.method,
        path: req.url.path,
        query: URI.decode_query(req.url.query || ""),
        body: decode(req.body)
      }

      Agent.update(agent, &[entry | &1])
      {status, body} = respond.(entry)
      {req, Req.Response.new(status: status, body: body)}
    end

    config = [kubeconfig: kubeconfig(unique_server()), req_adapter: adapter]
    {config, fn -> Agent.get(agent, &Enum.reverse/1) end}
  end

  defp decode(body) when is_binary(body) and body != "", do: JSON.decode!(body)
  defp decode(body) when is_list(body), do: body |> IO.iodata_to_binary() |> decode()
  defp decode(_body), do: nil
end
