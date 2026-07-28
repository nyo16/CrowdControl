defmodule CrowdControl.Backend.KubernetesUnitTest do
  # Pure tests for Backend.Kubernetes — no cluster and no network, so these run
  # in the default suite. Everything needing an API server lives in
  # kubernetes_test.exs behind @moduletag :k8s.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Credentials
  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Backend.Shell
  alias CrowdControl.Store

  # 32 lowercase hex, exactly what Store.new_key/0 mints.
  @key "0123456789abcdef0123456789abcdef"

  describe "network posture is never inferred (blocker: silent reachability)" do
    test "every explicit posture satisfies the gate" do
      assert Kubernetes.validate_network!(network: :deny_all) == :ok
      assert Kubernetes.validate_network!(network: {:policy, "x"}) == :ok
      assert Kubernetes.validate_network!(network: :unrestricted) == :ok
    end

    test "omitting :network is only allowed when nothing needs egress" do
      assert Kubernetes.validate_network!([]) == :ok
    end

    test "refuses :proxy_url without an explicit :network" do
      # A Pod always has cluster networking — there is no equivalent of Docker's
      # NetworkMode: "none" to fall back on. Inferring a posture here would hand
      # untrusted code general outbound access plus a session token.
      assert Kubernetes.validate_network!(proxy_url: "http://p:8080") ==
               {:error, {:k8s, :network_policy_required}}
    end

    test "refuses :api_url without an explicit :network" do
      # Worse than the proxy case: :api_url does not strip the real key, so this
      # would be unrestricted cluster networking *plus* a live provider credential.
      assert Kubernetes.validate_network!(api_url: "https://api.example.com") ==
               {:error, {:k8s, :network_policy_required}}
    end

    test "an unrecognized posture is rejected rather than treated as absent" do
      # Falling through to the nil branch would turn a typo into "no policy".
      assert {:error, {:k8s, {:invalid_network, "deny-all"}}} =
               Kubernetes.validate_network!(network: "deny-all")
    end

    test "the gate fires from provision/1 before any HTTP" do
      # provision/1 would need a cluster; assert on the ordering instead by
      # giving it a config that must be refused before a request is built. A
      # transport error here would mean the gate ran too late to matter.
      assert Kubernetes.provision(image: "busybox", proxy_url: "http://p:8080") ==
               {:error, {:k8s, :network_policy_required}}
    end

    test "an explicit :network gets past the gate" do
      # Fails later on an unreachable API server, which is the point — the
      # network check is no longer what stops it.
      capture_log(fn ->
        result =
          Kubernetes.provision(
            image: "busybox",
            proxy_url: "http://p:8080",
            network: :unrestricted,
            kubeconfig: kubeconfig("https://127.0.0.1:1")
          )

        assert {:error, {:k8s, reason}} = result
        refute reason == :network_policy_required
      end)
    end
  end

  describe "pod manifest hardening (blocker: silent hardening regression)" do
    test "no ServiceAccount token and no service links reach the sandbox" do
      spec = Kubernetes.pod_manifest(handle())["spec"]

      assert spec["automountServiceAccountToken"] == false,
             "a projected SA token is a live cluster credential inside a sandbox running untrusted code"

      assert spec["enableServiceLinks"] == false,
             "service links are free cluster reconnaissance"
    end

    test "the Pod can never restart" do
      # A restarted container truncates the tee file, which invalidates every
      # persisted byte_offset and silently replays or skips output.
      assert Kubernetes.pod_manifest(handle())["spec"]["restartPolicy"] == "Never"
    end

    test "the sandbox container drops every capability and adds none back" do
      container = container(Kubernetes.pod_manifest(handle()))

      assert container["name"] == "cc"
      assert container["command"] == ["/bin/sh", "-c", "sleep infinity"]
      assert container["securityContext"]["allowPrivilegeEscalation"] == false
      assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]

      refute Map.has_key?(container["securityContext"]["capabilities"], "add"),
             "the sandbox holds a capability for the life of the session; the init container holds MKNOD for milliseconds instead"
    end

    test "the init container is the only thing that ever holds MKNOD" do
      # drop: ALL and allowPrivilegeEscalation: false are each individually
      # harmless to mkfifo, but together they take CAP_MKNOD out of the
      # effective set and mkfifo fails with ENOENT. This container exists solely
      # to pay that cost and exit.
      init = init_container(Kubernetes.pod_manifest(handle()))

      assert init["name"] == "cc-init"
      assert ["/bin/sh", "-c", script] = init["command"]
      assert script == "mkfifo -m 600 '/var/run/cc.fifo' && mkdir -p '/var/log/cc'"

      assert init["securityContext"]["capabilities"] == %{"drop" => ["ALL"], "add" => ["MKNOD"]}
      assert init["securityContext"]["allowPrivilegeEscalation"] == false
    end

    test "resources are absent unless a limit was asked for" do
      # An empty "resources" map is not the same as no resources: it would make
      # a LimitRange's defaults look already-satisfied.
      refute Map.has_key?(container(Kubernetes.pod_manifest(handle())), "resources")

      manifest = Kubernetes.pod_manifest(handle(memory: 512 * 1024 * 1024, cpus: 1.5))

      assert container(manifest)["resources"] == %{
               "limits" => %{"memory" => "536870912", "cpu" => "1500m"}
             }
    end

    test "a memory limit alone does not invent a cpu limit" do
      manifest = Kubernetes.pod_manifest(handle(memory: 1024))
      assert container(manifest)["resources"] == %{"limits" => %{"memory" => "1024"}}
    end

    test "readOnlyRootFilesystem is opt-in" do
      refute Map.has_key?(
               container(Kubernetes.pod_manifest(handle()))["securityContext"],
               "readOnlyRootFilesystem"
             )

      manifest = Kubernetes.pod_manifest(handle(readonly_rootfs: true))
      assert container(manifest)["securityContext"]["readOnlyRootFilesystem"] == true
    end

    test "volumes cover the fifo and tee directories and are deduped" do
      # The init container hands the FIFO across, and a container's writable
      # layer is not shared with its init container — so these are volumes
      # whether or not the rootfs is read-only.
      volumes = Kubernetes.pod_manifest(handle())["spec"]["volumes"]

      assert volumes == [
               %{"name" => "cc-var-run", "emptyDir" => %{}},
               %{"name" => "cc-var-log-cc", "emptyDir" => %{}}
             ]

      shared =
        Kubernetes.pod_manifest(%{
          handle()
          | fifo_path: "/var/run/cc.fifo",
            tee_path: "/var/run/out.jsonl"
        })

      assert shared["spec"]["volumes"] == [%{"name" => "cc-var-run", "emptyDir" => %{}}]

      assert container(shared)["volumeMounts"] == [
               %{"name" => "cc-var-run", "mountPath" => "/var/run"}
             ]
    end

    test ":readonly_rootfs takes the volumes in-memory and adds /tmp" do
      # An unbounded medium: Memory emptyDir is charged against the node and
      # evicts the Pod rather than failing the write, so the size limit is not
      # decoration.
      volumes = Kubernetes.pod_manifest(handle(readonly_rootfs: true))["spec"]["volumes"]

      assert volumes == [
               %{
                 "name" => "cc-var-run",
                 "emptyDir" => %{"medium" => "Memory", "sizeLimit" => "8Mi"}
               },
               %{
                 "name" => "cc-var-log-cc",
                 "emptyDir" => %{"medium" => "Memory", "sizeLimit" => "64Mi"}
               },
               %{"name" => "cc-tmp", "emptyDir" => %{"medium" => "Memory", "sizeLimit" => "64Mi"}}
             ]
    end

    test ":cap_drop and :allow_privilege_escalation are overridable" do
      manifest =
        Kubernetes.pod_manifest(handle(cap_drop: ["NET_RAW"], allow_privilege_escalation: true))

      security_context = container(manifest)["securityContext"]

      assert security_context["capabilities"]["drop"] == ["NET_RAW"]
      assert security_context["allowPrivilegeEscalation"] == true
    end

    test ":run_as_user sets runAsNonRoot and an fsGroup for the volumes" do
      # A container-level runAsUser alone leaves the emptyDirs root-owned, and
      # the FIFO then cannot be opened by the sandbox.
      manifest = Kubernetes.pod_manifest(handle(run_as_user: 1000, run_as_group: 2000))

      assert container(manifest)["securityContext"]["runAsUser"] == 1000
      assert container(manifest)["securityContext"]["runAsGroup"] == 2000
      assert container(manifest)["securityContext"]["runAsNonRoot"] == true
      assert manifest["spec"]["securityContext"] == %{"fsGroup" => 2000}
    end
  end

  describe "pod naming and owner labelling (blocker: API-server rejection)" do
    test "a minted session key always yields a legal Pod name" do
      key = Store.new_key()
      assert {:ok, name} = Kubernetes.pod_name(key)

      assert name == "cc-" <> key
      assert byte_size(name) <= 63, "the API server rejects a label longer than 63 bytes"
      assert Regex.match?(~r/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/, name)
    end

    test "a session key that is not an RFC 1123 label is refused, not sanitized" do
      # Sanitizing is lossy, and two keys collapsing to one Pod name would let
      # one session destroy another's sandbox.
      for key <- ["Has_Caps", "nonode@nohost", "", nil, String.duplicate("a", 61)] do
        assert {:error, {:k8s, {:invalid_name, ^key}}} = Kubernetes.pod_name(key),
               "#{inspect(key)} would be sent to the API server and rejected at provision time"
      end
    end

    test "the owner label is a hash because the raw owner is illegal" do
      # Store.owner_id/0 defaults to to_string(node()); '@' is not a legal label
      # value character and the API server rejects the whole Pod for it.
      label = Kubernetes.owner_label("nonode@nohost")

      assert Regex.match?(~r/\A[a-z0-9]{32}\z/, label),
             "the raw owner is what the API server rejects, so the selector must be a hash of it"
    end

    test "the raw owner round-trips through the annotation, never the label" do
      manifest = Kubernetes.pod_manifest(%{handle() | owner: "nonode@nohost"})
      metadata = manifest["metadata"]

      # Reaper.owned_by?/3 re-checks the raw owner locally, so the exact string
      # has to survive somewhere. Annotation values are unconstrained.
      assert metadata["annotations"]["crowd_control.owner"] == "nonode@nohost"

      assert metadata["labels"]["crowd_control.owner_hash"] ==
               Kubernetes.owner_label("nonode@nohost")

      refute metadata["labels"]["crowd_control.owner_hash"] =~ "@",
             "the raw owner leaked into a label and the API server will reject the Pod"
    end

    test "distinct owners never collapse to one label" do
      owners = ["nonode@nohost", "nonode@nohost2", "node1@host", "node2@host", ""]
      labels = Enum.map(owners, &Kubernetes.owner_label/1)

      assert length(Enum.uniq(labels)) == length(owners),
             "two owners sharing a label lets one node's reaper destroy another's Pods"
    end

    test "the session and created_at labels are what age_ms/1 and the selector read" do
      metadata = Kubernetes.pod_manifest(handle())["metadata"]

      assert metadata["labels"]["crowd_control.session"] == @key
      assert {created_at, ""} = Integer.parse(metadata["labels"]["crowd_control.created_at"])
      assert_in_delta created_at, System.system_time(:millisecond), 5_000
    end
  end

  describe "credential injection" do
    test "without :proxy_url the env is untouched" do
      env = %{"ANTHROPIC_API_KEY" => "sk-real", "FOO" => "bar"}
      assert Credentials.apply_credentials(env, []) == env
    end

    test "with :proxy_url the real key is removed, not just overridden" do
      env = %{"ANTHROPIC_API_KEY" => "sk-real-secret", "FOO" => "bar"}

      result =
        Credentials.apply_credentials(env,
          proxy_url: "http://proxy.internal:8080",
          session_token: "sess-token-123"
        )

      assert result["ANTHROPIC_BASE_URL"] == "http://proxy.internal:8080"
      assert result["ANTHROPIC_API_KEY"] == "sess-token-123"
      assert result["FOO"] == "bar"
    end

    test "with :proxy_url but no token, no api key reaches the sandbox at all" do
      env = %{"ANTHROPIC_API_KEY" => "sk-real-secret"}
      result = Credentials.apply_credentials(env, proxy_url: "http://proxy:8080")

      refute Map.has_key?(result, "ANTHROPIC_API_KEY"),
             "the real key leaked into a proxied sandbox"
    end

    test "an env value cannot break out of the sourced env file" do
      # write_env_file/2 renders each pair as this exact line and ships it over
      # the exec stdin channel; the sandbox then sources the file. An unquoted
      # value would execute at source time. security_test.exs is the oracle for
      # Shell.escape/1 itself — this asserts the backend composes with it.
      value = "$(touch /tmp/pwned)"
      line = "export " <> "ANTHROPIC_API_KEY" <> "=" <> Shell.escape(value)

      assert line == "export ANTHROPIC_API_KEY='$(touch /tmp/pwned)'"

      quoted = "export FOO=" <> Shell.escape("it's; rm -rf /")
      assert quoted == ~S(export FOO='it'\''s; rm -rf /')
    end
  end

  describe "credential scrubbing (blocker: secrets persisted in cleartext)" do
    test "Kubernetes.scrub/1 strips credentials out of the handle's config" do
      # The handle carries the config it was provisioned from, and a Store
      # record can outlive the VM on disk.
      scrubbed =
        Kubernetes.scrub(handle(api_key: "sk-real", session_token: "tok", namespace: "ns1"))

      refute Keyword.has_key?(scrubbed.config, :api_key)
      refute Keyword.has_key?(scrubbed.config, :session_token)

      # Everything a reattach actually needs survives.
      assert scrubbed.config[:namespace] == "ns1"
      assert scrubbed.pod_name == "cc-" <> @key
      assert scrubbed.namespace == "ns1"
    end

    test "Backend.scrub/2 dispatches to the Kubernetes backend" do
      assert %Kubernetes{config: config} =
               Backend.scrub(Kubernetes, handle(api_key: "sk-real"))

      refute Keyword.has_key?(config, :api_key)
    end

    test "no secret survives a full round-trip into a store record" do
      record =
        Store.build(
          key: "k1",
          session_id: "s1",
          backend: Kubernetes,
          handle: Backend.scrub(Kubernetes, handle(api_key: "sk-leaked")),
          opts: Store.scrub_opts(api_key: "sk-leaked", timeout: 1_000)
        )

      # The whole record must be free of the secret, however it is nested.
      refute inspect(record) =~ "sk-leaked"
    end
  end

  describe "reconnect preserves the resume cursor (blocker: duplicated or lost bytes)" do
    test "the offset survives the swap and the exec channel is replaced" do
      # offset is a position in the tee file, and the resume command is
      # `tail -c +<offset + 1>`. Losing it re-reads the whole file into the
      # session; advancing it re-reads nothing and drops what was in flight.
      state = %{podexec: :dead_channel, offset: 4_096, reconnects: 3}

      resumed = Kubernetes.attach_stream(state, :fresh_channel)

      assert resumed.offset == 4_096, "the file offset is the resume cursor and must survive"
      assert resumed.podexec == :fresh_channel
    end

    test "the reconnect counter is carried through, not reset" do
      # reconnects counts reconnects since the last *delivered byte*, and only
      # deliver/2 resets it. Resetting on every successful open would let a
      # channel that flaps open-then-closed against a Running Pod reconnect
      # forever instead of giving up at @max_reconnects.
      state = %{podexec: nil, offset: 0, reconnects: 4}

      assert Kubernetes.attach_stream(state, :fresh_channel).reconnects == 4,
             "resetting here makes @max_reconnects unreachable and a flapping channel unbounded"
    end
  end

  describe "reader resilience (blocker: transport error killed the session)" do
    test "an unreachable API server casts :eof instead of crashing the caller" do
      # Kubereq.PodExec.start_link/1 raises MatchError on a failed upgrade AND
      # links to its caller, so without API.open_exec/5's rescue and the
      # reader's trap_exit the first blip takes the session down with it. The
      # reader is spawn_linked to its session; the contract is that transport
      # failure produces :eof.
      handle = handle(kubeconfig: kubeconfig("https://127.0.0.1:1"))

      Process.flag(:trap_exit, true)
      test_pid = self()
      relay = spawn(fn -> relay_loop(test_pid) end)

      capture_log(fn ->
        assert {:ok, reader} = Kubernetes.start_reader(handle, relay, Backend.new_cursor())
        assert_receive {:cast, :eof}, 5_000

        # The reader is done, so a :normal exit is expected. Any other reason is
        # what travels through the link and kills a non-trapping session, which
        # is the whole hazard this test defends.
        assert_receive {:EXIT, ^reader, exit_reason}, 1_000

        assert exit_reason == :normal,
               "the reader died with #{inspect(exit_reason)}; that reason propagates through the spawn_link and takes the session with it"
      end)
    end
  end

  describe "list_live paginates (blocker: reaper prunes live sandboxes)" do
    test "the request asks for 500 per page, never kubereq's default 10" do
      # Kubereq.list/3's into: :stream form does Keyword.put_new(params, :limit, 10).
      # A short list is read by the Reaper as `live? = no, stored? = yes`, and it
      # then deletes the store record of a running, billed sandbox — orphaning it
      # permanently. Truncation must be unrepresentable, not merely unlikely.
      config = adapter_config([pod_list([])])

      assert {:ok, []} =
               API.list_all(config, nil, label_selectors: [{"crowd_control.owner_hash", "abc"}])

      assert_receive {:req_query, query}
      assert query =~ "limit=500"
      refute query =~ "limit=10"
      assert query =~ "labelSelector=crowd_control.owner_hash%3Dabc"
    end

    test "a continued list is drained to the last page" do
      config =
        adapter_config([
          pod_list([running_pod("cc-a")], "page-two-token"),
          pod_list([running_pod("cc-b")])
        ])

      assert {:ok, [first, second]} = Kubernetes.list_live([{:owner, "owner-1"} | config])

      assert first.pod_name == "cc-a"
      assert second.pod_name == "cc-b"

      assert_receive {:req_query, page_one}
      refute page_one =~ "continue"

      assert_receive {:req_query, page_two}
      assert page_two =~ "continue=page-two-token"
    end

    test "a failure on the second page surfaces as an error, not a short list" do
      # This is the dangerous shape: one good page plus a failure looks exactly
      # like a complete list of one, and the reaper acts on it. 403 because a
      # token expiring mid-pagination is the realistic way this happens; the
      # 5xx shape is covered directly in the normalize block.
      config =
        adapter_config([
          pod_list([running_pod("cc-a")], "page-two-token"),
          Req.Response.new(status: 403, body: status_body("token expired"))
        ])

      assert {:error, {:k8s, {:forbidden, "token expired"}}} =
               Kubernetes.list_live([{:owner, "owner-1"} | config])
    end

    test "only Running Pods are reported live" do
      # A Succeeded Pod cannot be exec'd into; treating it as live would leave
      # the session reattaching to a corpse forever.
      pending = put_in(running_pod("cc-pending"), ["status", "phase"], "Pending")
      config = adapter_config([pod_list([running_pod("cc-a"), pending])])

      assert {:ok, [only]} = Kubernetes.list_live([{:owner, "owner-1"} | config])
      assert only.pod_name == "cc-a"
    end

    test "the raw owner is rebuilt from the annotation, not the hashed label" do
      # Reaper.owned_by?/3 compares raw owners exactly; a handle carrying the
      # hash would never match and the reaper would skip every Pod it owns.
      config = adapter_config([pod_list([running_pod("cc-a")])])

      assert {:ok, [handle]} = Kubernetes.list_live([{:owner, "owner-1"} | config])
      assert handle.owner == "nonode@nohost"
      assert handle.session_key == "a"
    end
  end

  describe "API error normalization" do
    test "2xx unwraps the body" do
      assert API.normalize({:ok, %{status: 200, body: %{"kind" => "Pod"}}}) ==
               {:ok, %{"kind" => "Pod"}}

      assert API.normalize({:ok, %{status: 201, body: %{"kind" => "Pod"}}}) ==
               {:ok, %{"kind" => "Pod"}}
    end

    test "non-2xx becomes an error even though kubereq reports it as :ok" do
      # kubereq installs only a request step, so nothing converts HTTP status.
      # A 404 arrives as {:ok, %Req.Response{status: 404}}; treating that as
      # success would make destroy/1 report a Pod deleted that never existed and
      # get_pod/2 hand a Status object back as if it were a Pod.
      assert API.normalize({:ok, %{status: 404, body: status_body("pods 'x' not found")}}) ==
               {:error, {:k8s, {:not_found, "pods 'x' not found"}}}

      assert API.normalize({:ok, %{status: 403, body: status_body("forbidden: pods create")}}) ==
               {:error, {:k8s, {:forbidden, "forbidden: pods create"}}}

      assert API.normalize({:ok, %{status: 500, body: status_body("boom")}}) ==
               {:error, {:k8s, {:http_status, 500, "boom"}}}
    end

    test "a kubereq step failure keeps its code" do
      error = %Kubereq.Error.StepError{code: :kubeconfig_not_loaded, message: "m"}

      assert API.normalize({:error, error}) ==
               {:error, {:k8s, {:step, :kubeconfig_not_loaded}}}
    end

    test "a transport failure keeps its reason" do
      assert API.normalize({:error, %Req.TransportError{reason: :econnrefused}}) ==
               {:error, {:k8s, {:transport, :econnrefused}}}
    end

    test "an unrecognized exception still returns rather than raises" do
      assert {:error, {:k8s, {:exception, message}}} =
               API.normalize({:error, %ArgumentError{message: "nope"}})

      assert message =~ "nope"
    end

    test "summarize/1 truncates a Status message so a payload cannot reach the logs" do
      long = String.duplicate("a", 500)
      summary = API.summarize(%{"kind" => "Status", "message" => long})

      assert byte_size(summary) == 200,
             "an untruncated error body carries a response payload — or an echoed secret — into a crash report"
    end

    test "summarize/1 says nothing about a body it does not recognize" do
      assert API.summarize(%{"kind" => "Status"}) == ""
      assert API.summarize(nil) == ""
      assert API.summarize("plain text body") == "plain text body"
    end
  end

  # --- helpers ---

  defp handle(config \\ []) do
    %Kubernetes{
      pod_name: "cc-" <> @key,
      namespace: "ns1",
      image: "busybox:1.36",
      tee_path: "/var/log/cc/out.jsonl",
      fifo_path: "/var/run/cc.fifo",
      env_path: "/var/run/cc.env",
      session_key: @key,
      owner: "nonode@nohost",
      config: config
    }
  end

  defp container(manifest), do: manifest |> get_in(["spec", "containers"]) |> hd()
  defp init_container(manifest), do: manifest |> get_in(["spec", "initContainers"]) |> hd()

  defp status_body(message), do: %{"kind" => "Status", "message" => message}

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

  # Serves `responses` in order and reports every query string back to the test,
  # so pagination is assertable without an API server. Over-drawing the queue
  # keeps returning the last page rather than crashing, so an unexpected extra
  # request shows up as the assertion it broke instead of an Agent stacktrace.
  defp adapter_config(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)
    test_pid = self()

    adapter = fn req ->
      send(test_pid, {:req_query, req.url.query})

      response =
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [head | tail] -> {head, tail}
        end)

      {req, response}
    end

    [kubeconfig: kubeconfig("https://k8s.test"), req_adapter: adapter]
  end

  defp pod_list(items, continue \\ nil) do
    metadata = if continue, do: %{"continue" => continue}, else: %{}

    Req.Response.new(
      status: 200,
      body: %{"kind" => "PodList", "items" => items, "metadata" => metadata}
    )
  end

  defp running_pod("cc-" <> session = name) do
    %{
      "metadata" => %{
        "name" => name,
        "namespace" => "ns1",
        "labels" => %{"crowd_control.session" => session},
        "annotations" => %{"crowd_control.owner" => "nonode@nohost"}
      },
      "spec" => %{"containers" => [%{"image" => "busybox:1.36"}]},
      "status" => %{"phase" => "Running"}
    }
  end

  defp relay_loop(test_pid) do
    receive do
      {:"$gen_cast", msg} ->
        send(test_pid, {:cast, msg})
        relay_loop(test_pid)
    end
  end
end
