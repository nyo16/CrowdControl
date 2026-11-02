defmodule CrowdControl.Backend.KubernetesServicesUnitTest do
  # Hermetic: the version lookup, the ConfigMap resource and the delete grace
  # are answered by a `:req_adapter` recorder; the manifests are pure.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Backend.Kubernetes.Drain
  alias CrowdControl.Backend.Kubernetes.Files
  alias CrowdControl.Backend.Kubernetes.Secrets
  alias CrowdControl.Backend.Kubernetes.Services
  alias CrowdControl.Preset.LogShipper
  alias CrowdControl.Service

  doctest CrowdControl.Backend.Kubernetes.Drain
  doctest CrowdControl.Backend.Kubernetes.Files
  doctest CrowdControl.Backend.Kubernetes.Secrets
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
    host_config: %{
      shm_size: 1_073_741_824,
      tmpfs: %{"/tmp" => "rw,noexec,nosuid,size=512m"}
    },
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
    host_config: %{tmpfs: %{"/var/lib/vector" => "rw,noexec,nosuid,size=8m"}},
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

      # By reference to the session's Secret: the token is not in the Pod.
      assert container["env"] == [
               %{
                 "name" => "PW_WS_TOKEN",
                 "valueFrom" => %{
                   "secretKeyRef" => %{"name" => "cc-#{@key}-browser-env", "key" => "PW_WS_TOKEN"}
                 }
               }
             ]

      refute JSON.encode!(pod) =~ "ccpw_0123456789abcdef"

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

  describe "service env (blocker: a credential readable with `get pods`)" do
    test "the Secret: named, labelled, annotated like every session object, values in data" do
      session = Map.put(session("node-a"), :sweep_after_ms, 1_234)

      manifest =
        Secrets.manifest(session, "browser", %{"PW_WS_TOKEN" => "ccpw_x", "B" => <<255>>})

      assert manifest["kind"] == "Secret"
      assert manifest["type"] == "Opaque"
      assert manifest["metadata"]["name"] == "cc-#{@key}-browser-env"
      assert manifest["metadata"]["namespace"] == "ns1"

      assert manifest["metadata"]["labels"] == %{
               "crowd_control.session" => @key,
               "crowd_control.owner_hash" => Kubernetes.owner_label("node-a"),
               "crowd_control.service" => "browser",
               "crowd_control.role" => "service-secret"
             }

      assert manifest["metadata"]["annotations"] == %{
               "crowd_control.owner" => "node-a",
               "crowd_control.sweep_after_ms" => "1234"
             }

      assert manifest["data"] == %{
               "PW_WS_TOKEN" => Base.encode64("ccpw_x"),
               "B" => Base.encode64(<<255>>)
             }

      refute Map.has_key?(manifest, "stringData")
    end

    test "create, get, delete and list address the namespaced secrets path" do
      {config, log} = recorder(fn _req -> {200, %{"items" => [], "metadata" => %{}}} end)
      manifest = Secrets.manifest(session("o"), "proxy", %{"K" => "v"})

      assert {:ok, _} = API.create_secret(config, manifest)
      assert {:ok, _} = API.get_secret(config, "cc-x-proxy-env")
      assert {:ok, _} = API.delete_secret(config, "cc-x-proxy-env")
      assert {:ok, []} = API.list_secrets(config, [{"crowd_control.role", "service-secret"}])

      assert [
               %{method: :post, path: "/api/v1/namespaces/ns1/secrets"},
               %{method: :get, path: "/api/v1/namespaces/ns1/secrets/cc-x-proxy-env/"},
               %{method: :delete, path: "/api/v1/namespaces/ns1/secrets/cc-x-proxy-env"},
               %{method: :get, path: "/api/v1/namespaces/ns1/secrets", query: query}
             ] = log.()

      assert query["labelSelector"] == "crowd_control.role=service-secret"
    end

    test "no literal value in any Pod provision/1 creates, a :pod sidecar's included" do
      vector = Map.put(@vector, :env, %{"VECTOR_SINK_TOKEN" => "s3cr3t-vector-token"})
      stack = [vector, @browser, @proxy, @aggregator]
      {config, log} = recorder(&cluster/1)

      assert {:ok, _handle} = Kubernetes.provision(provision_opts(config, stack))

      posts = for %{method: :post, path: path, body: body} <- log.(), do: {kind(path), body}
      pods = for {:pods, body} <- posts, do: body

      assert length(pods) == 3

      for pod <- pods, value <- ["s3cr3t-vector-token", "ccpw_0123456789abcdef"] do
        refute JSON.encode!(pod) =~ value, "#{pod["metadata"]["name"]} carries #{value}"
        refute JSON.encode!(pod) =~ Base.encode64(value)
      end

      sandbox = Enum.find(pods, &(&1["metadata"]["name"] == "cc-#{@key}"))
      [_init, sidecar] = sandbox["spec"]["initContainers"]

      assert sidecar["env"] == [
               %{
                 "name" => "VECTOR_SINK_TOKEN",
                 "valueFrom" => %{
                   "secretKeyRef" => %{
                     "name" => "cc-#{@key}-vector-env",
                     "key" => "VECTOR_SINK_TOKEN"
                   }
                 }
               }
             ]

      # The annotation destroy/1 derives names from: refs, never env.
      annotation = sandbox["metadata"]["annotations"]["crowd_control.services"]
      refute annotation =~ "VECTOR_SINK_TOKEN"
      refute annotation =~ "PW_WS_TOKEN"

      # The values are in the session's Secrets, one per service with env.
      secrets = Map.new(for({:secrets, body} <- posts, do: {body["metadata"]["name"], body}))
      assert Map.keys(secrets) == ["cc-#{@key}-browser-env", "cc-#{@key}-vector-env"]

      assert secrets["cc-#{@key}-vector-env"]["data"] == %{
               "VECTOR_SINK_TOKEN" => Base.encode64("s3cr3t-vector-token")
             }
    end

    test "an env name that cannot be a Secret key is refused before any request" do
      bad = %{@browser | env: %{"BAD KEY" => "v"}}

      assert Kubernetes.provision(provision_opts(fn _ -> raise "no request" end, [bad])) ==
               {:error, {:k8s, {:bad_service, {"browser", :env}}}}
    end
  end

  describe "declared weakenings render (D9; W-19)" do
    setup do
      handle = handle(readonly_rootfs: true)
      ctx = Kubernetes.service_context(handle)

      hardy = %{
        name: "hardy",
        image: "hardy:1",
        egress: :none,
        user: "1000:1000",
        host_config: %{
          cap_add: ["SYS_ADMIN"],
          no_new_privileges: false,
          readonly_rootfs: false,
          memory: 268_435_456,
          cpus: 0.5,
          tmpfs: %{"/scratch" => "rw,noexec,nosuid,size=16m"}
        },
        weaken: [:cap_add, :no_new_privileges, :readonly_rootfs],
        placement: :separate
      }

      plain = %{
        name: "plain",
        image: "plain:1",
        egress: :none,
        user: "1001",
        placement: :separate
      }

      %{ctx: ctx, hardy: hardy, plain: plain}
    end

    test "each declared key renders, and only on its own service", ctx do
      {:ok, services} = Services.normalize([services: [ctx.hardy, ctx.plain]], ctx.ctx)
      [hardy, plain] = Enum.map(services, &container(Services.pod_manifest(ctx.ctx, &1, [])))

      # `readonly_rootfs: false` overrides the stack's `true`: no key at all.
      assert hardy["securityContext"] == %{
               "allowPrivilegeEscalation" => true,
               "capabilities" => %{"drop" => ["ALL"], "add" => ["SYS_ADMIN"]},
               "seccompProfile" => %{"type" => "RuntimeDefault"},
               "runAsUser" => 1_000,
               "runAsGroup" => 1_000,
               "runAsNonRoot" => true
             }

      assert hardy["resources"] == %{"limits" => %{"memory" => "268435456", "cpu" => "500m"}}

      # The sibling keeps every default of the stack.
      assert plain["securityContext"] == %{
               "allowPrivilegeEscalation" => false,
               "capabilities" => %{"drop" => ["ALL"]},
               "seccompProfile" => %{"type" => "RuntimeDefault"},
               "readOnlyRootFilesystem" => true,
               "runAsUser" => 1_001,
               "runAsNonRoot" => true
             }

      refute Map.has_key?(plain, "resources")
    end

    test "a service may harden past the stack: readonly_rootfs: true needs no declaration",
         ctx do
      ctx_rw = Kubernetes.service_context(handle([]))
      locked = put_in(ctx.plain, [:host_config], %{readonly_rootfs: true})

      {:ok, [service]} = Services.normalize([services: [locked]], ctx_rw)

      assert container(Services.pod_manifest(ctx_rw, service, []))["securityContext"][
               "readOnlyRootFilesystem"
             ]

      {:ok, [service]} = Services.normalize([services: [ctx.plain]], ctx_rw)

      refute Map.has_key?(
               container(Services.pod_manifest(ctx_rw, service, []))["securityContext"],
               "readOnlyRootFilesystem"
             )
    end

    test "an undeclared weakening and a malformed tmpfs size are refused", ctx do
      undeclared = %{ctx.hardy | weaken: [:no_new_privileges, :readonly_rootfs]}

      assert {:error, {:k8s, {:weakening_not_declared, {"hardy", :cap_add}}}} =
               Services.normalize([services: [undeclared, ctx.plain]], ctx.ctx)

      malformed =
        put_in(ctx.hardy, [:host_config, :tmpfs], %{"/scratch" => "rw,noexec,nosuid,size=lots"})

      assert {:error, {:k8s, {:bad_host_config, {"hardy", :tmpfs}}}} =
               Services.normalize([services: [malformed, ctx.plain]], ctx.ctx)
    end
  end

  describe "user and files posture (G1/G2)" do
    setup do
      ctx = Kubernetes.service_context(handle([]))
      %{ctx: ctx, base: %{name: "svc", image: "svc:1", egress: :none, placement: :separate}}
    end

    test "no user: the kubelet must prove the image is not root, unless :user is declared",
         %{ctx: ctx, base: base} do
      assert security(ctx, base) == %{
               "allowPrivilegeEscalation" => false,
               "capabilities" => %{"drop" => ["ALL"]},
               "seccompProfile" => %{"type" => "RuntimeDefault"},
               "runAsNonRoot" => true
             }

      refute Map.has_key?(security(ctx, Map.put(base, :weaken, [:user])), "runAsNonRoot")
    end

    test "root is numeric: \"00\" and \"000:1000\" are uid 0, and need weaken: [:user]",
         %{ctx: ctx, base: base} do
      for user <- ["00", "000:1000"] do
        assert {:error, {:k8s, {:weakening_not_declared, {"svc", :user}}}} =
                 Services.normalize([services: [Map.put(base, :user, user)]], ctx)
      end

      declared = Map.put(base, :weaken, [:user])

      assert %{"runAsUser" => 0, "runAsNonRoot" => false} =
               security = security(ctx, Map.put(declared, :user, "00"))

      refute Map.has_key?(security, "runAsGroup")

      assert %{"runAsUser" => 0, "runAsGroup" => 1_000, "runAsNonRoot" => false} =
               security(ctx, Map.put(declared, :user, "000:1000"))

      assert %{"runAsUser" => 1_000, "runAsNonRoot" => true} =
               security(ctx, Map.put(base, :user, "1000"))
    end

    test "the :files budget counts the ConfigMap's base64, not the raw bytes",
         %{ctx: ctx, base: base} do
      # 800 000 raw bytes pass `Service.normalize/2`; base64 makes them 1 066 668.
      raw = 800_000
      binary = [%{path: "/data/blob", content: :binary.copy(<<255>>, raw)}]
      text = [%{path: "/data/blob", content: String.duplicate("a", raw)}]

      assert raw < Service.max_files_bytes()

      assert {:error, {:k8s, {:files_too_large, {"svc", 1_066_668}}}} =
               Services.normalize([services: [Map.put(base, :files, binary)]], ctx)

      assert {:ok, _} = Services.normalize([services: [Map.put(base, :files, text)]], ctx)
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
    test "version → ConfigMaps → Secrets → policies → Services → service Pods → ready → sandbox" do
      {config, log} = recorder(&cluster/1)

      assert {:ok, handle} = Kubernetes.provision(provision_opts(config, @stack))
      assert Enum.map(handle.services, & &1.name) == ["vector", "browser", "proxy"]

      creates =
        for %{method: :post, path: path, body: body} <- log.(),
            do: {kind(path), body["metadata"]["name"]}

      assert creates == [
               {:configmaps, "cc-#{@key}-vector-files"},
               {:configmaps, "cc-#{@key}-proxy-files"},
               {:secrets, "cc-#{@key}-browser-env"},
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
      assert "cc-#{@key}-browser-env" in created

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
            {:configmaps, "cc-#{@key}-proxy-files"},
            {:secrets, "cc-#{@key}-vector-env"},
            {:secrets, "cc-#{@key}-browser-env"},
            {:secrets, "cc-#{@key}-proxy-env"}
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
        configmaps: [object("cc-dead-proxy-files", "dead", "service-config", nil, created: old)],
        secrets: [
          object("cc-dead-browser-env", "dead", "service-secret", nil, created: old),
          object("cc-live-browser-env", "live", "service-secret", nil, created: old)
        ]
      }

      {config, log} =
        recorder(fn
          %{method: :get, path: path} ->
            {200, %{"items" => by_kind[kind(path)], "metadata" => %{}}}

          %{method: :delete} ->
            {200, %{}}
        end)

      assert {:ok, 7} =
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
               {:secrets, "cc-dead-browser-env"},
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

      assert {:secrets, "crowd_control.owner_hash=#{hash},crowd_control.role=service-secret"} in lists
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

  describe "teardown order (blocker: a terminating sandbox with no NetworkPolicy)" do
    test "a drained sandbox Pod is gone before its deny-all or any derived object is deleted" do
      {:ok, polls} = Agent.start_link(fn -> [{200, terminating_pod("cc-#{@key}")}] end)

      {config, log} =
        recorder(fn
          %{method: :get, path: "/api/v1/namespaces/ns1/pods/cc-" <> _} ->
            Agent.get_and_update(polls, fn
              [next | rest] -> {next, rest}
              [] -> {{404, %{"message" => "not found"}}, []}
            end)

          %{method: :delete} ->
            {200, %{}}
        end)

      refs = [
        %{name: "vector", placement: :pod, grace: 28},
        %{name: "browser", placement: :separate, grace: 0}
      ]

      assert Kubernetes.destroy(handle(config, services: refs)) == :ok

      requests = Enum.map(log.(), &{&1.method, kind(&1.path), Path.basename(&1.path)})

      assert [
               {:delete, :pods, "cc-#{@key}"},
               {:get, :pods, "cc-#{@key}"},
               {:get, :pods, "cc-#{@key}"} | after_gone
             ] = requests

      assert {:delete, :networkpolicies, "cc-#{@key}-deny-all"} in after_gone
      assert {:delete, :networkpolicies, "cc-#{@key}-browser"} in after_gone
      assert {:delete, :pods, "cc-#{@key}-browser"} in after_gone
      assert {:delete, :configmaps, "cc-#{@key}-vector-files"} in after_gone

      sandbox_delete = hd(log.())
      assert sandbox_delete.query["gracePeriodSeconds"] == "28"
    end

    test "a drained :separate service keeps its own policy until it is gone" do
      {:ok, polls} = Agent.start_link(fn -> [{200, terminating_pod("cc-#{@key}-proxy")}] end)

      {config, log} =
        recorder(fn
          %{method: :get, path: "/api/v1/namespaces/ns1/pods/cc-" <> _} ->
            Agent.get_and_update(polls, fn
              [next | rest] -> {next, rest}
              [] -> {{404, %{"message" => "not found"}}, []}
            end)

          %{method: :delete} ->
            {200, %{}}
        end)

      refs = [%{name: "proxy", placement: :separate, grace: 45}]
      assert Kubernetes.destroy(handle(config, services: refs)) == :ok

      requests = Enum.map(log.(), &{&1.method, kind(&1.path), Path.basename(&1.path)})
      at = fn request -> for {^request, i} <- Enum.with_index(requests), do: i end

      # The sandbox itself has no drained sidecar: grace 0, no wait.
      assert hd(requests) == {:delete, :pods, "cc-#{@key}"}
      assert hd(log.()).query["gracePeriodSeconds"] == "0"

      # Terminating, then 404: two polls, and only then its policy.
      assert [first_poll, last_poll] = at.({:get, :pods, "cc-#{@key}-proxy"})
      assert [proxy_delete] = at.({:delete, :pods, "cc-#{@key}-proxy"})
      assert [policy_delete] = at.({:delete, :networkpolicies, "cc-#{@key}-proxy"})
      assert proxy_delete < first_poll and last_poll < policy_delete
    end

    test "with no drained service the order is unchanged: no wait, everything deleted" do
      {config, log} = recorder(fn _req -> {200, %{}} end)
      refs = [%{name: "browser", placement: :separate, grace: 0}]

      assert Kubernetes.destroy(handle(config, services: refs)) == :ok

      requests = log.()
      refute Enum.any?(requests, &(&1.method == :get)), "a grace-0 delete is never awaited"

      assert [{:pods, "cc-#{@key}"} | _] =
               for(
                 %{method: :delete, path: path} <- requests,
                 do: {kind(path), Path.basename(path)}
               )

      assert List.last(requests).path =~ ~r"/networkpolicies/cc-#{@key}-deny-all$"
    end

    test "a sandbox Pod whose delete failed keeps its deny-all" do
      {config, log} =
        recorder(fn
          %{method: :delete, path: "/api/v1/namespaces/ns1/pods/" <> _} ->
            {500, %{"message" => "etcd is unhappy"}}

          %{method: :delete} ->
            {200, %{}}
        end)

      assert Kubernetes.destroy(handle(config, services: [])) == :ok

      refute Enum.any?(log.(), &(&1.path =~ "networkpolicies")),
             "a Pod that may still run must keep its only NetworkPolicy"
    end

    test "the sweep leaves every object of a session whose Pod is still terminating" do
      old = System.system_time(:millisecond) - 600_000

      pods = [
        object("cc-ending", "ending", "sandbox", old, deleting: true),
        object("cc-ending-browser", "ending", "service", old),
        # No sandbox left, but its drained service Pod is still running out its grace.
        object("cc-draining-proxy", "draining", "service", old, deleting: true)
      ]

      by_kind = %{
        pods: pods,
        services: [],
        networkpolicies: [
          object("cc-ending-deny-all", "ending", "sandbox", nil, created: old),
          object("cc-draining-proxy", "draining", "service", old)
        ],
        configmaps: [],
        secrets: []
      }

      {config, log} =
        recorder(fn
          %{method: :get, path: path} ->
            {200, %{"items" => by_kind[kind(path)], "metadata" => %{}}}

          %{method: :delete} ->
            raise "nothing may be deleted"
        end)

      assert {:ok, 0} = Kubernetes.sweep_orphans([owner: "node-a"] ++ config)
      refute Enum.any?(log.(), &(&1.method == :delete))
    end

    test "PID 1 forwards SIGTERM to the CLI's process group" do
      [_shell, _flag, script] =
        hd(Kubernetes.pod_manifest(handle([]))["spec"]["containers"])["command"]

      # The launcher is a `setsid` session leader: its pid is the group's.
      assert script =~ "trap forward TERM"
      assert script =~ ~s{p=$(cat '/var/run/cc.launcher' 2>/dev/null)}
      assert script =~ ~s{kill -TERM -"$p"}
    end
  end

  describe "sweep window (blocker: a slow provision swept from under itself)" do
    test "every object provision/1 creates carries the session's sweep_after_ms" do
      {config, log} = recorder(&cluster/1)
      before = System.system_time(:millisecond)

      # Keyword lookups take the first entry, so the override goes in front.
      opts = [provision_timeout: 300_000] ++ provision_opts(config, @stack)
      assert {:ok, _handle} = Kubernetes.provision(opts)

      later = System.system_time(:millisecond)
      posts = for %{method: :post, body: body} <- log.(), do: body["metadata"]

      assert length(posts) == 11

      for metadata <- posts do
        stamp = metadata["annotations"]["crowd_control.sweep_after_ms"]
        assert is_binary(stamp), "#{metadata["name"]} has no sweep_after_ms"
        assert String.to_integer(stamp) in (before + 360_000)..(later + 360_000)
      end
    end

    test "the sweep waits for the later of its own floor and the object's stamp" do
      now = System.system_time(:millisecond)
      created = now - 200_000

      # Provisioned with `provision_timeout: 300_000` 200 s ago: past the
      # reaper's 180 s floor, not past its own 360 s.
      slow = now + 160_000
      # The same age, stamped by a session whose window has passed.
      done = now - 1_000

      by_kind = %{
        pods: [
          object("cc-slow-browser", "slow", "service", created, sweep_after: slow),
          object("cc-done-browser", "done", "service", created, sweep_after: done)
        ],
        services: [],
        networkpolicies: [
          object("cc-slow-deny-all", "slow", "sandbox", created, sweep_after: slow)
        ],
        configmaps: [],
        secrets: []
      }

      {config, log} =
        recorder(fn
          %{method: :get, path: path} ->
            {200, %{"items" => by_kind[kind(path)], "metadata" => %{}}}

          %{method: :delete} ->
            {200, %{}}
        end)

      assert {:ok, 1} = Kubernetes.sweep_orphans([owner: "node-a"] ++ config)

      assert [{:pods, "cc-done-browser"}] =
               for(
                 %{method: :delete, path: path} <- log.(),
                 do: {kind(path), Path.basename(path)}
               )
    end

    test ":orphan_margin_ms replaces the minute, in the stamp and in the sweep's floor" do
      {config, log} = recorder(&cluster/1)
      before = System.system_time(:millisecond)
      opts = [provision_timeout: 5_000, orphan_margin_ms: 1_000] ++ provision_opts(config, @stack)
      assert {:ok, _handle} = Kubernetes.provision(opts)

      for %{method: :post, body: %{"metadata" => metadata}} <- log.() do
        stamp = String.to_integer(metadata["annotations"]["crowd_control.sweep_after_ms"])
        assert stamp in (before + 6_000)..(System.system_time(:millisecond) + 6_000)
      end

      created = System.system_time(:millisecond) - 10_000

      by_kind = %{
        pods: [object("cc-gone-browser", "gone", "service", created)],
        services: [],
        networkpolicies: [],
        configmaps: [],
        secrets: []
      }

      {config, log} =
        recorder(fn
          %{method: :get, path: path} ->
            {200, %{"items" => by_kind[kind(path)], "metadata" => %{}}}

          %{method: :delete} ->
            {200, %{}}
        end)

      # 10 s old: young under the default 120 s + 60 s, past 5 s + 1 s.
      assert {:ok, 0} = Kubernetes.sweep_orphans([owner: "node-a"] ++ config)

      assert {:ok, 1} =
               Kubernetes.sweep_orphans(
                 [owner: "node-a", provision_timeout: 5_000, orphan_margin_ms: 1_000] ++ config
               )

      assert [_one_delete] = for(%{method: :delete} = req <- log.(), do: req)
    end

    test "a deny-all gone before the sandbox Pod fails the provision and rolls back" do
      {config, log} =
        recorder(fn
          %{method: :get, path: "/apis/networking.k8s.io/v1/namespaces/ns1/networkpolicies/" <> _} ->
            {404, %{"message" => "not found"}}

          req ->
            cluster(req)
        end)

      assert Kubernetes.provision(provision_opts(config, @stack)) ==
               {:error, {:k8s, {:policy_missing, "cc-#{@key}-deny-all"}}}

      assert_rolled_back(log.())
    end
  end

  describe "service readiness (blocker: a sandbox beside a dead browser)" do
    test "an ImagePullBackOff service fails the provision, and nothing is left" do
      {config, log} =
        recorder(fn
          %{method: :get, path: "/api/v1/namespaces/ns1/pods", query: query} = req ->
            if query["fieldSelector"] =~ "-browser",
              do: {200, %{"items" => [pulling_pod()], "metadata" => %{"resourceVersion" => "1"}}},
              else: cluster(req)

          %{method: :get, path: "/api/v1/namespaces/ns1/pods/cc-" <> name} = req ->
            if String.ends_with?(String.trim_trailing(name, "/"), "-browser"),
              do: {200, pulling_pod()},
              else: cluster(req)

          req ->
            cluster(req)
        end)

      assert Kubernetes.provision(provision_opts(config, @stack)) ==
               {:error, {:k8s, {:service_not_ready, {"browser", "ImagePullBackOff"}}}}

      assert_rolled_back(log.())
    end
  end

  describe "externals (blocker: sandbox egress through an {:external, _})" do
    test "an ip_block the sandbox reaches is private or narrow" do
      too_broad = fn cidr ->
        normalize([%{@aggregator | placement: {:external, %{ip_block: cidr}}}])
      end

      for cidr <- ["0.0.0.0/0", "::/0", "8.0.0.0/8", "2001:db8::/48", "172.0.0.0/8"] do
        assert too_broad.(cidr) == {:error, {:k8s, {:external_too_broad, {"aggregator", cidr}}}}
      end

      for cidr <- [
            "10.0.0.0/8",
            "172.20.0.0/16",
            "192.168.4.0/24",
            "100.64.0.0/10",
            "fd00::/8",
            "203.0.113.0/24",
            "203.0.113.7/32",
            "2001:db8:0:100::/56"
          ] do
        assert {:ok, _} = too_broad.(cidr)
      end
    end

    test "an external runs nothing, so it has no egress to declare" do
      assert normalize([%{@aggregator | egress: :allow}]) ==
               {:error, {:k8s, {:external_egress_forbidden, "aggregator"}}}
    end

    test "kube-dns needs allow_dns: true, by port or by namespace" do
      {:external, target} = @aggregator.placement
      dns = %{@aggregator | ports: [53]}

      assert normalize([dns]) ==
               {:error, {:k8s, {:external_dns_not_declared, {"aggregator", 53}}}}

      kube_system = %{
        @aggregator
        | placement:
            {:external,
             %{target | namespace_selector: %{"kubernetes.io/metadata.name" => "kube-system"}}}
      }

      assert normalize([kube_system]) ==
               {:error, {:k8s, {:external_dns_not_declared, {"aggregator", "kube-system"}}}}

      declared = %{dns | placement: {:external, Map.put(target, :allow_dns, true)}}
      assert {:ok, _} = normalize([declared])

      # Refused before the first request.
      assert Kubernetes.provision(provision_opts(fn _ -> raise "no request" end, [dns])) ==
               {:error, {:k8s, {:external_dns_not_declared, {"aggregator", 53}}}}
    end

    test "a CIDR prefix must fit its family, and an alias host must be DNS-1123" do
      for target <- [
            %{ip_block: "10.0.0.0/33"},
            %{ip_block: "fd00::/129"},
            %{ip_block: "10.0.0.0/-1"},
            %{ip_block: "10.0.0.0/8", except: ["10.1.0.0/40"]},
            %{ip_block: "10.0.0.0/8", host: "Not_A_Host", ip: "10.0.0.1"},
            %{ip_block: "10.0.0.0/8", allow_dns: "yes"}
          ] do
        assert normalize([%{@aggregator | placement: {:external, target}}]) ==
                 {:error, {:k8s, {:bad_external, "aggregator"}}},
               inspect(target)
      end
    end

    test "the LogShipper refuses an aggregator provision/1 would" do
      shipper = fn aggregator ->
        LogShipper.services(
          placement: :pod,
          sink: {:vector, address: "10.96.0.9:6000"},
          aggregator: aggregator
        )
      end

      assert [_vector, _aggregator] = shipper.(%{ip_block: "10.96.0.9/32"})

      assert_raise ArgumentError, ~r/external_too_broad/, fn ->
        shipper.(%{ip_block: "0.0.0.0/0"})
      end

      assert_raise ArgumentError, ~r/external_dns_not_declared/, fn ->
        shipper.(%{namespace_selector: %{"kubernetes.io/metadata.name" => "kube-system"}})
      end
    end
  end

  defp container(pod) do
    [container] = pod["spec"]["containers"]
    container
  end

  defp security(ctx, spec) do
    {:ok, [service]} = Services.normalize([services: [spec]], ctx)
    container(Services.pod_manifest(ctx, service, []))["securityContext"]
  end

  # Nothing the sandbox needs was POSTed, and everything that was is DELETEd.
  defp assert_rolled_back(requests) do
    created = for %{method: :post, body: body} <- requests, do: body["metadata"]["name"]
    deleted = for %{method: :delete, path: path} <- requests, do: Path.basename(path)

    refute "cc-#{@key}" in created, "the sandbox Pod must not be created after a failure"
    assert created != []

    for name <- created do
      assert name in deleted, "#{name} was created and never deleted"
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

  defp cluster(%{
         method: :get,
         path: "/apis/networking.k8s.io/v1/namespaces/ns1/networkpolicies/" <> name
       }),
       do: {200, %{"metadata" => %{"name" => name}}}

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

  defp terminating_pod(name) do
    %{
      "metadata" => %{"name" => name, "deletionTimestamp" => "2026-11-02T00:00:00Z"},
      "status" => %{"phase" => "Running"}
    }
  end

  defp pulling_pod do
    %{
      "metadata" => %{"name" => "cc-#{@key}-browser"},
      "status" => %{
        "phase" => "Pending",
        "containerStatuses" => [
          %{"state" => %{"waiting" => %{"reason" => "ImagePullBackOff", "message" => "no"}}}
        ]
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
        "annotations" =>
          %{"crowd_control.owner" => Keyword.get(opts, :owner, "node-a")}
          |> then(
            &if opts[:sweep_after],
              do: Map.put(&1, "crowd_control.sweep_after_ms", to_string(opts[:sweep_after])),
              else: &1
          )
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
      |> then(
        &if opts[:deleting],
          do: Map.put(&1, "deletionTimestamp", "2026-11-02T00:00:00Z"),
          else: &1
      )

    %{"metadata" => metadata, "status" => %{"phase" => Keyword.get(opts, :phase, "Running")}}
  end

  defp kind(path) do
    cond do
      path =~ "/configmaps" -> :configmaps
      path =~ "/secrets" -> :secrets
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
