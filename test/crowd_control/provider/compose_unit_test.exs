defmodule CrowdControl.Provider.ComposeUnitTest do
  # Hermetic: every Docker Engine API call and every agent call is answered by a
  # stub adapter, so these run in the default suite with no daemon. Everything
  # needing a live daemon lives in test/crowd_control/provider/compose_test.exs.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CrowdControl.Backend.Docker.HostConfig
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Compose

  # No @secret here and no setup mutating :sandboxd_secret: test_helper.exs sets
  # one for the whole suite. A per-module secret raced every other async module
  # deriving a token from it.
  @session "abcdef0123456789abcdef0123456789"
  @project "cc-abcdef0123456789abcdef0123456789"

  describe "gates run before any HTTP (blocker: rolling back four resources to report a typo)" do
    test "an adapter that raises is never reached by any gate" do
      # Each of these must be decided from the options alone. A stack is N
      # resources; a gate that ran after creation would have to unwind them.
      for opts <- [
            [session_key: nil],
            [image: nil],
            [project_name: "Not_A_Project"],
            [network: [internal: "yes"]],
            [volumes: [%{name: "bad name"}]],
            [services: [[name: "kw"]]],
            [services: [%{name: "PROXY", image: "i", egress: :none}]],
            [services: [%{name: "proxy", egress: :none}]],
            [services: [%{name: "proxy", image: "i"}]],
            [services: "not-a-list"],
            [services: [%{name: "a", image: "i", egress: :none, depends_on: ["nope"]}]],
            [ready: %{"nope" => %{test: ["CMD", "true"]}}]
          ] do
        assert {:error, {:compose, _}} = gate(opts)
      end
    end

    test "refuses without a session key, which the token is derived from" do
      assert {:error, {:compose, :session_key_required}} = gate(session_key: nil)
    end

    test "refuses without an image for the sandbox" do
      assert {:error, {:compose, :image_required}} = gate(image: nil)
    end

    test "refuses a project name the daemon would reject four calls later" do
      assert {:error, {:compose, {:bad_project_name, "Not_A_Project"}}} =
               gate(project_name: "Not_A_Project")
    end

    test "refuses a malformed :network" do
      assert {:error, {:compose, {:bad_network, _}}} = gate(network: [internal: "yes"])
      assert {:error, {:compose, {:bad_network, _}}} = gate(network: %{internal: true})
    end

    test "refuses a malformed volume declaration" do
      assert {:error, {:compose, {:bad_volume, _}}} = gate(volumes: [%{name: "bad name"}])
      assert {:error, {:compose, {:bad_volume, _}}} = gate(volumes: ["workspace"])
    end

    test "refuses a non-list :services rather than raising out of a gate" do
      assert {:error, {:compose, {:bad_option, {:services, "nope"}}}} = gate(services: "nope")
    end

    test "service specs must be maps, so scrub/1 can strip their env" do
      assert {:error, {:compose, {:bad_service, _}}} = gate(services: [[name: "proxy"]])
    end

    test "a service name must be usable as a DNS alias, since that is how it is addressed" do
      assert {:error, {:compose, {:bad_service_name, "PROXY"}}} =
               gate(services: [%{name: "PROXY", image: "i", egress: :none}])

      assert {:error, {:compose, {:bad_service_name, "-lead"}}} =
               gate(services: [%{name: "-lead", image: "i", egress: :none}])
    end

    test "a sidecar has no :image fallback, unlike the sandbox" do
      assert {:error, {:compose, {:image_required, "proxy"}}} =
               gate(services: [%{name: "proxy", egress: :none}])
    end

    test "an {:external, _} placement buys no image here: placement is ignored, so it is a container" do
      external = %{
        name: "aggregator",
        egress: :none,
        ports: [6000],
        placement: {:external, %{ip_block: "10.0.0.0/8"}}
      }

      assert {:error, {:compose, {:image_required, "aggregator"}}} = gate(services: [external])
    end

    test "refuses duplicate service names" do
      specs = [
        %{name: "proxy", image: "i", egress: :none},
        %{name: "proxy", image: "j", egress: :none}
      ]

      assert {:error, {:compose, {:duplicate_service, "proxy"}}} = gate(services: specs)
    end

    test "a declared service cannot take the forwarder's name, which is always synthesised" do
      assert {:error, {:compose, {:duplicate_service, "forwarder"}}} =
               gate(services: [%{name: "forwarder", image: "i", egress: :none}])
    end

    test "refuses a sandbox and forwarder with the same name" do
      assert {:error, {:compose, {:duplicate_service, "same"}}} =
               gate(sandbox_service: "same", forwarder_service: "same")
    end

    test "refuses a mount of an undeclared volume" do
      specs = [
        %{
          name: "proxy",
          image: "i",
          egress: :none,
          volumes: [%{name: "cache", target: "/cache"}]
        }
      ]

      assert {:error, {:compose, {:unknown_volume, "cache"}}} = gate(services: specs)
    end

    test "refuses a relative mount target" do
      specs = [
        %{name: "proxy", image: "i", egress: :none, volumes: [%{name: "c", target: "cache"}]}
      ]

      assert {:error, {:compose, {:bad_mount, {"proxy", _}}}} =
               gate(services: specs, volumes: [%{name: "c"}])
    end

    test "refuses a :ready entry naming no service" do
      assert {:error, {:compose, {:unknown_service, "nope"}}} =
               gate(ready: %{"nope" => %{test: ["CMD", "true"]}})
    end

    test "refuses a :ready spec Docker would accept but never report healthy for" do
      # A bare command or "NONE" leaves nothing for the poll to observe, and the
      # caller asked for readiness gating by writing the option at all.
      assert {:error, {:compose, {:bad_ready, "sandbox"}}} =
               gate(ready: %{"sandbox" => %{test: ["true"]}})

      assert {:error, {:compose, {:bad_ready, "sandbox"}}} =
               gate(ready: %{"sandbox" => %{test: ["NONE"]}})

      assert {:error, {:compose, {:bad_ready, "sandbox"}}} =
               gate(ready: %{"sandbox" => %{test: ["CMD"]}})
    end

    test "refuses a dependency on a service that does not exist" do
      specs = [%{name: "a", image: "i", egress: :none, depends_on: ["ghost"]}]

      assert {:error, {:compose, {:unknown_dependency, {"a", "ghost"}}}} = gate(services: specs)
    end

    test "refuses a dependency cycle rather than deadlocking the start loop" do
      specs = [
        %{name: "a", image: "i", egress: :none, depends_on: ["b"]},
        %{name: "b", image: "i", egress: :none, depends_on: ["a"]}
      ]

      assert {:error, {:compose, {:dependency_cycle, cycle}}} = gate(services: specs)
      assert Enum.sort(cycle) == ["a", "b"]
    end
  end

  describe "egress is never inferred (blocker: silent full internet for untrusted code)" do
    test "a sidecar must state its posture" do
      assert {:error, {:compose, {:egress_required, "proxy"}}} =
               gate(services: [%{name: "proxy", image: "i"}])
    end

    test "rejects an unknown :egress value rather than treating it as a default" do
      assert {:error, {:compose, {:bad_egress, {"proxy", :maybe}}}} =
               gate(services: [%{name: "proxy", image: "i", egress: :maybe}])
    end

    test "the sandbox can never be given egress" do
      # There is no legitimate reason: the whole construction exists so the
      # sandbox has no default route at all.
      assert {:error, {:compose, :sandbox_egress_forbidden}} =
               gate(services: [%{name: "sandbox", image: "i", egress: :allow}])
    end

    test "no NAT network is created when nothing asks for one" do
      {_handle, _endpoint, requests} = acquire!([])

      refute network_body(requests, "-egress")
    end

    test "a sidecar with :allow gets a NAT bridge, attached after create" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]
      {_handle, _endpoint, requests} = acquire!(services: specs)

      egress = network_body(requests, "-egress")
      assert egress["Name"] == @project <> "-egress"
      assert egress["Driver"] == "bridge"
      # A NAT bridge, deliberately: this is the sanctioned hole, and masquerade
      # is exactly what the publish network disables.
      refute Map.has_key?(egress, "Options")
      refute egress["Internal"]

      assert connect_body(requests, @project <> "-egress") == %{
               "Container" => "ctr-proxy",
               "EndpointConfig" => %{"Aliases" => ["proxy"]}
             }
    end

    test "the sandbox is never attached to the NAT bridge" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]
      {_handle, _endpoint, requests} = acquire!(services: specs)

      connects =
        for r <- requests,
            r.method == :post,
            String.ends_with?(r.path, "/connect"),
            do: {r.path, r.body["Container"]}

      refute {"/networks/#{@project}-egress/connect", "ctr-sandbox"} in connects
    end
  end

  describe "network shape (blocker: Internal:true and a published port on one container)" do
    test "the sandbox network is internal, which is the only structural egress block" do
      {_handle, _endpoint, requests} = acquire!([])
      sbx = network_body(requests, "-sbx")

      assert sbx["Name"] == @project <> "-sbx"
      assert sbx["Driver"] == "bridge"
      assert sbx["Internal"] == true
      refute Map.has_key?(sbx, "Options")
    end

    test "the publish network is non-internal but has masquerade disabled" do
      {_handle, _endpoint, requests} = acquire!([])
      pub = network_body(requests, "-pub")

      # Non-internal is forced: PortBindings are silently discarded on an
      # internal network. No SNAT is what keeps the forwarder off the internet.
      refute Map.has_key?(pub, "Internal")

      assert pub["Options"] == %{"com.docker.network.bridge.enable_ip_masquerade" => "false"}
    end

    test "network: [internal: false] is honoured, because it is explicit" do
      {_handle, _endpoint, requests} = acquire!(network: [internal: false, driver: "bridge"])

      assert network_body(requests, "-sbx")["Internal"] == false
    end

    test "extra sandbox network options are merged" do
      opts = [network: [options: %{"com.docker.network.driver.mtu" => "1400"}]]
      {_handle, _endpoint, requests} = acquire!(opts)

      assert network_body(requests, "-sbx")["Options"] == %{
               "com.docker.network.driver.mtu" => "1400"
             }
    end

    test "the sandbox publishes nothing at all" do
      {_handle, _endpoint, requests} = acquire!([])
      body = container_body(requests, "sandbox")

      # The daemon accepts both fields on an internal network with
      # `"Warnings": []` and binds nothing, then echoes PortBindings back. Not
      # sending them is the only way the absence is visible.
      refute Map.has_key?(body, "ExposedPorts")
      refute Map.has_key?(body["HostConfig"], "PortBindings")
      assert body["HostConfig"]["NetworkMode"] == @project <> "-sbx"
    end

    test "the forwarder publishes on loopback only" do
      {_handle, _endpoint, requests} = acquire!([])
      body = container_body(requests, "forwarder")

      assert body["ExposedPorts"] == %{"8080/tcp" => %{}}

      # Omitting HostIp yields TWO bindings, IPv4 and IPv6, on every interface.
      assert body["HostConfig"]["PortBindings"] == %{
               "8080/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => "0"}]
             }

      assert body["HostConfig"]["NetworkMode"] == @project <> "-pub"
    end

    test "the forwarder's second network is attached by /connect after create, not at create" do
      {_handle, _endpoint, requests} = acquire!([])

      # Create-time dual attach is HTTP 400 below API 1.44, and daemons still
      # report MinAPIVersion 1.40.
      assert container_body(requests, "forwarder")["NetworkingConfig"] == %{
               "EndpointsConfig" => %{(@project <> "-pub") => %{"Aliases" => ["forwarder"]}}
             }

      assert connect_body(requests, @project <> "-sbx") == %{
               "Container" => "ctr-forwarder",
               "EndpointConfig" => %{"Aliases" => ["forwarder"]}
             }

      create = index(requests, :post, "/containers/create", "forwarder")
      connect = index(requests, :post, "/networks/#{@project}-sbx/connect")
      start = index(requests, :post, "/containers/ctr-forwarder/start")

      assert create < connect and connect < start
    end

    test "the forwarder command is concurrency-safe and addresses the sandbox by alias" do
      {_handle, _endpoint, requests} = acquire!([])
      body = container_body(requests, "forwarder")

      # `busybox nc -e` serves one connection at a time and dropped two of three
      # concurrent requests; the session holds a chunked stream open throughout.
      assert body["Entrypoint"] == ["socat"]
      assert body["Cmd"] == ["TCP-LISTEN:8080,fork,reuseaddr", "TCP:sandbox:8080"]

      # An IP would be wrong: they are reassigned on every start.
      refute Enum.any?(body["Cmd"], &(&1 =~ ~r/\d+\.\d+\.\d+\.\d+/))
    end

    test "every service is aliased on the sandbox network by its own name" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :none}]
      {_handle, _endpoint, requests} = acquire!(services: specs)

      assert container_body(requests, "proxy")["NetworkingConfig"] == %{
               "EndpointsConfig" => %{(@project <> "-sbx") => %{"Aliases" => ["proxy"]}}
             }

      assert container_body(requests, "sandbox")["NetworkingConfig"] == %{
               "EndpointsConfig" => %{(@project <> "-sbx") => %{"Aliases" => ["sandbox"]}}
             }
    end

    test "a custom :agent_port reaches every place that has to agree on it" do
      {_handle, endpoint, requests} = acquire!(agent_port: 9999)

      assert container_body(requests, "forwarder")["ExposedPorts"] == %{"9999/tcp" => %{}}

      assert container_body(requests, "forwarder")["Cmd"] == [
               "TCP-LISTEN:9999,fork,reuseaddr",
               "TCP:sandbox:9999"
             ]

      assert "CC_SANDBOXD_PORT=9999" in container_body(requests, "sandbox")["Env"]
      assert endpoint.base_url == "http://127.0.0.1:32768"
    end

    test "the host port comes from NetworkSettings, and an unusable one is a hard error" do
      # HostConfig.PortBindings echoes the request even when the binding was
      # discarded, so a null Ports entry is the only place the truth shows up.
      routes = %{
        {:get, "/containers/ctr-forwarder/json"} =>
          {200, %{"NetworkSettings" => %{"Ports" => %{"8080/tcp" => nil}}}}
      }

      assert {{:error, {:docker, :agent_port_not_published}}, requests} = acquire(routes: routes)

      # And the stack it had already built is gone.
      assert "/networks/#{@project}-sbx" in paths(requests, :delete)
    end
  end

  describe "labels (blocker: a compose CLI that decides it owns a live stack)" do
    test "crowd_control labels are on every resource" do
      opts = [volumes: [%{name: "workspace"}]]
      {handle, _endpoint, requests} = acquire!(opts)

      bodies = [
        network_body(requests, "-sbx"),
        network_body(requests, "-pub"),
        volume_body(requests),
        container_body(requests, "sandbox"),
        container_body(requests, "forwarder")
      ]

      for body <- bodies do
        labels = body["Labels"]
        assert labels["crowd_control.session"] == @session
        assert labels["crowd_control.owner"] == "node-a"
        assert labels["crowd_control.agent"] == "sandboxd"
        assert {ms, ""} = Integer.parse(labels["crowd_control.created_at"])
        assert ms == handle.created_at
        assert labels["com.docker.compose.project"] == @project
      end
    end

    test "containers carry the labels docker compose ps needs to render a row" do
      {_handle, _endpoint, requests} = acquire!([])
      labels = container_body(requests, "sandbox")["Labels"]

      assert labels["com.docker.compose.service"] == "sandbox"
      assert labels["com.docker.compose.container-number"] == "1"
      assert labels["com.docker.compose.oneoff"] == "False"
    end

    test "config-hash and version are deliberately absent from every resource" do
      # Emitting them tells the compose CLI it owns the stack; a `docker compose
      # up` in the same project would then decide the config drifted and
      # recreate every container underneath a live session.
      opts = [volumes: [%{name: "workspace"}]]
      {_handle, _endpoint, requests} = acquire!(opts)

      for request <- requests, is_map(request.body), labels = request.body["Labels"], labels do
        refute Map.has_key?(labels, "com.docker.compose.config-hash")
        refute Map.has_key?(labels, "com.docker.compose.version")
      end
    end

    test "networks and volumes are tagged with their compose-relative names" do
      {_handle, _endpoint, requests} = acquire!(volumes: [%{name: "workspace"}])

      assert network_body(requests, "-sbx")["Labels"]["com.docker.compose.network"] == "sbx"
      assert network_body(requests, "-pub")["Labels"]["com.docker.compose.network"] == "pub"
      assert volume_body(requests)["Labels"]["com.docker.compose.volume"] == "workspace"
    end

    test "the token is in no label, no name, and no URL" do
      {_handle, _endpoint, requests} = acquire!(volumes: [%{name: "workspace"}])
      token = Provider.token(@session)

      for request <- requests do
        refute request.path =~ token
        refute inspect(request.query) =~ token
        refute inspect(request.body["Labels"] || %{}) =~ token
        refute to_string(request.body["Name"] || "") =~ token
      end
    end
  end

  describe "agent credentials (blocker: a token in argv, a label, or a log)" do
    test "the token reaches the sandbox through the create API's Env array" do
      {_handle, _endpoint, requests} = acquire!([])

      assert ("CC_SANDBOXD_TOKEN=" <> Provider.token(@session)) in container_body(
               requests,
               "sandbox"
             )["Env"]
    end

    test "the agent binds 0.0.0.0, because the forwarder reaches it across a network" do
      {_handle, _endpoint, requests} = acquire!([])
      env = container_body(requests, "sandbox")["Env"]

      # An agent on the container's own loopback would never see the forwarded
      # connection. Non-routability is the internal network's job.
      assert "CC_SANDBOXD_BIND=0.0.0.0" in env
      assert "CC_SANDBOXD_CAPTURE=/var/log/cc/out.jsonl" in env
    end

    test "a service spec cannot redefine the agent contract" do
      specs = [
        %{
          name: "sandbox",
          image: "sandbox:dev",
          env: %{"CC_SANDBOXD_PORT" => "1", "CC_SANDBOXD_BIND" => "127.0.0.1", "KEEP" => "yes"}
        }
      ]

      {_handle, _endpoint, requests} = acquire!(services: specs)
      env = container_body(requests, "sandbox")["Env"]

      assert "CC_SANDBOXD_PORT=8080" in env
      assert "CC_SANDBOXD_BIND=0.0.0.0" in env
      assert "KEEP=yes" in env
      refute "CC_SANDBOXD_PORT=1" in env
    end

    test "the forwarder is given no environment at all" do
      {_handle, _endpoint, requests} = acquire!([])
      assert container_body(requests, "forwarder")["Env"] == []
    end
  end

  describe "the egress proxy contract (blocker: a sandbox holding a working provider key)" do
    setup do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow, port: 3128}]
      {:ok, specs: specs}
    end

    test "the real key is removed from the sandbox, not merely overridden", %{specs: specs} do
      {_handle, _endpoint, requests} =
        acquire!(services: specs, proxy_service: "proxy", api_key: "sk-real-secret")

      env = container_body(requests, "sandbox")["Env"]

      refute Enum.any?(env, &String.starts_with?(&1, "ANTHROPIC_API_KEY=sk-real-secret"))
      assert "ANTHROPIC_BASE_URL=http://proxy:3128" in env

      # Replaced by a per-session token, so a sandbox that routes around the
      # proxy has nothing the upstream API will accept.
      assert [key] = Enum.filter(env, &String.starts_with?(&1, "ANTHROPIC_API_KEY="))
      refute key =~ "sk-real-secret"
    end

    test "the proxy receives the session token and the real key", %{specs: specs} do
      {_handle, _endpoint, requests} =
        acquire!(services: specs, proxy_service: "proxy", api_key: "sk-real-secret")

      proxy_env = container_body(requests, "proxy")["Env"]
      sandbox_env = container_body(requests, "sandbox")["Env"]

      assert "ANTHROPIC_API_KEY=sk-real-secret" in proxy_env
      assert ["CC_SESSION_TOKEN=" <> token] = Enum.filter(proxy_env, &(&1 =~ "CC_SESSION_TOKEN"))
      assert ("ANTHROPIC_API_KEY=" <> token) in sandbox_env

      # Prefixed, so a log shipper's redaction can find it (B6.4).
      assert "ccst_" <> random = token
      assert byte_size(random) == 43
    end

    test "an explicit :session_token is used rather than a minted one", %{specs: specs} do
      {_handle, _endpoint, requests} =
        acquire!(services: specs, proxy_service: "proxy", session_token: "sess-123")

      assert "CC_SESSION_TOKEN=sess-123" in container_body(requests, "proxy")["Env"]
      assert "ANTHROPIC_API_KEY=sess-123" in container_body(requests, "sandbox")["Env"]
    end

    test "with no :proxy_service the environment is untouched, real key included" do
      {_handle, _endpoint, requests} = acquire!(api_key: "sk-real-secret")
      env = container_body(requests, "sandbox")["Env"]

      assert "ANTHROPIC_API_KEY=sk-real-secret" in env
      refute Enum.any?(env, &String.starts_with?(&1, "ANTHROPIC_BASE_URL="))
    end

    test "a proxy on the internal network only is refused", %{specs: specs} do
      specs = Enum.map(specs, &%{&1 | egress: :none})

      assert {:error, {:compose, {:proxy_needs_egress, "proxy"}}} =
               gate(services: specs, proxy_service: "proxy")
    end

    test ":proxy_service must name a real service" do
      assert {:error, {:compose, {:unknown_service, "ghost"}}} = gate(proxy_service: "ghost")
    end
  end

  describe "dependency ordering (blocker: a sandbox wired to a proxy that never came up)" do
    test "a :ready spec becomes a HealthConfig in nanoseconds" do
      ready = %{
        "db" => %{
          test: ["CMD-SHELL", "pg_isready"],
          interval_ms: 500,
          timeout_ms: 1_500,
          retries: 4,
          start_period_ms: 2_000
        }
      }

      specs = [%{name: "db", image: "db:1", egress: :none}]
      {_handle, _endpoint, requests} = acquire!(services: specs, ready: ready)

      # The container config field is `Healthcheck`; `HealthConfig` names its
      # type. Durations are nanoseconds.
      assert container_body(requests, "db")["Healthcheck"] == %{
               "Test" => ["CMD-SHELL", "pg_isready"],
               "Interval" => 500_000_000,
               "Timeout" => 1_500_000_000,
               "Retries" => 4,
               "StartPeriod" => 2_000_000_000
             }
    end

    test "a service without a :ready spec gets no healthcheck and is not polled" do
      {_handle, _endpoint, requests} = acquire!([])

      refute Map.has_key?(container_body(requests, "sandbox"), "Healthcheck")

      refute Enum.any?(
               requests,
               &(&1.method == :get and &1.path == "/containers/ctr-sandbox/json")
             )
    end

    test "the poll waits through 'starting' and proceeds on 'healthy'" do
      {:ok, states} = Agent.start_link(fn -> ["starting", "starting", "healthy"] end)

      routes = %{
        {:get, "/containers/ctr-db/json"} => fn _req ->
          status = Agent.get_and_update(states, fn [h | t] -> {h, t} end)
          {200, %{"State" => %{"Health" => %{"Status" => status}}}}
        end
      }

      specs = [%{name: "db", image: "db:1", egress: :none}]

      {_handle, _endpoint, requests} =
        acquire!(
          services: specs,
          ready: ready_for("db"),
          routes: routes,
          health_timeout: 5_000
        )

      polls = Enum.count(requests, &(&1.path == "/containers/ctr-db/json"))
      assert polls == 3
      assert Agent.get(states, & &1) == []
    end

    test "'unhealthy' destroys the whole stack rather than continuing" do
      routes = %{
        {:get, "/containers/ctr-db/json"} =>
          {200, %{"State" => %{"Health" => %{"Status" => "unhealthy"}}}}
      }

      specs = [%{name: "db", image: "db:1", egress: :none}]

      assert {{:error, {:compose, {:unhealthy, "db"}}}, requests} =
               acquire(services: specs, ready: ready_for("db"), routes: routes)

      deletes = paths(requests, :delete)

      # Everything that had been created, including the container that was
      # never started because the failure came first.
      assert "/containers/ctr-sandbox" in deletes
      assert "/containers/ctr-db" in deletes
      assert "/networks/#{@project}-sbx" in deletes
      assert "/networks/#{@project}-pub" in deletes

      # And the forwarder was never created, because db came first in the order.
      refute Enum.any?(requests, &(&1.path == "/containers/ctr-forwarder/start"))
    end

    test "a poll deadline is the same failure as unhealthy" do
      routes = %{
        {:get, "/containers/ctr-db/json"} =>
          {200, %{"State" => %{"Health" => %{"Status" => "starting"}}}}
      }

      specs = [%{name: "db", image: "db:1", egress: :none}]

      assert {{:error, {:compose, {:unhealthy, "db"}}}, requests} =
               acquire(
                 services: specs,
                 ready: ready_for("db"),
                 routes: routes,
                 health_timeout: 0
               )

      assert "/containers/ctr-db" in paths(requests, :delete)
    end

    test "depends_on is honoured, and the forwarder always starts after the sandbox" do
      specs = [
        %{name: "web", image: "web:1", egress: :none, depends_on: ["db"]},
        %{name: "db", image: "db:1", egress: :none}
      ]

      {_handle, _endpoint, requests} = acquire!(services: specs)

      assert started_order(requests) == ["sandbox", "db", "web", "forwarder"]
    end

    test "a sandbox declared in :services keeps its place in the ordering" do
      specs = [
        %{name: "db", image: "db:1", egress: :none},
        %{name: "sandbox", image: "sandbox:dev", depends_on: ["db"]}
      ]

      {_handle, _endpoint, requests} = acquire!(services: specs)

      assert started_order(requests) == ["db", "sandbox", "forwarder"]
    end
  end

  describe "volumes (blocker: a named volume that outlives the whole stack)" do
    test "declared volumes are created project-scoped and mounted by target" do
      specs = [
        %{
          name: "db",
          image: "db:1",
          egress: :none,
          volumes: [
            %{name: "data", target: "/var/lib/data"},
            %{name: "ro", target: "/ro", read_only: true}
          ]
        }
      ]

      {handle, _endpoint, requests} =
        acquire!(services: specs, volumes: [%{name: "data"}, %{name: "ro"}])

      names =
        for r <- requests, r.method == :post, r.path == "/volumes/create", do: r.body["Name"]

      assert names == [@project <> "-data", @project <> "-ro"]
      assert handle.volumes == [@project <> "-data", @project <> "-ro"]

      assert container_body(requests, "db")["HostConfig"]["Binds"] == [
               "#{@project}-data:/var/lib/data",
               "#{@project}-ro:/ro:ro"
             ]
    end

    test "a service with no mounts gets no Binds key at all" do
      {_handle, _endpoint, requests} = acquire!([])
      refute Map.has_key?(container_body(requests, "sandbox")["HostConfig"], "Binds")
    end
  end

  describe "teardown order (blocker: a 403 on a network still in use)" do
    test "containers, then networks, then named volumes, explicitly" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]

      {handle, _endpoint, _requests} =
        acquire!(services: specs, volumes: [%{name: "workspace"}])

      {:ok, requests} = with_recorder(handle, fn handle -> Compose.release(handle) end)

      assert paths(requests, :delete) == [
               "/containers/ctr-sandbox",
               "/containers/ctr-proxy",
               "/containers/ctr-forwarder",
               "/networks/#{@project}-sbx",
               "/networks/#{@project}-pub",
               "/networks/#{@project}-egress",
               "/volumes/#{@project}-workspace"
             ]
    end

    test "container deletes force and take anonymous volumes with them" do
      {handle, _endpoint, _requests} = acquire!([])
      {:ok, requests} = with_recorder(handle, fn handle -> Compose.release(handle) end)

      assert %{"force" => "true", "v" => "true"} =
               find(requests, :delete, "/containers/ctr-sandbox").query
    end

    test "named volumes need their own DELETE, since ?v=true only takes anonymous ones" do
      {handle, _endpoint, _requests} = acquire!(volumes: [%{name: "workspace"}])
      {:ok, requests} = with_recorder(handle, fn handle -> Compose.release(handle) end)

      assert find(requests, :delete, "/volumes/#{@project}-workspace")
    end

    test "a reaper-rebuilt handle finds named volumes by label, since it cannot know them" do
      routes = %{
        {:get, "/volumes"} => {200, %{"Volumes" => [%{"Name" => @project <> "-orphan"}]}}
      }

      handle = %Compose{
        project: @project,
        session_key: @session,
        owner: "node-a",
        sandbox_network: @project <> "-sbx",
        publish_network: @project <> "-pub",
        egress_network: @project <> "-egress",
        sandbox_service: "sandbox",
        forwarder_service: "forwarder",
        containers: [{"sandbox", "ctr-sandbox"}]
      }

      {:ok, requests} =
        with_recorder(handle, routes, fn handle -> Compose.release(handle) end)

      assert "/volumes/#{@project}-orphan" in paths(requests, :delete)
    end

    test "release/1 is idempotent across 404 on every resource" do
      {handle, _endpoint, _requests} = acquire!(volumes: [%{name: "workspace"}])
      routes = %{:any_delete => {404, %{"message" => "no such thing"}}}

      {:ok, requests} = with_recorder(handle, routes, fn handle -> Compose.release(handle) end)

      # Already gone is the desired end state, and nothing is retried for it:
      # two containers, three networks, one named volume, one pass.
      assert paths(requests, :delete) == [
               "/containers/ctr-sandbox",
               "/containers/ctr-forwarder",
               "/networks/#{@project}-sbx",
               "/networks/#{@project}-pub",
               "/networks/#{@project}-egress",
               "/volumes/#{@project}-workspace"
             ]
    end

    test "a partial teardown is retried, then gives up returning :ok" do
      {handle, _endpoint, _requests} = acquire!([])
      routes = %{{:delete, "/containers/ctr-sandbox"} => {500, %{"message" => "device busy"}}}

      log =
        capture_log(fn ->
          {:ok, requests} =
            with_recorder(handle, routes, fn handle -> Compose.release(handle) end)

          # Three passes over the whole sequence, not one abandoned attempt: the
          # usual cause is a container that has not finished going away.
          assert Enum.count(paths(requests, :delete), &(&1 == "/containers/ctr-sandbox")) == 3
        end)

      assert log =~ "compose teardown incomplete"
    end

    test "release/1 on a handle that never provisioned touches nothing" do
      assert Compose.release(%Compose{}) == :ok
    end
  end

  describe "list_live/1 (blocker: a reaper that reaps containers instead of stacks)" do
    test "returns one handle per stack, not one per container" do
      containers = [
        container_json("a1", "session-a", "sandbox"),
        container_json("a2", "session-a", "proxy"),
        container_json("a3", "session-a", "forwarder"),
        container_json("b1", "session-b", "sandbox")
      ]

      {:ok, requests} = recorder(%{{:get, "/containers/json"} => {200, containers}})

      assert {:ok, handles} = Compose.list_live(req_adapter: requests.adapter, owner: "node-a")
      assert length(handles) == 2

      [stack_a, stack_b] = Enum.sort_by(handles, & &1.session_key)

      assert stack_a.session_key == "session-a"

      assert Enum.sort(stack_a.containers) == [
               {"forwarder", "a3"},
               {"proxy", "a2"},
               {"sandbox", "a1"}
             ]

      assert stack_a.project == "cc-session-a"
      assert stack_a.sandbox_network == "cc-session-a-sbx"
      assert stack_b.containers == [{"sandbox", "b1"}]
    end

    test "is owner-, agent- and compose-scoped" do
      {:ok, requests} = recorder(%{{:get, "/containers/json"} => {200, []}})
      {:ok, []} = Compose.list_live(req_adapter: requests.adapter, owner: "node-a")

      filters = JSON.decode!(find(requests.log.(), :get, "/containers/json").query["filters"])

      # Unscoped, one node's reaper destroys another node's sandboxes; without
      # the agent label it also picks up Backend.Docker's FIFO containers; and
      # oneoff excludes Provider.Docker's single containers, which carry no
      # compose labels.
      assert filters == %{
               "label" => [
                 "crowd_control.owner=node-a",
                 "crowd_control.agent=sandboxd",
                 "com.docker.compose.oneoff=False"
               ]
             }
    end

    test "containers without a session label are dropped rather than grouped under nil" do
      containers = [container_json("x", nil, "sandbox")]
      {:ok, requests} = recorder(%{{:get, "/containers/json"} => {200, containers}})

      assert {:ok, []} = Compose.list_live(req_adapter: requests.adapter, owner: "node-a")
    end

    test "an unexpected list response is an error, not a crash" do
      {:ok, requests} = recorder(%{{:get, "/containers/json"} => {200, %{"oops" => true}}})

      assert {:error, {:compose, {:unexpected_list_response, _}}} =
               Compose.list_live(req_adapter: requests.adapter, owner: "node-a")
    end
  end

  describe "reconnect/1 (blocker: a persisted host port)" do
    test "re-reads the forwarder's port, because it changes on every start" do
      {handle, endpoint, _requests} = acquire!([])
      assert endpoint.base_url == "http://127.0.0.1:32768"

      routes = %{
        {:get, "/containers/ctr-forwarder/json"} =>
          {200,
           %{
             "NetworkSettings" => %{
               "Ports" => %{"8080/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => "40001"}]}
             }
           }}
      }

      {{:ok, _handle, reconnected}, _requests} =
        with_recorder(handle, routes, fn handle -> Compose.reconnect(handle) end)

      assert reconnected.base_url == "http://127.0.0.1:40001"
      assert reconnected.token == Provider.token(@session)
    end

    test "refuses a handle that never provisioned" do
      assert {:error, {:compose, :not_provisioned}} = Compose.reconnect(%Compose{})
    end
  end

  describe "age_ms/1 (blocker: a reaper that cannot tell a stack's age)" do
    test "reads the created_at label off the sandbox container" do
      {handle, _endpoint, _requests} = acquire!([])
      created = System.system_time(:millisecond) - 5_000

      routes = %{
        {:get, "/containers/ctr-sandbox/json"} =>
          {200, %{"Config" => %{"Labels" => %{"crowd_control.created_at" => to_string(created)}}}}
      }

      {age, _requests} = with_recorder(handle, routes, fn handle -> Compose.age_ms(handle) end)

      assert age >= 5_000
    end

    test "is nil rather than an error when the label is unreadable" do
      {handle, _endpoint, _requests} = acquire!([])
      routes = %{{:get, "/containers/ctr-sandbox/json"} => {200, %{"Config" => %{}}}}

      assert {nil, _requests} =
               with_recorder(handle, routes, fn handle -> Compose.age_ms(handle) end)

      assert Compose.age_ms(%Compose{}) == nil
    end
  end

  describe "scrub/1 (blocker: a credential in a Store record on disk)" do
    test "no token appears in the bytes of a persisted handle" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]

      {handle, _endpoint, _requests} =
        acquire!(services: specs, proxy_service: "proxy", api_key: "sk-real-secret")

      # term_to_binary, never inspect: Provider.Endpoint redacts on inspect and
      # a struct field would make the assertion vacuous.
      bytes = :erlang.term_to_binary(Compose.scrub(persistable(handle)))

      refute bytes =~ Provider.token(@session)
      refute bytes =~ "sk-real-secret"
      refute bytes =~ Application.fetch_env!(:crowd_control, :sandboxd_secret)
      refute bytes =~ "ANTHROPIC"
    end

    test "credential-bearing top-level options are dropped" do
      {handle, _endpoint, _requests} = acquire!(api_key: "sk-real-secret")
      scrubbed = Compose.scrub(handle)

      refute Keyword.has_key?(scrubbed.config, :api_key)
      assert Keyword.has_key?(scrubbed.config, :image)
    end

    test "a service spec's env is stripped too, since Store cannot see into it" do
      specs = [%{name: "db", image: "db:1", egress: :none, env: %{"PGPASSWORD" => "hunter2"}}]
      {handle, _endpoint, _requests} = acquire!(services: specs)

      scrubbed = Compose.scrub(persistable(handle))

      refute :erlang.term_to_binary(scrubbed) =~ "hunter2"
      # The rest of the spec survives, so release/1 still knows what it built.
      assert [%{name: "db", image: "db:1"}] = scrubbed.config[:services]
    end

    test "a scrubbed handle can still be reconnected" do
      {handle, _endpoint, _requests} = acquire!(api_key: "sk-real-secret")

      {{:ok, _handle, endpoint}, _requests} =
        with_recorder(Compose.scrub(handle), fn handle -> Compose.reconnect(handle) end)

      assert endpoint.token == Provider.token(@session)
    end
  end

  describe "hardening (blocker: a sidecar weaker than the sandbox it shares a network with)" do
    test "every container in the stack gets the shared hardening defaults" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]
      {_handle, _endpoint, requests} = acquire!(services: specs)

      defaults = HostConfig.hardening_defaults()

      for service <- ["sandbox", "proxy", "forwarder"] do
        host = container_body(requests, service)["HostConfig"]

        for {key, value} <- Map.delete(defaults, "NetworkMode") do
          assert host[key] == value, "#{service} lost #{key}"
        end
      end
    end

    test "hardening options apply to the whole stack, not just the sandbox" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]
      {_handle, _endpoint, requests} = acquire!(services: specs, pids_limit: 64, memory: 1024)

      for service <- ["sandbox", "proxy", "forwarder"] do
        host = container_body(requests, service)["HostConfig"]
        assert host["PidsLimit"] == 64
        assert host["Memory"] == 1024
      end
    end

    test "a per-service :user is applied at the container level" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :none, user: "1000:1000"}]
      {_handle, _endpoint, requests} = acquire!(services: specs)

      assert container_body(requests, "proxy")["User"] == "1000:1000"
      refute Map.has_key?(container_body(requests, "forwarder"), "User")
    end
  end

  describe "name conflicts (blocker: adopting a container this run did not write)" do
    test "a 409 on create is a hard error, and the partial stack is destroyed" do
      routes = %{{:post, "/containers/create"} => {409, %{"message" => "name in use"}}}

      assert {{:error, {:compose, {:name_conflict, name}}}, requests} = acquire(routes: routes)
      assert name == @project <> "-sandbox-1"

      # The container may hold a token derived from a since-rotated secret, so
      # reuse is not safe; the networks that were created go away.
      assert "/networks/#{@project}-sbx" in paths(requests, :delete)
    end

    test "a 409 on network create is reuse, since the name and posture are derived" do
      routes = %{{:post, "/networks/create"} => {409, %{"message" => "already exists"}}}

      assert {{:ok, _handle, _endpoint}, _requests} = acquire(routes: routes)
    end
  end

  describe "version gate (blocker: CVE-2024-29018 DNS exfiltration from an internal network)" do
    test "an :allow sidecar on a daemon below 25.0.5 creates nothing" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]
      routes = %{{:get, "/version"} => {200, %{"Version" => "25.0.4"}}}

      assert {{:error, {:version, :docker, {25, 0, 4}, {25, 0, 5}}}, requests} =
               acquire(services: specs, docker_host: unique_host(), routes: routes)

      assert Enum.map(requests, &{&1.method, &1.path}) == [{:get, "/version"}]
    end

    test "per-service networks are gated the same way" do
      routes = %{{:get, "/version"} => {200, %{"Version" => "24.0.9"}}}

      assert {{:error, {:version, :docker, {24, 0, 9}, {25, 0, 5}}}, requests} =
               acquire(networks: [%{name: "brw"}], docker_host: unique_host(), routes: routes)

      refute Enum.any?(requests, &(&1.method == :post))
    end

    test "a stack with no gated feature never asks for the version" do
      {_handle, _endpoint, requests} = acquire!(docker_host: unique_host())

      refute find(requests, :get, "/version")
    end

    test "an unreachable /version is a failed gate, not an assumed pass" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]
      routes = %{{:get, "/version"} => {500, %{"message" => "boom"}}}

      assert {{:error, {:docker, {:http_status, 500, "boom"}}}, requests} =
               acquire(services: specs, docker_host: unique_host(), routes: routes)

      refute Enum.any?(requests, &(&1.method == :post))
    end
  end

  describe "CrowdControl.Service on Compose (blocker: two substrates drifting on one spec)" do
    test "placement is Kubernetes-only and ignored with a warning" do
      specs = [%{name: "db", image: "db:1", egress: :none, placement: :pod}]

      log = capture_log(fn -> assert {{:ok, _, _}, _} = acquire(services: specs) end)

      assert log =~ "placement"
      assert log =~ "db"
    end

    test "a service's own ready: becomes its healthcheck" do
      specs = [
        %{
          name: "db",
          image: "db:1",
          egress: :none,
          ready: %{test: ["CMD", "true"], interval_ms: 10, timeout_ms: 10, retries: 1}
        }
      ]

      {_handle, _endpoint, requests} = acquire!(services: specs)

      assert container_body(requests, "db")["Healthcheck"]["Test"] == ["CMD", "true"]
    end
  end

  describe ":files (blocker: configuration that never reaches the container)" do
    test "files are uploaded as a tar between create and start" do
      specs = [
        %{
          name: "proxy",
          image: "proxy:1",
          egress: :none,
          files: [
            %{
              path: "/cfg/config.yaml",
              content: "acl_file: /cfg/acl.yaml\n",
              mode: 0o440,
              uid: 65_532
            },
            %{path: "/cfg/acl.yaml", content: "allowed_domains: []\n"}
          ]
        }
      ]

      {_handle, _endpoint, requests} = acquire!(services: specs)

      upload = find(requests, :put, "/containers/ctr-proxy/archive")
      assert upload.query == %{"path" => "/"}

      create = index(requests, :post, "/containers/create", "proxy")
      put = index(requests, :put, "/containers/ctr-proxy/archive")
      start = index(requests, :post, "/containers/ctr-proxy/start")
      assert create < put and put < start

      assert {:ok, entries} = :erl_tar.extract({:binary, upload.body}, [:memory])

      assert Enum.sort(entries) == [
               {~c"cfg/acl.yaml", "allowed_domains: []\n"},
               {~c"cfg/config.yaml", "acl_file: /cfg/acl.yaml\n"}
             ]

      assert {:ok, table} = :erl_tar.table({:binary, upload.body}, [:verbose])

      assert {_, :regular, _, _, 0o440, 65_532, 0} =
               List.keyfind(table, ~c"cfg/config.yaml", 0)

      assert {_, :regular, _, _, 0o644, 0, 0} = List.keyfind(table, ~c"cfg/acl.yaml", 0)
    end

    test "a service without files makes no upload" do
      {_handle, _endpoint, requests} = acquire!([])
      refute Enum.any?(requests, &(&1.method == :put))
    end

    test "a file under a writable volume is uploaded into that volume" do
      specs = [
        %{
          name: "vector",
          image: "vector:1",
          egress: :none,
          volumes: [%{name: "cfg", target: "/etc/vector"}],
          files: [%{path: "/etc/vector/conf.d/vector.yaml", content: "sources: {}\n"}]
        }
      ]

      {_handle, _endpoint, requests} =
        acquire!(services: specs, volumes: [%{name: "cfg"}], readonly_rootfs: true)

      upload = find(requests, :put, "/containers/ctr-vector/archive")
      assert upload.query == %{"path" => "/etc/vector"}

      assert {:ok, [{~c"conf.d/vector.yaml", "sources: {}\n"}]} =
               :erl_tar.extract({:binary, upload.body}, [:memory])
    end

    test "the daemon's 403 cases are refused before any HTTP" do
      ro_mount = [%{name: "cfg", target: "/cfg", read_only: true}]

      cases = [
        # Read-only rootfs and no volume under the path.
        {[readonly_rootfs: true], %{}, []},
        # A read-only mount.
        {[], %{}, ro_mount},
        # Read-only only for this service.
        {[], %{readonly_rootfs: true}, []},
        # Under a tmpfs, which hides the file once it mounts.
        {[], %{tmpfs: %{"/cfg" => "rw"}}, []}
      ]

      for {stack, host_config, volumes} <- cases do
        spec = %{
          name: "proxy",
          image: "proxy:1",
          egress: :none,
          host_config: host_config,
          volumes: volumes,
          files: [%{path: "/cfg/a.yaml", content: "x"}]
        }

        opts = [services: [spec], volumes: [%{name: "cfg"}]] ++ stack

        assert {:error, {:compose, {:files_not_writable, {"proxy", "/cfg/a.yaml"}}}} =
                 gate(opts)
      end
    end

    test "malformed files are refused before any HTTP" do
      for {files, reason} <- [
            {[%{path: "cfg/a", content: ""}], {:bad_file, {"proxy", "cfg/a"}}},
            {[%{path: "/cfg/../etc/passwd", content: ""}],
             {:bad_file, {"proxy", "/cfg/../etc/passwd"}}},
            {[%{path: "/a", content: ""}, %{path: "/a", content: ""}],
             {:duplicate_file, {"proxy", "/a"}}},
            {[%{path: "/a", content: :binary.copy("x", 1_048_577)}],
             {:files_too_large, {"proxy", 1_048_577}}}
          ] do
        spec = %{name: "proxy", image: "proxy:1", egress: :none, files: files}
        assert {:error, {:compose, ^reason}} = gate(services: [spec])
      end
    end

    test "scrub/1 drops files along with env" do
      specs = [
        %{name: "db", image: "db:1", egress: :none, files: [%{path: "/a", content: "big"}]}
      ]

      {handle, _endpoint, _requests} = acquire!(services: specs)

      assert [spec] = Compose.scrub(handle).config[:services]
      refute Map.has_key?(spec, :files)
    end

    test "archive/2 round-trips through :erl_tar" do
      files = [
        %{path: "/w/a.txt", content: "alpha", mode: 0o600, uid: 1, gid: 2},
        %{path: "/w/deep/b.bin", content: <<0, 255, 1>>, mode: 0o755, uid: 0, gid: 0}
      ]

      bytes = Compose.archive("/w", files)

      assert {:ok, entries} = :erl_tar.extract({:binary, bytes}, [:memory])
      assert Enum.sort(entries) == [{~c"a.txt", "alpha"}, {~c"deep/b.bin", <<0, 255, 1>>}]

      # Deterministic: a body is a function of its inputs.
      assert Compose.archive("/w", files) == bytes
    end
  end

  describe "per-service networks (blocker: a sandbox one hop from the internet)" do
    test "a sandbox sharing a network with an :allow service is refused" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow, networks: ["sbx", "brw"]}]

      assert {:error, {:compose, {:sandbox_shares_network_with_egress, "sbx", "proxy"}}} =
               gate(services: specs, networks: [%{name: "brw"}])
    end

    test "joining the sandbox on an extra network shared with an :allow service is refused" do
      specs = [
        %{name: "sandbox", networks: ["sbx", "brw"]},
        %{name: "proxy", image: "proxy:1", egress: :allow, networks: ["brw"]}
      ]

      assert {:error, {:compose, {:sandbox_shares_network_with_egress, "brw", "proxy"}}} =
               gate(services: specs, networks: [%{name: "brw"}])
    end

    test "an :allow service left on the default sbx is refused once networks are in use" do
      specs = [%{name: "proxy", image: "proxy:1", egress: :allow}]

      assert {:error, {:compose, {:sandbox_shares_network_with_egress, "sbx", "proxy"}}} =
               gate(services: specs, networks: [%{name: "brw"}])
    end

    test "the :proxy_service is the one sanctioned relay" do
      specs = [
        %{name: "api", image: "api:1", egress: :allow},
        %{name: "browser", image: "b:1", egress: :none, networks: ["sbx", "brw"]},
        %{name: "proxy", image: "proxy:1", egress: :allow, networks: ["brw"]}
      ]

      assert {{:ok, _, _}, _} =
               acquire(services: specs, networks: [%{name: "brw"}], proxy_service: "api")
    end

    test "browser on sbx and brw, proxy on brw and egress: the two-tier layout" do
      specs = [
        %{name: "browser", image: "b:1", egress: :none, networks: ["sbx", "brw"]},
        %{name: "proxy", image: "proxy:1", egress: :allow, networks: ["brw"]}
      ]

      {handle, _endpoint, requests} = acquire!(services: specs, networks: [%{name: "brw"}])

      brw = network_body(requests, "-brw")
      assert brw["Name"] == @project <> "-brw"
      assert brw["Internal"] == true
      assert brw["Labels"]["com.docker.compose.network"] == "brw"
      assert brw["Labels"]["crowd_control.session"] == @session

      assert container_body(requests, "browser")["NetworkingConfig"] == %{
               "EndpointsConfig" => %{(@project <> "-sbx") => %{"Aliases" => ["browser"]}}
             }

      assert container_body(requests, "proxy")["NetworkingConfig"] == %{
               "EndpointsConfig" => %{(@project <> "-brw") => %{"Aliases" => ["proxy"]}}
             }

      assert container_body(requests, "proxy")["HostConfig"]["NetworkMode"] == @project <> "-brw"

      connects =
        for r <- requests,
            r.method == :post,
            String.ends_with?(r.path, "/connect"),
            do: {r.path, r.body["Container"]}

      assert {"/networks/#{@project}-brw/connect", "ctr-browser"} in connects
      assert {"/networks/#{@project}-egress/connect", "ctr-proxy"} in connects
      refute {"/networks/#{@project}-sbx/connect", "ctr-proxy"} in connects
      refute Enum.any?(connects, &(elem(&1, 1) == "ctr-sandbox"))

      assert handle.networks == [@project <> "-brw"]
    end

    test "Preset.browser_stack/1's Compose output is accepted as is, in the two-tier layout" do
      {services, networks, _overrides} =
        CrowdControl.Preset.browser_stack(
          substrate: :compose,
          proxy: [image: "smokescreen:1", allow_domains: ["example.com"], nc: true],
          browser: [image: "browser:1"]
        )

      {_handle, _endpoint, requests} = acquire!(services: services, networks: networks)

      assert container_body(requests, "browser")["NetworkingConfig"] == %{
               "EndpointsConfig" => %{(@project <> "-sbx") => %{"Aliases" => ["browser"]}}
             }

      proxy = container_body(requests, "egress-proxy")
      assert proxy["HostConfig"]["NetworkMode"] == @project <> "-brw"
      assert proxy["User"] == "65532:65532"
      assert ["/bin/sh", "-c", "exec smokescreen " <> _] = proxy["Entrypoint"]
      assert proxy["Healthcheck"]["Test"] == ["CMD", "nc", "-z", "127.0.0.1", "4750"]

      browser = container_body(requests, "browser")["HostConfig"]
      assert browser["ShmSize"] == 1_073_741_824
      assert browser["Init"] == true
      assert browser["Tmpfs"]["/tmp"] == "rw,nosuid,size=512m"

      connects =
        for r <- requests,
            r.method == :post and String.ends_with?(r.path, "/connect"),
            do: {r.path, r.body["Container"]}

      assert {"/networks/#{@project}-brw/connect", "ctr-browser"} in connects
      assert {"/networks/#{@project}-egress/connect", "ctr-egress-proxy"} in connects

      # The Smokescreen config is staged before start.
      assert find(requests, :put, "/containers/ctr-egress-proxy/archive")
    end

    test "memberships must name sbx or a declared network" do
      specs = [%{name: "browser", image: "b:1", egress: :none, networks: ["brw"]}]

      assert {:error, {:compose, {:unknown_network, {"browser", "brw"}}}} =
               gate(services: specs)
    end

    test "the sandbox must stay on sbx, which the forwarder reaches it across" do
      assert {:error, {:compose, {:sandbox_needs_network, "sbx"}}} =
               gate(services: [%{name: "sandbox", networks: ["brw"]}], networks: [%{name: "brw"}])
    end

    test "a stack network may not reuse a fixed network's name" do
      for name <- ["sbx", "pub", "egress", "Bad"] do
        assert {:error, {:compose, {:bad_stack_network, %{name: ^name}}}} =
                 gate(networks: [%{name: name}])
      end

      assert {:error, {:compose, {:bad_stack_network, %{name: "brw"}}}} =
               gate(networks: [%{name: "brw"}, %{name: "brw"}])
    end

    test "teardown deletes the extra networks, after the containers" do
      {handle, _endpoint, _requests} = acquire!(networks: [%{name: "brw"}])
      {:ok, requests} = with_recorder(handle, fn handle -> Compose.release(handle) end)

      deletes = paths(requests, :delete)
      assert "/networks/#{@project}-brw" in deletes

      assert Enum.find_index(deletes, &(&1 == "/containers/ctr-forwarder")) <
               Enum.find_index(deletes, &(&1 == "/networks/#{@project}-brw"))
    end

    test "a reaper-rebuilt handle finds extra networks by label" do
      containers = [container_json("a1", @session, "sandbox")]

      routes = %{
        {:get, "/containers/json"} => {200, containers},
        {:get, "/networks"} => {200, [%{"Name" => @project <> "-brw"}]}
      }

      {:ok, recorder} = recorder(routes)

      {:ok, [handle]} = Compose.list_live(req_adapter: recorder.adapter, owner: "node-a")
      :ok = Compose.release(handle)

      requests = recorder.log.()
      assert "/networks/#{@project}-brw" in paths(requests, :delete)

      filters = JSON.decode!(find(requests, :get, "/networks").query["filters"])
      assert filters == %{"label" => ["crowd_control.session=#{@session}"]}
    end
  end

  describe "per-service HostConfig (blocker: a weakened browser beside the sandbox)" do
    test "ShmSize and Init are rendered for the service that asks, and only it" do
      specs = [
        %{
          name: "browser",
          image: "b:1",
          egress: :none,
          host_config: %{shm_size: 1_073_741_824, init: true}
        }
      ]

      {_handle, _endpoint, requests} = acquire!(services: specs)

      browser = container_body(requests, "browser")["HostConfig"]
      assert browser["ShmSize"] == 1_073_741_824
      assert browser["Init"] == true

      refute Map.has_key?(container_body(requests, "sandbox")["HostConfig"], "ShmSize")
      refute Map.has_key?(container_body(requests, "forwarder")["HostConfig"], "Init")
    end

    test "an undeclared weakening is refused before any HTTP" do
      specs = [
        %{name: "browser", image: "b:1", egress: :none, host_config: %{cap_add: ["SYS_ADMIN"]}}
      ]

      assert {:error, {:compose, {:weakening_not_declared, "browser", :cap_add}}} =
               gate(services: specs)

      specs = [%{name: "browser", image: "b:1", egress: :none, user: "0"}]

      assert {:error, {:compose, {:weakening_not_declared, "browser", :user}}} =
               gate(services: specs)
    end

    test "a declared weakening renders, and leaves the rest hardened" do
      specs = [
        %{
          name: "browser",
          image: "b:1",
          egress: :none,
          host_config: %{cap_add: ["SYS_ADMIN"], no_new_privileges: false},
          weaken: [:cap_add, :no_new_privileges]
        }
      ]

      {_handle, _endpoint, requests} = acquire!(services: specs)

      browser = container_body(requests, "browser")["HostConfig"]
      assert browser["CapAdd"] == ["SYS_ADMIN"]
      assert browser["CapDrop"] == ["ALL"]
      refute "no-new-privileges:true" in browser["SecurityOpt"]

      sandbox = container_body(requests, "sandbox")["HostConfig"]
      assert sandbox["SecurityOpt"] == ["no-new-privileges:true"]
      refute Map.has_key?(sandbox, "CapAdd")
    end

    test "privileged is always refused" do
      for spec <- [
            %{name: "browser", image: "b:1", egress: :none, host_config: %{privileged: true}},
            %{
              name: "browser",
              image: "b:1",
              egress: :none,
              host_config: %{privileged: true},
              weaken: [:privileged]
            }
          ] do
        assert {:error, {:compose, {:privileged_refused, "browser"}}} = gate(services: [spec])
      end
    end
  end

  describe "teardown drain (blocker: a log shipper SIGKILLed mid-flush)" do
    setup do
      specs = [
        %{name: "vector", image: "vector:1", egress: :none, drain: 10, shutdown_limit: 7}
      ]

      {:ok, specs: specs}
    end

    test "a drained service is stopped gracefully before any force-remove", %{specs: specs} do
      {handle, _endpoint, requests} = acquire!(services: specs)

      labels = container_body(requests, "vector")["Labels"]
      assert labels["crowd_control.drain_ms"] == "10"
      assert labels["crowd_control.stop_timeout_s"] == "12"

      {:ok, requests} = with_recorder(handle, fn handle -> Compose.release(handle) end)

      stop = find(requests, :post, "/containers/ctr-vector/stop")
      assert stop.query == %{"t" => "12"}

      stop_at = index(requests, :post, "/containers/ctr-vector/stop")
      first_delete = Enum.find_index(requests, &(&1.method == :delete))
      assert stop_at < first_delete

      # Only the drained service; the sandbox and forwarder are unchanged.
      assert [_] = Enum.filter(requests, &String.ends_with?(&1.path, "/stop"))
    end

    test "a session without a drained service keeps the plain force-remove path" do
      {handle, _endpoint, _requests} = acquire!([])
      {:ok, requests} = with_recorder(handle, fn handle -> Compose.release(handle) end)

      refute Enum.any?(requests, &String.ends_with?(&1.path, "/stop"))
    end

    test "a stop that fails still lets teardown remove everything", %{specs: specs} do
      {handle, _endpoint, _requests} = acquire!(services: specs)
      routes = %{{:post, "/containers/ctr-vector/stop"} => {500, %{"message" => "stuck"}}}

      log =
        capture_log(fn ->
          {:ok, requests} = with_recorder(handle, routes, fn h -> Compose.release(h) end)
          assert "/containers/ctr-vector" in paths(requests, :delete)
        end)

      assert log =~ "drain of vector failed"
    end

    test "an already-stopped container (304) is not an error", %{specs: specs} do
      {handle, _endpoint, _requests} = acquire!(services: specs)
      routes = %{{:post, "/containers/ctr-vector/stop"} => {304, ""}}

      log = capture_log(fn -> with_recorder(handle, routes, fn h -> Compose.release(h) end) end)
      refute log =~ "drain"
    end

    test "a reaper-rebuilt handle drains from the container labels" do
      labels = %{"crowd_control.drain_ms" => "0", "crowd_control.stop_timeout_s" => "9"}

      containers = [
        container_json("a1", @session, "sandbox"),
        Map.update!(container_json("a2", @session, "vector"), "Labels", &Map.merge(&1, labels))
      ]

      {:ok, recorder} = recorder(%{{:get, "/containers/json"} => {200, containers}})

      {:ok, [handle]} = Compose.list_live(req_adapter: recorder.adapter, owner: "node-a")
      assert handle.drained == [{"vector", 0, 9}]

      :ok = Compose.release(handle)
      assert find(recorder.log.(), :post, "/containers/a2/stop").query == %{"t" => "9"}
    end

    test "a failed acquire rolls back without waiting on a drain", %{specs: specs} do
      routes = %{
        {:get, "/containers/ctr-forwarder/json"} =>
          {200, %{"NetworkSettings" => %{"Ports" => %{"8080/tcp" => nil}}}}
      }

      assert {{:error, _}, requests} = acquire(services: specs, routes: routes)
      refute Enum.any?(requests, &String.ends_with?(&1.path, "/stop"))
    end
  end

  # --- Helpers ---

  defp base_opts do
    [image: "sandbox:dev", session_key: @session, owner: "node-a"]
  end

  # `:req_adapter` is a test-only closure over this test's own options, so
  # term_to_binary would find every secret in its captured environment and the
  # assertion would be about the harness rather than about the handle. Nothing
  # in production sets it.
  defp persistable(handle) do
    %{handle | config: Keyword.delete(handle.config, :req_adapter)}
  end

  # Drives a gate with an adapter that raises, so a passing assertion also
  # proves nothing reached the transport.
  defp gate(opts) do
    opts =
      base_opts()
      |> Keyword.merge(opts)
      |> Keyword.put(:req_adapter, fn _req -> raise "the transport must not be reached" end)

    Compose.acquire(opts)
  end

  defp acquire(opts) do
    {routes, opts} = Keyword.pop(opts, :routes, %{})
    opts = Keyword.merge(base_opts(), opts)
    {:ok, recorder} = start_recorder(opts, routes)

    {Compose.acquire(Keyword.put(opts, :req_adapter, recorder.adapter)), recorder.log.()}
  end

  defp acquire!(opts) do
    {result, requests} = acquire(opts)
    {:ok, handle, endpoint} = result
    {handle, endpoint, requests}
  end

  # Re-run something against a fresh recorder, so the requests a later call
  # makes are not mixed with the ones acquire/1 made.
  defp with_recorder(handle, fun), do: with_recorder(handle, %{}, fun)

  defp with_recorder(handle, routes, fun) do
    {:ok, recorder} = start_recorder(handle.config, routes)
    result = fun.(%{handle | config: Keyword.put(handle.config, :req_adapter, recorder.adapter)})

    case result do
      :ok -> {:ok, recorder.log.()}
      other -> {other, recorder.log.()}
    end
  end

  defp recorder(routes), do: start_recorder([], routes)

  defp start_recorder(opts, routes) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    adapter = fn req ->
      Agent.update(agent, &[record(req) | &1])
      {status, body} = route(req, routes, opts)
      {req, Req.Response.new(status: status, body: body)}
    end

    {:ok, %{adapter: adapter, log: fn -> Agent.get(agent, &Enum.reverse(&1)) end}}
  end

  defp record(req) do
    uri = URI.parse(to_string(req.url))

    %{
      method: req.method,
      path: uri.path,
      query: URI.decode_query(uri.query || ""),
      body: request_body(req)
    }
  end

  # A tar upload is kept as raw bytes; everything else this provider sends is
  # JSON.
  defp request_body(%{body: body}) when is_binary(body) and body != "" do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp request_body(%{options: %{json: json}}), do: JSON.decode!(JSON.encode!(json))
  defp request_body(_req), do: %{}

  # Route a stubbed request by {method, path}, honouring per-test overrides.
  # Any unrouted call raises with the method and path, so a test that stubs the
  # wrong thing fails loudly instead of timing out.
  defp route(req, routes, opts) do
    key = {req.method, URI.parse(to_string(req.url)).path}

    case Map.get(routes, key) || delete_override(routes, req) do
      nil -> default_route(req, key, opts)
      fun when is_function(fun, 1) -> fun.(req)
      {status, body} -> {status, body}
    end
  end

  defp delete_override(routes, %{method: :delete}), do: Map.get(routes, :any_delete)
  defp delete_override(_routes, _req), do: nil

  defp default_route(req, key, opts) do
    case key do
      {:post, "/networks/create"} -> {201, %{"Id" => "net"}}
      {:post, "/volumes/create"} -> {201, %{"Name" => "vol"}}
      {:post, "/containers/create"} -> {201, %{"Id" => "ctr-" <> service_of(req, opts)}}
      {:post, path} -> post_route(path)
      {:put, "/containers/" <> _} -> {200, ""}
      {:get, path} -> get_route(path, Keyword.get(opts, :agent_port, 8080))
      {:delete, _path} -> {204, ""}
      _ -> raise "unstubbed Docker API call: #{inspect(key)}"
    end
  end

  defp get_route("/containers/" <> rest, port), do: inspect_route(rest, port)
  defp get_route("/volumes", _port), do: {200, %{"Volumes" => []}}
  defp get_route("/networks", _port), do: {200, []}
  defp get_route("/version", _port), do: {200, %{"Version" => "27.3.1", "ApiVersion" => "1.47"}}
  defp get_route("/v1/health", _port), do: {200, %{"ok" => true}}
  defp get_route(path, _port), do: raise("unstubbed Docker API call: #{inspect({:get, path})}")

  defp post_route(path) do
    cond do
      String.ends_with?(path, "/start") -> {204, ""}
      String.ends_with?(path, "/stop") -> {204, ""}
      String.ends_with?(path, "/connect") -> {200, %{}}
      true -> raise "unstubbed Docker API POST: #{path}"
    end
  end

  defp inspect_route(rest, port) do
    id = String.trim_trailing(rest, "/json")

    {200,
     %{
       "Id" => id,
       "Config" => %{"Labels" => %{"crowd_control.created_at" => "1000"}},
       "State" => %{"Running" => true, "Health" => %{"Status" => "healthy"}},
       "NetworkSettings" => %{
         "Ports" => %{"#{port}/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => "32768"}]}
       }
     }}
  end

  # `<project>-<service>-1` back to `<service>`, so the stub can hand out ids a
  # test can name.
  defp service_of(req, opts) do
    project = opts[:project_name] || "cc-" <> opts[:session_key]

    URI.parse(to_string(req.url)).query
    |> URI.decode_query()
    |> Map.fetch!("name")
    |> String.replace_prefix(project <> "-", "")
    |> String.replace_suffix("-1", "")
  end

  defp ready_for(service) do
    %{service => %{test: ["CMD", "true"], interval_ms: 10, timeout_ms: 10, retries: 1}}
  end

  # A docker_host no other test uses, so the per-host version cache is this
  # test's alone. The host itself is never dialled: :req_adapter answers.
  defp unique_host, do: "tcp://docker-#{System.unique_integer([:positive])}.test:2375"

  defp container_json(id, session, service) do
    labels =
      %{
        "crowd_control.owner" => "node-a",
        "crowd_control.agent" => "sandboxd",
        "crowd_control.created_at" => "1000",
        "com.docker.compose.project" => "cc-#{session}",
        "com.docker.compose.service" => service
      }
      |> then(fn labels ->
        if session, do: Map.put(labels, "crowd_control.session", session), else: labels
      end)

    %{"Id" => id, "Labels" => labels}
  end

  # --- request lookups ---

  defp paths(requests, method), do: for(r <- requests, r.method == method, do: r.path)

  defp find(requests, method, path) do
    Enum.find(requests, &(&1.method == method and &1.path == path))
  end

  defp index(requests, method, path) do
    Enum.find_index(requests, &(&1.method == method and &1.path == path))
  end

  defp index(requests, method, path, service) do
    Enum.find_index(
      requests,
      &(&1.method == method and &1.path == path and
          String.ends_with?(&1.query["name"] || "", "-#{service}-1"))
    )
  end

  defp container_body(requests, service) do
    Enum.find_value(requests, fn r ->
      r.method == :post and r.path == "/containers/create" and
        String.ends_with?(r.query["name"] || "", "-#{service}-1") and r.body
    end)
  end

  defp network_body(requests, suffix) do
    Enum.find_value(requests, fn r ->
      r.method == :post and r.path == "/networks/create" and
        String.ends_with?(r.body["Name"] || "", suffix) and r.body
    end)
  end

  defp volume_body(requests), do: find(requests, :post, "/volumes/create").body

  defp connect_body(requests, network) do
    find(requests, :post, "/networks/#{network}/connect").body
  end

  defp started_order(requests) do
    ids =
      for r <- requests,
          r.method == :post,
          String.ends_with?(r.path, "/start"),
          do: r.path |> String.trim_leading("/containers/") |> String.trim_trailing("/start")

    Enum.map(ids, &String.replace_prefix(&1, "ctr-", ""))
  end
end
