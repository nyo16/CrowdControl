defmodule CrowdControl.Provider.DockerUnitTest do
  # Hermetic: every Docker Engine API call is answered by a stub adapter, so
  # these run in the default suite with no daemon. Everything needing a live
  # daemon lives in test/crowd_control/provider/docker_test.exs.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Docker.HostConfig
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Docker
  alias CrowdControl.Store

  # No @secret and no setup mutating :sandboxd_secret: test_helper.exs sets one
  # for the whole suite. A per-module secret raced every other async module that
  # derives a token from it.
  @session "abcdef0123456789abcdef0123456789"

  describe "egress is never inferred (blocker: silent full internet for untrusted code)" do
    test "refuses to acquire without an explicit :egress" do
      # The measured constraint: this provider cannot both publish the agent
      # port and block egress. Defaulting either way would hide which trade the
      # caller took, in exactly the scenario SECURITY.md warns about.
      assert {:error, {:docker, :egress_required}} =
               Docker.acquire(image: "sandbox:dev", session_key: @session)
    end

    test "rejects an unknown :egress value rather than treating it as a default" do
      assert {:error, {:docker, {:bad_egress, :none}}} =
               Docker.acquire(image: "sandbox:dev", session_key: @session, egress: :none)
    end

    test "the validation gate runs before any HTTP happens" do
      # An adapter that raises proves nothing reached the transport.
      adapter = fn _req -> raise "must not be called" end

      assert {:error, {:docker, :egress_required}} =
               Docker.acquire(image: "sandbox:dev", session_key: @session, req_adapter: adapter)
    end

    test ":allow adds no masquerade option; :no_nat disables masquerade" do
      {:ok, allow} = capture_requests(egress: :allow)
      {:ok, no_nat} = capture_requests(egress: :no_nat)

      refute Map.has_key?(network_body(allow), "Options")

      assert network_body(no_nat)["Options"] == %{
               "com.docker.network.bridge.enable_ip_masquerade" => "false"
             }
    end
  end

  describe "required options" do
    test "refuses without an image" do
      assert {:error, {:docker, :image_required}} =
               Docker.acquire(session_key: @session, egress: :allow)
    end

    test "refuses without a session key, which the token is derived from" do
      assert {:error, {:docker, :session_key_required}} =
               Docker.acquire(image: "sandbox:dev", egress: :allow)
    end
  end

  describe "agent credentials (blocker: a token in argv, a label, or a log)" do
    test "the token reaches the container through the create API's Env array" do
      {:ok, requests} = capture_requests(egress: :allow)

      env = container_body(requests)["Env"]
      expected = "CC_SANDBOXD_TOKEN=" <> Provider.token(@session)

      assert expected in env
    end

    test "the token is not in any label" do
      {:ok, requests} = capture_requests(egress: :allow)
      token = Provider.token(@session)

      for body <- [container_body(requests), network_body(requests)] do
        refute inspect(Map.get(body, "Labels", %{})) =~ token
      end
    end

    test "the token is not in the container name or the network name" do
      {:ok, requests} = capture_requests(egress: :allow)
      token = Provider.token(@session)

      refute network_body(requests)["Name"] =~ token
      refute inspect(container_request(requests).url) =~ token
    end

    test "the agent binds 0.0.0.0 inside the container, because the port is published" do
      {:ok, requests} = capture_requests(egress: :allow)

      # A published port is forwarded from *outside* the container, so an agent
      # on the container's own loopback would never receive it. The host-side
      # binding is what keeps it non-routable.
      assert "CC_SANDBOXD_BIND=0.0.0.0" in container_body(requests)["Env"]
    end
  end

  describe "port publishing (blocker: an agent port on every interface)" do
    test "always sends HostIp 127.0.0.1" do
      {:ok, requests} = capture_requests(egress: :allow)

      # Omitting HostIp yields TWO bindings, IPv4 and IPv6, on all interfaces.
      assert container_body(requests)["HostConfig"]["PortBindings"] == %{
               "8080/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => "0"}]
             }
    end

    test "exposes the agent port so the binding is not discarded" do
      {:ok, requests} = capture_requests(egress: :allow)
      assert container_body(requests)["ExposedPorts"] == %{"8080/tcp" => %{}}
    end

    test "honours a custom :agent_port in both places" do
      {:ok, requests} = capture_requests(egress: :allow, agent_port: 9999)

      assert container_body(requests)["ExposedPorts"] == %{"9999/tcp" => %{}}
      assert Map.has_key?(container_body(requests)["HostConfig"]["PortBindings"], "9999/tcp")
      assert "CC_SANDBOXD_PORT=9999" in container_body(requests)["Env"]
    end
  end

  describe "host port parsing (blocker: a binding Docker silently discarded)" do
    test "reads the assigned port from NetworkSettings.Ports" do
      json = %{"NetworkSettings" => %{"Ports" => ports("32768")}}
      assert {:ok, 32_768} = Docker.host_port_from_inspect(json, 8080)
    end

    test "a present key with a null value is not published" do
      # What an internal network actually returns. Naive list access raises here.
      json = %{"NetworkSettings" => %{"Ports" => %{"8080/tcp" => nil}}}

      assert {:error, {:docker, :agent_port_not_published}} =
               Docker.host_port_from_inspect(json, 8080)
    end

    test "an empty-string HostPort is not published" do
      # gateway_mode_ipv4=routed reports a binding it did not make.
      json = %{"NetworkSettings" => %{"Ports" => ports("")}}

      assert {:error, {:docker, :agent_port_not_published}} =
               Docker.host_port_from_inspect(json, 8080)
    end

    test "an empty Ports map means the container is not running" do
      json = %{"NetworkSettings" => %{"Ports" => %{}}}

      assert {:error, {:docker, :agent_port_not_published}} =
               Docker.host_port_from_inspect(json, 8080)
    end

    test "a missing NetworkSettings is an error, not a crash" do
      assert {:error, {:docker, :agent_port_not_published}} =
               Docker.host_port_from_inspect(%{}, 8080)
    end

    test "a non-numeric HostPort is rejected" do
      json = %{"NetworkSettings" => %{"Ports" => ports("http")}}

      assert {:error, {:docker, {:bad_host_port, "http"}}} =
               Docker.host_port_from_inspect(json, 8080)
    end

    test "acquire fails when the daemon publishes nothing, rather than hanging" do
      # The daemon answers 201/204 and reports no usable port: the exact silent
      # failure of an internal network. It must surface as a provider error.
      adapter = fn req ->
        respond(req, fn
          {:post, "/networks/create"} -> {201, %{"Id" => "net"}}
          {:post, "/containers/create"} -> {201, %{"Id" => "ctr"}}
          {:post, "/containers/ctr/start"} -> {204, ""}
          {:get, "/containers/ctr/json"} -> {200, %{"NetworkSettings" => %{"Ports" => %{}}}}
          {:delete, _} -> {204, ""}
        end)
      end

      assert {:error, {:docker, :agent_port_not_published}} = acquire(adapter, egress: :allow)
    end
  end

  describe "acquire rollback (blocker: a leaked container)" do
    test "a failed start deletes the container and the network" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      adapter = fn req ->
        Agent.update(agent, &[{req.method, URI.parse(to_string(req.url)).path} | &1])

        respond(req, fn
          {:post, "/networks/create"} -> {201, %{"Id" => "net"}}
          {:post, "/containers/create"} -> {201, %{"Id" => "ctr"}}
          {:post, "/containers/ctr/start"} -> {500, %{"message" => "no such image"}}
          {:delete, _} -> {204, ""}
        end)
      end

      assert {:error, {:docker, {:http_status, 500, _}}} = acquire(adapter, egress: :allow)

      calls = Agent.get(agent, &Enum.reverse(&1))
      assert {:delete, "/containers/ctr"} in calls
      assert {:delete, "/networks/cc-sbx-#{@session}"} in calls
    end

    test "a health timeout deletes the sandbox" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      adapter = fn req ->
        Agent.update(agent, &[{req.method, URI.parse(to_string(req.url)).path} | &1])

        respond(req, fn
          {:post, "/networks/create"} ->
            {201, %{"Id" => "net"}}

          {:post, "/containers/create"} ->
            {201, %{"Id" => "ctr"}}

          {:post, "/containers/ctr/start"} ->
            {204, ""}

          {:get, "/containers/ctr/json"} ->
            {200, %{"NetworkSettings" => %{"Ports" => ports("1")}}}

          {:get, "/v1/health"} ->
            {503, %{"error" => "not ready"}}

          {:delete, _} ->
            {204, ""}
        end)
      end

      assert {:error, {:sandboxd, {:ready_timeout, _}}} =
               acquire(adapter, egress: :allow, ready_timeout: 150)

      calls = Agent.get(agent, &Enum.reverse(&1))
      assert {:delete, "/containers/ctr"} in calls
    end
  end

  describe "release/1 (blocker: a teardown that fails on the second call)" do
    test "is idempotent across 404 on both resources" do
      adapter = fn req ->
        respond(req, fn {:delete, _} -> {404, %{"message" => "no such"}} end)
      end

      handle = handle(req_adapter: adapter)

      assert :ok = Docker.release(handle)
      assert :ok = Docker.release(handle)
    end

    test "deletes the container before the network, since a network in use is 403" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      adapter = fn req ->
        Agent.update(agent, &[URI.parse(to_string(req.url)).path | &1])
        respond(req, fn {:delete, _} -> {204, ""} end)
      end

      assert :ok = Docker.release(handle(req_adapter: adapter))

      assert ["/containers/ctr", "/networks/cc-sbx-#{@session}"] =
               Agent.get(agent, &Enum.reverse(&1))
    end

    test "tolerates a transport failure rather than raising in teardown" do
      # A Req adapter signals a transport failure by returning the exception in
      # place of a response, not an {:error, _} tuple.
      adapter = fn req -> {req, %Req.TransportError{reason: :econnrefused}} end
      assert :ok = Docker.release(handle(req_adapter: adapter))
    end

    test "is a no-op for a handle that never got a container" do
      assert :ok = Docker.release(%Docker{})
    end
  end

  describe "list_live/1 (blocker: reaping another owner's or another backend's sandbox)" do
    test "filters by owner, agent and stack shape" do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      adapter = fn req ->
        Agent.update(agent, fn _ -> URI.decode(to_string(req.url)) end)
        respond(req, fn {:get, "/containers/json"} -> {200, []} end)
      end

      assert {:ok, []} = Docker.list_live(req_adapter: adapter, owner: "node-a")

      url = Agent.get(agent, & &1)
      assert url =~ "crowd_control.owner=node-a"
      # Without the agent label this would also return Backend.Docker's FIFO
      # containers, which this provider cannot reconnect to or drive.
      assert url =~ "crowd_control.agent=sandboxd"
      # Without the stack label it would return Provider.Compose's containers,
      # which carry the same agent label — and the reaper would tear a stack
      # apart one container at a time, orphaning its networks and volumes.
      # Docker label filters cannot express absence, hence a positive term.
      assert url =~ "crowd_control.stack=single"
    end

    test "the create body carries the stack discriminator" do
      {:ok, requests} = capture_requests(egress: :allow)

      assert container_body(requests)["Labels"]["crowd_control.stack"] == "single"
    end

    test "lifts the session key and owner out of the labels" do
      adapter = fn req ->
        respond(req, fn
          {:get, "/containers/json"} ->
            {200,
             [
               %{
                 "Id" => "ctr1",
                 "Image" => "sandbox:dev",
                 "Labels" => %{
                   "crowd_control.session" => @session,
                   "crowd_control.owner" => "node-a",
                   "crowd_control.agent" => "sandboxd"
                 }
               }
             ]}
        end)
      end

      assert {:ok, [handle]} = Docker.list_live(req_adapter: adapter, owner: "node-a")
      assert handle.session_key == @session
      assert handle.owner == "node-a"
      # Derived, not stored: release/1 must be able to remove the network of a
      # sandbox it only learned about from a label.
      assert handle.network_name == "cc-sbx-#{@session}"
    end
  end

  describe "scrub/1 (blocker: a credential in a Store record on disk)" do
    test "drops every secret-bearing option from the persisted config" do
      handle =
        handle(
          api_key: "sk-real",
          session_token: "sess",
          env: %{"ANTHROPIC_API_KEY" => "sk-also-real"},
          auth_token: "auth",
          image: "sandbox:dev"
        )

      scrubbed = Docker.scrub(handle)

      for key <- Store.secret_keys() do
        refute Keyword.has_key?(scrubbed.config, key), "#{key} survived scrubbing"
      end

      refute inspect(scrubbed) =~ "sk-real"
      refute inspect(scrubbed) =~ "sk-also-real"
    end

    test "the scrubbed handle survives term_to_binary and stays usable" do
      handle = handle(api_key: "sk-real")

      round_tripped =
        handle |> Docker.scrub() |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert round_tripped.container_id == "ctr"
      assert round_tripped.session_key == @session
      refute inspect(round_tripped) =~ "sk-real"
    end

    test "no derived token is anywhere in the handle, scrubbed or not" do
      # The token is recomputed from session_key on every reconnect precisely so
      # that it never has to be stored.
      token = Provider.token(@session)
      handle = handle([])

      refute inspect(handle) =~ token
      refute inspect(Docker.scrub(handle)) =~ token
    end
  end

  describe "hardening (blocker: a sandbox weaker than the trusted container)" do
    test "the create body carries the shared hardening defaults" do
      {:ok, requests} = capture_requests(egress: :allow)
      host_config = container_body(requests)["HostConfig"]

      for {key, value} <- HostConfig.hardening_defaults() do
        assert host_config[key] == value, "#{key} was #{inspect(host_config[key])}"
      end
    end

    test "both call sites produce identical hardening from identical options" do
      # The drift this guards against is silent: a sandbox that lost
      # CapDrop: ALL looks exactly like one that did not.
      opts = [cpus: 1.5, memory: 512 * 1024 * 1024, readonly_rootfs: true]

      provider_side = HostConfig.build(opts, network_mode: "cc-sbx-x")
      backend_side = HostConfig.build(opts, network_mode: "none")

      assert Map.delete(provider_side, "NetworkMode") == Map.delete(backend_side, "NetworkMode")
    end

    test "the network is a per-sandbox bridge, not the default one" do
      {:ok, requests} = capture_requests(egress: :allow)

      assert container_body(requests)["HostConfig"]["NetworkMode"] == "cc-sbx-#{@session}"
      assert network_body(requests)["Driver"] == "bridge"
    end
  end

  # --- Helpers ---

  defp ports(host_port),
    do: %{"8080/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => host_port}]}

  defp handle(config) do
    %Docker{
      container_id: "ctr",
      network_name: "cc-sbx-#{@session}",
      image: "sandbox:dev",
      session_key: @session,
      owner: "node-a",
      config: config
    }
  end

  defp acquire(adapter, opts) do
    Docker.acquire(
      [image: "sandbox:dev", session_key: @session, owner: "node-a", req_adapter: adapter] ++ opts
    )
  end

  # Drives a full successful acquire against a stub daemon and returns every
  # request it made, so the request *bodies* can be asserted on directly.
  defp capture_requests(opts) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    port = Keyword.get(opts, :agent_port, 8080)

    adapter = fn req ->
      Agent.update(agent, &[req | &1])

      respond(req, fn
        {:post, "/networks/create"} ->
          {201, %{"Id" => "net"}}

        {:post, "/containers/create"} ->
          {201, %{"Id" => "ctr"}}

        {:post, "/containers/ctr/start"} ->
          {204, ""}

        {:get, "/containers/ctr/json"} ->
          {200,
           %{
             "NetworkSettings" => %{
               "Ports" => %{
                 "#{port}/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => "32768"}]
               }
             }
           }}

        {:get, "/v1/health"} ->
          {200, %{"ok" => true}}
      end)
    end

    assert {:ok, _handle, _endpoint} = acquire(adapter, opts)
    {:ok, Agent.get(agent, &Enum.reverse(&1))}
  end

  defp container_request(requests) do
    Enum.find(requests, fn req ->
      req.method == :post and URI.parse(to_string(req.url)).path == "/containers/create"
    end)
  end

  defp container_body(requests), do: decoded_body(container_request(requests))

  defp network_body(requests) do
    requests
    |> Enum.find(fn req ->
      req.method == :post and URI.parse(to_string(req.url)).path == "/networks/create"
    end)
    |> decoded_body()
  end

  defp decoded_body(%{body: body}) when is_binary(body), do: JSON.decode!(body)
  defp decoded_body(%{options: %{json: json}}), do: JSON.decode!(JSON.encode!(json))

  # Route a stubbed request by {method, path} and build a Req.Response. Any
  # unrouted call raises with the method and path, so a test that stubs the
  # wrong thing fails loudly instead of timing out.
  defp respond(req, router) do
    path = URI.parse(to_string(req.url)).path
    key = {req.method, path}

    {status, body} =
      try do
        router.(key)
      rescue
        FunctionClauseError ->
          reraise RuntimeError.exception("unstubbed Docker API call: #{inspect(key)}"),
                  __STACKTRACE__
      end

    {req, Req.Response.new(status: status, body: body)}
  end
end
