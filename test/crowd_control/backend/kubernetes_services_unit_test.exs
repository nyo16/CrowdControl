defmodule CrowdControl.Backend.KubernetesServicesUnitTest do
  # Hermetic: the version lookup, the ConfigMap resource and the delete grace
  # are answered by a `:req_adapter` recorder; the manifests are pure.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Backend.Kubernetes.Drain
  alias CrowdControl.Backend.Kubernetes.Files
  alias CrowdControl.Service

  doctest CrowdControl.Backend.Kubernetes.Drain
  doctest CrowdControl.Backend.Kubernetes.Files

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
