defmodule CrowdControl.Provider.ComposeTest do
  # Needs a live Docker daemon. Excluded by default (see test_helper.exs); run
  # with `mix test --include compose`.
  #
  # This is the test that earns the module's central claim. Everything else
  # about the stack is asserted hermetically in compose_unit_test.exs; the three
  # things only a real daemon can answer are:
  #
  #   * the sandbox, on an `Internal: true` network, genuinely has no egress;
  #   * it can still resolve and reach a sibling by network alias;
  #   * the host can reach the agent anyway, through the forwarder — including
  #     under concurrency, which is the one part of the network design that
  #     testing left open (`busybox nc -e` dropped two of three concurrent
  #     requests; `socat ... fork` is the replacement being verified here).
  use ExUnit.Case, async: false

  alias CrowdControl.Backend.Docker.API
  alias CrowdControl.Backend.Docker.Demux
  alias CrowdControl.Backend.Sandboxd.API, as: AgentAPI
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Compose

  @moduletag :compose
  @moduletag timeout: 180_000

  # Stands in for `sandboxd` and for a sidecar alike: a concurrent HTTP server
  # whose body and content type come from argv. A real sandboxd release would
  # need the image built, and nothing here is testing the agent — only the
  # network shape around it.
  @server ~S"""
  import http.server, socketserver, sys

  BODY = sys.argv[1].encode()
  CTYPE = sys.argv[2]


  class Handler(http.server.BaseHTTPRequestHandler):
      protocol_version = "HTTP/1.1"

      def do_GET(self):
          self.send_response(200)
          self.send_header("Content-Type", CTYPE)
          self.send_header("Content-Length", str(len(BODY)))
          self.end_headers()
          self.wfile.write(BODY)

      def log_message(self, *args):
          pass


  class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
      daemon_threads = True
      allow_reuse_address = True


  Server(("0.0.0.0", 8080), Handler).serve_forever()
  """

  # Reachability by IP literal, never by name: a DNS-only probe would have
  # reported the opposite of the truth on a no-SNAT network.
  @probe ~S"""
  import socket, sys

  try:
      socket.create_connection((sys.argv[1], int(sys.argv[2])), 3).close()
      print("REACHABLE")
  except Exception:
      print("BLOCKED")
  """

  @agent_image "python:3.13-slim"
  @forwarder_image "alpine/socat:1.8.1.3"
  @health_probe ~S|python3 -c "import socket;socket.create_connection(('127.0.0.1',8080),2)"|

  setup_all do
    config = [timeout: 30_000]
    for image <- [@agent_image, @forwarder_image], do: :ok = ensure_image(config, image)
    :ok
  end

  setup do
    previous = Application.get_env(:crowd_control, :sandboxd_secret)
    Application.put_env(:crowd_control, :sandboxd_secret, "compose-secret-32-bytes-minimum!!")

    owner = "cc-compose-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
    session = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    on_exit(fn ->
      case Compose.list_live(owner: owner, timeout: 30_000) do
        {:ok, handles} -> Enum.each(handles, &Compose.release/1)
        _ -> :ok
      end

      if previous do
        Application.put_env(:crowd_control, :sandboxd_secret, previous)
      else
        Application.delete_env(:crowd_control, :sandboxd_secret)
      end
    end)

    {:ok, owner: owner, session: session, opts: base_opts(owner, session)}
  end

  describe "a two-service stack (blocker: no shape gives both no-egress and a reachable agent)" do
    test "the host reaches the agent, the sandbox reaches nothing", context do
      {:ok, handle, endpoint} = Compose.acquire(context.opts)

      try do
        # 1. The host can reach the agent. `acquire/1` only returns after
        #    GET /v1/health answered through the forwarder, so this is already
        #    proven -- assert it anyway, since it is half the claim.
        assert AgentAPI.health(endpoint) == :ok
        assert endpoint.base_url =~ ~r{^http://127\.0\.0\.1:\d+$}

        sandbox = container(handle, "sandbox")
        forwarder = container(handle, "forwarder")

        # 2. The sandbox has no egress. Internal networks have no default route
        #    at all, so this is structural rather than a missing NAT rule.
        assert probe(context.opts, sandbox, "1.1.1.1", 443) == "BLOCKED"
        assert probe(context.opts, sandbox, "8.8.8.8", 53) == "BLOCKED"

        # 3. But it can reach its sibling by alias, which is what makes an
        #    egress proxy on this network usable at all.
        assert probe(context.opts, sandbox, "sidecar", 8080) == "REACHABLE"

        # 4. The forwarder is the blast radius, and it has no internet either:
        #    its publish network disables ip masquerade. Probed with socat
        #    rather than python, because that image carries socat and a busybox
        #    shell and nothing else — same measurement, a TCP connect to an IP
        #    literal.
        assert socat_probe(context.opts, forwarder, "1.1.1.1", 443) == "BLOCKED"

        # And it can reach the sandbox, which is the whole reason it exists.
        assert socat_probe(context.opts, forwarder, "sandbox", 8080) == "REACHABLE"
      after
        Compose.release(handle)
      end
    end

    test "the forwarder serves concurrent requests", context do
      # The one component the network spike could not prove. A single-slot
      # forwarder dropped two of three concurrent requests, and a session holds
      # a chunked stream open for its whole life.
      {:ok, handle, endpoint} = Compose.acquire(context.opts)

      try do
        results =
          1..12
          |> Task.async_stream(fn _ -> AgentAPI.health(endpoint) end,
            max_concurrency: 12,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.all?(results, &(&1 == :ok)),
               "forwarder dropped #{Enum.count(results, &(&1 != :ok))} of 12"
      after
        Compose.release(handle)
      end
    end

    test "the sandbox publishes nothing and the forwarder publishes on loopback", context do
      {:ok, handle, _endpoint} = Compose.acquire(context.opts)

      try do
        {:ok, sandbox} = inspect_container(context.opts, container(handle, "sandbox"))
        {:ok, forwarder} = inspect_container(context.opts, container(handle, "forwarder"))

        # NetworkSettings is the only source of truth: PortBindings echoes the
        # request even when the binding was discarded.
        assert sandbox["NetworkSettings"]["Ports"] == %{}
        assert Map.keys(sandbox["NetworkSettings"]["Networks"]) == [handle.sandbox_network]

        assert [%{"HostIp" => "127.0.0.1", "HostPort" => port}] =
                 forwarder["NetworkSettings"]["Ports"]["8080/tcp"]

        assert {_int, ""} = Integer.parse(port)

        assert Enum.sort(Map.keys(forwarder["NetworkSettings"]["Networks"])) ==
                 Enum.sort([handle.sandbox_network, handle.publish_network])
      after
        Compose.release(handle)
      end
    end

    test "the agent token reaches the sandbox and nothing else", context do
      {:ok, handle, _endpoint} = Compose.acquire(context.opts)

      try do
        token = Provider.token(context.session)
        {:ok, sandbox} = inspect_container(context.opts, container(handle, "sandbox"))
        {:ok, sidecar} = inspect_container(context.opts, container(handle, "sidecar"))

        assert "CC_SANDBOXD_TOKEN=#{token}" in sandbox["Config"]["Env"]
        assert "CC_SANDBOXD_BIND=0.0.0.0" in sandbox["Config"]["Env"]

        refute Enum.any?(sidecar["Config"]["Env"] || [], &(&1 =~ token))
        refute inspect(sandbox["Config"]["Labels"]) =~ token
      after
        Compose.release(handle)
      end
    end

    test "the network posture is what was asked for", context do
      {:ok, handle, _endpoint} = Compose.acquire(context.opts)

      try do
        {:ok, sbx} = API.request(context.opts, :get, "/networks/#{handle.sandbox_network}")
        {:ok, pub} = API.request(context.opts, :get, "/networks/#{handle.publish_network}")

        assert sbx["Internal"] == true
        refute pub["Internal"]

        assert pub["Options"]["com.docker.network.bridge.enable_ip_masquerade"] == "false"

        # Nothing asked for egress, so no NAT bridge exists at all.
        assert {:error, {:docker, {:not_found, _}}} =
                 API.request(context.opts, :get, "/networks/#{handle.egress_network}")
      after
        Compose.release(handle)
      end
    end

    test "a :ready healthcheck gates the start, and the field name is right", context do
      # The Engine API's container-config field is `Healthcheck` while its type
      # is `HealthConfig`; getting that wrong is silent, because an ignored
      # healthcheck leaves `State.Health` absent and the poll would just time
      # out.
      {:ok, handle, _endpoint} = Compose.acquire(context.opts)

      try do
        {:ok, sidecar} = inspect_container(context.opts, container(handle, "sidecar"))

        assert sidecar["Config"]["Healthcheck"]["Test"] == ["CMD-SHELL", @health_probe]
        assert sidecar["Config"]["Healthcheck"]["Interval"] == 500_000_000
        assert sidecar["State"]["Health"]["Status"] == "healthy"
      after
        Compose.release(handle)
      end
    end
  end

  describe "release/1 (blocker: a named volume that outlives the whole stack)" do
    test "takes containers, networks and named volumes with it", context do
      {:ok, handle, _endpoint} = Compose.acquire(context.opts)

      assert {:ok, _} = API.request(context.opts, :get, "/volumes/#{handle.project}-workspace")

      assert Compose.release(handle) == :ok

      for id <- Enum.map(handle.containers, &elem(&1, 1)) do
        assert {:error, {:docker, {:not_found, _}}} = inspect_container(context.opts, id)
      end

      for network <- [handle.sandbox_network, handle.publish_network] do
        assert {:error, {:docker, {:not_found, _}}} =
                 API.request(context.opts, :get, "/networks/#{network}")
      end

      # `DELETE /containers/{id}?v=true` removes anonymous volumes only, so this
      # one needed its own call.
      assert {:error, {:docker, {:not_found, _}}} =
               API.request(context.opts, :get, "/volumes/#{handle.project}-workspace")
    end

    test "is idempotent, and a second call is not an error", context do
      {:ok, handle, _endpoint} = Compose.acquire(context.opts)

      assert Compose.release(handle) == :ok
      assert Compose.release(handle) == :ok
    end
  end

  describe "list_live/1 (blocker: a reaper that reaps containers instead of stacks)" do
    test "returns one handle for the whole stack", context do
      {:ok, handle, _endpoint} = Compose.acquire(context.opts)

      try do
        assert {:ok, [live]} = Compose.list_live(owner: context.owner, timeout: 30_000)

        assert live.session_key == context.session
        assert live.project == handle.project
        # Three containers, one handle.
        assert length(live.containers) == 3

        assert Enum.sort(Enum.map(live.containers, &elem(&1, 0))) ==
                 ["forwarder", "sandbox", "sidecar"]
      after
        Compose.release(handle)
      end
    end

    test "a rebuilt handle can tear the stack down, volumes included", context do
      {:ok, handle, _endpoint} = Compose.acquire(context.opts)
      {:ok, [live]} = Compose.list_live(owner: context.owner, timeout: 30_000)

      # The reaper never sees the acquire-path handle, so the volume list has to
      # be recoverable from labels alone.
      assert live.volumes == []
      assert Compose.release(live) == :ok

      assert {:error, {:docker, {:not_found, _}}} =
               API.request(context.opts, :get, "/volumes/#{handle.project}-workspace")
    end
  end

  describe "reconnect/1 (blocker: a persisted host port)" do
    test "re-reads the port, which changes on every start", context do
      {:ok, handle, endpoint} = Compose.acquire(context.opts)

      try do
        forwarder = container(handle, "forwarder")
        {:ok, _} = API.request(context.opts, :post, "/containers/#{forwarder}/restart")

        assert {:ok, _handle, reconnected} = Compose.reconnect(handle)
        assert AgentAPI.health(reconnected) == :ok

        # Not an assertion about a *different* port -- the daemon may hand back
        # the same one -- but about the endpoint being rebuilt from the daemon
        # rather than replayed from the handle.
        assert reconnected.base_url =~ ~r{^http://127\.0\.0\.1:\d+$}
        assert reconnected.token == endpoint.token
      after
        Compose.release(handle)
      end
    end
  end

  # --- Helpers ---

  defp base_opts(owner, session) do
    [
      image: @agent_image,
      forwarder_image: @forwarder_image,
      session_key: session,
      owner: owner,
      timeout: 30_000,
      ready_timeout: 60_000,
      health_timeout: 60_000,
      volumes: [%{name: "workspace"}],
      ready: %{
        "sidecar" => %{
          test: ["CMD-SHELL", @health_probe],
          interval_ms: 500,
          timeout_ms: 2_000,
          retries: 20
        }
      },
      services: [
        %{
          name: "sandbox",
          image: @agent_image,
          entrypoint: ["python3"],
          command: ["-c", @server, ~s({"ok":true}), "application/json"],
          volumes: [%{name: "workspace", target: "/workspace"}]
        },
        %{
          name: "sidecar",
          image: @agent_image,
          egress: :none,
          entrypoint: ["python3"],
          command: ["-c", @server, "SIDECAR-OK", "text/plain"]
        }
      ]
    ]
  end

  defp container(handle, service) do
    {^service, id} = List.keyfind(handle.containers, service, 0)
    id
  end

  defp inspect_container(config, id), do: API.request(config, :get, "/containers/#{id}/json")

  defp probe(config, id, host, port) do
    config
    |> exec(id, ["python3", "-c", @probe, host, to_string(port)])
    |> String.trim()
  end

  # socat's own connect, for the forwarder image, which has no python. `-u`
  # with /dev/null closes immediately, so a zero exit means the connect
  # succeeded and nothing else.
  defp socat_probe(config, id, host, port) do
    command =
      "socat -u /dev/null TCP:#{host}:#{port},connect-timeout=3 >/dev/null 2>&1" <>
        " && echo REACHABLE || echo BLOCKED"

    config |> exec(id, ["sh", "-c", command]) |> String.trim()
  end

  # Same shape as docker_test.exs: create an exec, start it undetached, demux
  # the multiplexed stream.
  defp exec(config, id, cmd) do
    {:ok, %{"Id" => exec_id}} =
      API.request(config, :post, "/containers/#{id}/exec",
        json: %{"AttachStdout" => true, "AttachStderr" => true, "Tty" => false, "Cmd" => cmd}
      )

    {:ok, raw} =
      API.request(config, :post, "/exec/#{exec_id}/start",
        json: %{"Detach" => false, "Tty" => false},
        decode_body: false
      )

    {payloads, _state} = Demux.feed(Demux.new(), raw)
    IO.iodata_to_binary(payloads)
  end

  # The provider deliberately does not pull: `POST /containers/create` 404s on a
  # missing image and the caller owns its registry policy. The test owns its
  # fixtures.
  defp ensure_image(config, image) do
    case API.request(config, :get, "/images/#{image}/json") do
      {:ok, _} ->
        :ok

      _ ->
        [repo, tag] = String.split(image, ":", parts: 2)

        {:ok, _} =
          API.request(config, :post, "/images/create",
            params: [fromImage: repo, tag: tag],
            decode_body: false,
            receive_timeout: 300_000
          )

        :ok
    end
  end
end
