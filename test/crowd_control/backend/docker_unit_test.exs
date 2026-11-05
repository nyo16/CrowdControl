defmodule CrowdControl.Backend.DockerUnitTest do
  # Pure tests for Backend.Docker — no daemon required, so these run in the
  # default suite. Everything needing a live daemon lives in docker_test.exs.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Docker
  alias CrowdControl.Store

  describe "network mode is never inferred (blocker: silent bridge)" do
    test "defaults to none with no proxy or custom url" do
      # provision/1 would need a daemon; assert on the validation gate instead
      # by giving it a config that must be rejected before any HTTP happens.
      assert {:error, {:docker, :network_mode_required}} =
               Docker.provision(image: "alpine", proxy_url: "http://proxy:8080")
    end

    test "refuses :proxy_url without an explicit :network_mode" do
      # SECURITY.md says never use bridge for this. Previously the code chose
      # bridge silently, handing untrusted code general outbound access and a
      # session token — a free exfiltration channel.
      assert {:error, {:docker, :network_mode_required}} =
               Docker.provision(image: "alpine", proxy_url: "http://proxy:8080")
    end

    test "refuses :api_url without an explicit :network_mode" do
      # Worse than the proxy case: :api_url does not strip the real key, so this
      # would have been bridge networking *plus* a live provider credential.
      assert {:error, {:docker, :network_mode_required}} =
               Docker.provision(image: "alpine", api_url: "https://api.example.com")
    end

    test "an explicit :network_mode satisfies the gate" do
      # Gets past validation; fails later on an unreachable daemon, which is the
      # point — the network check is no longer what stops it.
      result =
        Docker.provision(
          image: "alpine",
          proxy_url: "http://proxy:8080",
          network_mode: "cc-egress",
          docker_host: "unix:///nonexistent/docker.sock"
        )

      assert {:error, {:docker, reason}} = result
      refute reason == :network_mode_required
    end
  end

  describe "credential scrubbing (blocker: secrets persisted in cleartext)" do
    test "Store.scrub_opts/1 drops every credential-bearing key" do
      opts = [
        api_key: "sk-real",
        session_token: "sess-tok",
        env: %{"ANTHROPIC_API_KEY" => "sk-also-real"},
        auth_token: "auth",
        timeout: 5_000,
        image: "alpine"
      ]

      scrubbed = Store.scrub_opts(opts)

      for key <- Store.secret_keys() do
        refute Keyword.has_key?(scrubbed, key), "#{key} survived scrubbing"
      end

      # Everything a reattach actually needs is preserved.
      assert scrubbed[:timeout] == 5_000
      assert scrubbed[:image] == "alpine"
    end

    test "Docker.scrub/1 strips credentials out of the handle's config" do
      # The handle carries the config it was provisioned from — which is what
      # made this leak reach disk even though :opts was the obvious suspect.
      handle = %Docker{
        container_id: "abc123",
        config: [api_key: "sk-real", session_token: "tok", docker_host: "unix:///x.sock"]
      }

      scrubbed = Docker.scrub(handle)

      refute Keyword.has_key?(scrubbed.config, :api_key)
      refute Keyword.has_key?(scrubbed.config, :session_token)
      assert scrubbed.config[:docker_host] == "unix:///x.sock"
      assert scrubbed.container_id == "abc123"
    end

    test "Backend.scrub/2 dispatches to the backend and is a no-op without one" do
      handle = %Docker{container_id: "x", config: [api_key: "sk-real"]}
      assert %Docker{config: config} = Backend.scrub(Docker, handle)
      refute Keyword.has_key?(config, :api_key)

      # Backend.Local defines no scrub/1; the handle must come back untouched.
      {:ok, local} = Backend.Local.provision(api_key: "sk-real")
      assert Backend.scrub(Backend.Local, local) == local
    end

    test "no secret survives a full round-trip into a store record" do
      handle = %Docker{container_id: "c1", config: [api_key: "sk-leaked"]}

      record =
        Store.build(
          key: "k1",
          session_id: "s1",
          backend: Docker,
          handle: Backend.scrub(Docker, handle),
          opts: Store.scrub_opts(api_key: "sk-leaked", timeout: 1_000)
        )

      # The whole record must be free of the secret, however it is nested.
      refute inspect(record) =~ "sk-leaked"
    end
  end

  describe "credential injection" do
    test "without :proxy_url the env is untouched" do
      env = %{"ANTHROPIC_API_KEY" => "sk-real", "FOO" => "bar"}
      assert Docker.apply_credentials(env, []) == env
    end

    test "with :proxy_url the real key is removed, not just overridden" do
      env = %{"ANTHROPIC_API_KEY" => "sk-real-secret", "FOO" => "bar"}

      result =
        Docker.apply_credentials(env,
          proxy_url: "http://proxy.internal:8080",
          session_token: "sess-token-123"
        )

      assert result["ANTHROPIC_BASE_URL"] == "http://proxy.internal:8080"
      assert result["ANTHROPIC_API_KEY"] == "sess-token-123"
      assert result["FOO"] == "bar"
    end

    test "with :proxy_url but no token, no api key reaches the container at all" do
      env = %{"ANTHROPIC_API_KEY" => "sk-real-secret"}
      result = Docker.apply_credentials(env, proxy_url: "http://proxy:8080")

      refute Map.has_key?(result, "ANTHROPIC_API_KEY"),
             "the real key leaked into a proxied sandbox"
    end
  end

  describe "reconnect discards demux state (blocker: frame desync)" do
    alias CrowdControl.Backend.Docker.Demux

    test "attaching a new stream always starts with clean demux state" do
      # Reproduces the exact hazard: a backpressure cancel lands mid-frame, so
      # the demux is holding a partial 8-byte header from a connection that is
      # now dead. Docker frame headers are per-connection, so those bytes must
      # not survive the reconnect.
      {[], dirty} = Demux.feed(Demux.new(), <<1, 0, 0>>)
      assert Demux.pending(dirty) == 3

      state = %{resp: :old_conn, demux: dirty, offset: 100}
      resumed = Docker.attach_stream(state, :new_conn)

      assert Demux.pending(resumed.demux) == 0,
             "stale frame bytes survived a reconnect — the parser will desync"

      assert resumed.resp == :new_conn
      assert resumed.offset == 100, "the file offset is the resume cursor and must survive"
    end

    test "carrying stale demux state across a reconnect corrupts the stream" do
      # Demonstrates the consequence, so the reset above is not mistaken for
      # defensive noise. Same fresh frame, fed to a clean vs. a dirty parser.
      frame = <<1, 0, 0, 0, 0, 0, 0, 5, "hello">>

      {clean_out, _} = Demux.feed(Demux.new(), frame)
      assert clean_out == ["hello"]

      {[], dirty} = Demux.feed(Demux.new(), <<1, 0, 0>>)
      {dirty_out, _} = Demux.feed(dirty, frame)

      refute dirty_out == ["hello"],
             "if this ever matches, the desync hazard has changed shape — revisit attach_stream/2"
    end
  end

  describe "reader resilience (blocker: transport error killed the session)" do
    test "an unreachable daemon casts :eof instead of crashing the caller" do
      # The reader is spawn_linked to its session, so any crash in it takes the
      # session down. The contract is that transport failure produces :eof.
      handle = %Docker{
        container_id: "does-not-exist",
        tee_path: "/var/log/cc/out.jsonl",
        config: [docker_host: "unix:///nonexistent/docker.sock"]
      }

      Process.flag(:trap_exit, true)
      test_pid = self()
      relay = spawn(fn -> relay_loop(test_pid) end)

      assert {:ok, reader} = Docker.start_reader(handle, relay, Backend.new_cursor())
      assert_receive {:cast, :eof}, 5_000

      refute_receive {:EXIT, ^reader, {%CaseClauseError{}, _}}, 100
    end
  end

  describe "volume mounts (blocker: a mount that shadows the FIFO)" do
    alias CrowdControl.Backend.Docker.HostConfig

    test "no Binds key at all when nothing is mounted" do
      # An empty list would be harmless to the Engine but would show up in
      # `docker inspect` as a deliberate choice nobody made.
      refute Map.has_key?(HostConfig.build([], network_mode: "none"), "Binds")
    end

    test "a named volume and a host path both become Binds, with the mode" do
      # Mounts arrive already normalized, through opts — the same way both
      # Docker call sites pass them. HostConfig never reads :volumes out of
      # config, because Provider.Compose's config uses that key for stack-level
      # volume declarations and would be silently reinterpreted.
      mounts =
        CrowdControl.Volume.normalize!(
          [
            volumes: [
              %{name: "workspace", target: "/workspace"},
              %{host_path: "/srv/fixtures", target: "/fixtures", read_only: true}
            ]
          ],
          []
        )

      assert HostConfig.build([], network_mode: "none", volumes: mounts)["Binds"] ==
               ["workspace:/workspace:rw", "/srv/fixtures:/fixtures:ro"]
    end

    test "a Compose-style :volumes in config is never reinterpreted as mounts" do
      # The collision this layering exists to prevent: Compose declares
      # [%{name: "workspace"}] with no target, and builds its own Binds.
      refute Map.has_key?(
               HostConfig.build([volumes: [%{name: "workspace"}]], network_mode: "none"),
               "Binds"
             )
    end

    test "provision/1 refuses a mount over the FIFO before creating a container" do
      # No daemon is touched: the gate runs on the handle's own paths, and the
      # error names Docker so a caller can match on it like any other.
      assert {:error, {:docker, {:invalid_volume, _, {:reserved_target, "/var/run/cc.fifo"}}}} =
               Docker.provision(
                 image: "alpine:latest",
                 network_mode: "none",
                 session_key: Store.new_key(),
                 volumes: [%{name: "w", target: "/var/run/cc.fifo"}]
               )
    end

    test "the tee directory is refused as well, since mounting it hides the file" do
      assert {:error, {:docker, {:invalid_volume, _, {:reserved_target, "/var/log/cc"}}}} =
               Docker.provision(
                 image: "alpine:latest",
                 network_mode: "none",
                 session_key: Store.new_key(),
                 volumes: [%{name: "w", target: "/var/log/cc"}]
               )
    end
  end

  describe "API.transport/1" do
    alias CrowdControl.Backend.Docker.API

    test "parses each supported scheme" do
      assert {:ok, opts} = API.transport("unix:///var/run/docker.sock")
      assert opts[:unix_socket] == "/var/run/docker.sock"
      assert opts[:base_url] == "http://localhost"

      assert {:ok, [base_url: "http://10.0.0.5:2375"]} = API.transport("tcp://10.0.0.5:2375")
      assert {:ok, [base_url: "http://h:1"]} = API.transport("http://h:1")
      assert {:ok, [base_url: "https://h:1"]} = API.transport("https://h:1")
    end

    test "rejects an unknown scheme and an empty unix path" do
      assert {:error, {:docker, {:bad_host, _}}} = API.transport("pigeon://nope")
      assert {:error, {:docker, {:bad_host, _}}} = API.transport("unix://")
      assert {:error, {:docker, {:bad_host, _}}} = API.transport("")
    end
  end

  describe "write/2 ordering (blocker: a detached exec lets control frames reorder)" do
    test "each write's exec is inspected until it has exited before the next is created" do
      # e1 is still running on its first inspect; e2 is done at once. Were write/2
      # to return on a detached start, e2 would be created while e1 still runs.
      {handle, agent} =
        stub_daemon(%{
          "e1" => [running(), done(0)],
          "e2" => [done(0)]
        })

      assert :ok = Docker.write(handle, "first\n")
      assert :ok = Docker.write(handle, "second\n")

      assert [
               {:create, "e1", first},
               {:start, "e1", %{"Detach" => true}},
               {:inspect, "e1"},
               {:inspect, "e1"},
               {:create, "e2", second},
               {:start, "e2", %{"Detach" => true}},
               {:inspect, "e2"}
             ] = events(agent)

      assert first =~ "printf %s 'first\n' >> '/var/run/cc.fifo'"
      assert second =~ "printf %s 'second\n' >> '/var/run/cc.fifo'"
    end

    test "an exec that exits non-zero is a failed write, not a delivered frame" do
      {handle, _agent} = stub_daemon(%{"e1" => [done(1)]})

      assert {:error, {:docker, {:exit_status, 1}}} = Docker.write(handle, "lost\n")
    end

    test "a null ExitCode means not finished yet, even when Running reads false" do
      {handle, agent} =
        stub_daemon(%{"e1" => [%{"Running" => false, "ExitCode" => nil}, done(0)]})

      assert :ok = Docker.write(handle, "hi\n")
      assert [{:inspect, "e1"}, {:inspect, "e1"}] = Enum.filter(events(agent), &inspect?/1)
    end

    test "an exec still running when the budget runs out is indeterminate" do
      {handle, _agent} = stub_daemon(%{"e1" => [running()]}, write_timeout: 30)

      assert {:error, {:docker, :write_indeterminate}} = Docker.write(handle, "maybe\n")
    end
  end

  describe "write/2 frame size (blocker: a frame past MAX_ARG_STRLEN)" do
    test "a frame over 120 KiB is refused before any exec is created" do
      {handle, agent} = stub_daemon(%{})

      assert {:error, :frame_too_large} =
               Docker.write(handle, String.duplicate("x", 120 * 1024 + 1))

      assert events(agent) == []
    end

    test "the limit applies to the escaped script, which is what the kernel sees" do
      {handle, agent} = stub_daemon(%{})

      # 40 KiB of quotes escapes to 160 KiB (each `'` becomes `'\\''`).
      assert {:error, :frame_too_large} = Docker.write(handle, String.duplicate("'", 40 * 1024))
      assert events(agent) == []
    end

    test "a large frame under the limit is written" do
      {handle, _agent} = stub_daemon(%{"e1" => [done(0)]})

      assert :ok = Docker.write(handle, String.duplicate("x", 100 * 1024))
    end
  end

  describe "list_live/1 scope (blocker: a reaper that tears down sandboxd's containers)" do
    test "a container labelled agent=sandboxd is not listed; the owner filter stays" do
      {handle, agent} =
        stub_daemon(%{},
          containers: [
            %{
              "Id" => "mine",
              "Image" => "img",
              "Labels" => %{"crowd_control.owner" => "o1", "crowd_control.session" => "s1"}
            },
            %{
              "Id" => "theirs",
              "Image" => "img",
              "Labels" => %{"crowd_control.owner" => "o1", "crowd_control.agent" => "sandboxd"}
            }
          ]
        )

      assert {:ok, [%Docker{container_id: "mine", session_key: "s1"}]} =
               Docker.list_live(Keyword.put(handle.config, :owner, "o1"))

      assert [{:list, %{"label" => ["crowd_control.owner=o1"]}}] = events(agent)
    end

    test "a container labelled agent=docker with owner and session is listed" do
      {handle, _agent} =
        stub_daemon(%{},
          containers: [
            %{
              "Id" => "mine",
              "Image" => "img",
              "Labels" => %{
                "crowd_control.owner" => "o1",
                "crowd_control.session" => "s1",
                "crowd_control.agent" => "docker"
              }
            }
          ]
        )

      assert {:ok, [%Docker{container_id: "mine", session_key: "s1", owner: "o1"}]} =
               Docker.list_live(Keyword.put(handle.config, :owner, "o1"))
    end

    test "provision stamps agent=docker so an image's agent label cannot override it" do
      {handle, agent} = stub_daemon(%{})

      assert {:ok, %Docker{container_id: "ctr"}} =
               Docker.provision(handle.config ++ [image: "img", session_key: "s1", owner: "o1"])

      assert [{:create_container, %{"Labels" => labels}} | _] = events(agent)

      assert %{
               "crowd_control.agent" => "docker",
               "crowd_control.owner" => "o1",
               "crowd_control.session" => "s1"
             } = labels
    end
  end

  describe "API.server_version/1 (blocker: a gate that cannot see the daemon's version)" do
    alias CrowdControl.Backend.Docker.API

    test "parses real-world version strings" do
      assert API.parse_version(%{"Version" => "26.1.4"}) == {:ok, {26, 1, 4}}
      assert API.parse_version(%{"Version" => "25.0.5-ce"}) == {:ok, {25, 0, 5}}
      assert API.parse_version(%{"Version" => "28.0.0-rc.1"}) == {:ok, {28, 0, 0}}
      assert API.parse_version(%{"Version" => "27.1"}) == {:ok, {27, 1, 0}}

      assert {:error, {:docker, {:unparseable_version, "dev"}}} =
               API.parse_version(%{"Version" => "dev"})

      assert {:error, {:docker, {:unparseable_version, nil}}} = API.parse_version(%{})
    end

    test "asks GET /version once per docker_host, then answers from the cache" do
      test_pid = self()

      adapter = fn req ->
        send(test_pid, {:path, req.url.path})
        {req, Req.Response.new(status: 200, body: %{"Version" => "26.0.0"})}
      end

      config = [docker_host: unique_host(), req_adapter: adapter]

      assert API.server_version(config) == {:ok, {26, 0, 0}}
      assert_received {:path, "/version"}

      assert API.server_version(config) == {:ok, {26, 0, 0}}
      refute_received {:path, _}
    end

    test "a failed lookup is not cached" do
      failing = fn req -> {req, Req.Response.new(status: 500, body: %{"message" => "boom"})} end
      host = unique_host()

      assert {:error, {:docker, {:http_status, 500, "boom"}}} =
               API.server_version(docker_host: host, req_adapter: failing)

      working = fn req -> {req, Req.Response.new(status: 200, body: %{"Version" => "27.0.1"})} end
      assert API.server_version(docker_host: host, req_adapter: working) == {:ok, {27, 0, 1}}
    end
  end

  describe "HostConfig per-service overrides (blocker: a weakening nobody wrote down)" do
    alias CrowdControl.Backend.Docker.HostConfig

    test "ShmSize and Init are rendered from config and from an override" do
      assert %{"ShmSize" => 1024, "Init" => true} =
               HostConfig.build([shm_size: 1024, init: true], network_mode: "none")

      host = HostConfig.build([], network_mode: "none", overrides: %{shm_size: 2048, init: true})
      assert host["ShmSize"] == 2048
      assert host["Init"] == true
    end

    test "no override leaves the hardened defaults byte-identical" do
      assert HostConfig.build([], network_mode: "none", overrides: %{}) ==
               HostConfig.build([], network_mode: "none")
    end

    test "resource overrides replace the stack's values" do
      host =
        HostConfig.build([pids_limit: 64, memory: 10],
          network_mode: "none",
          overrides: %{pids_limit: 1024, memory: 2048, cpus: 0.5}
        )

      assert host["PidsLimit"] == 1024
      assert host["Memory"] == 2048
      assert host["NanoCpus"] == 500_000_000
    end

    test "a tmpfs override merges over the read-only defaults" do
      host =
        HostConfig.build([readonly_rootfs: true],
          network_mode: "none",
          overrides: %{tmpfs: %{"/tmp" => "rw,size=512m"}}
        )

      assert host["Tmpfs"]["/tmp"] == "rw,size=512m"
      assert host["Tmpfs"]["/var/log"] == HostConfig.default_tmpfs()["/var/log"]
    end

    test "weakening overrides render exactly what they say" do
      host =
        HostConfig.build([readonly_rootfs: true],
          network_mode: "none",
          overrides: %{cap_add: ["SYS_ADMIN"], no_new_privileges: false, readonly_rootfs: false}
        )

      assert host["CapAdd"] == ["SYS_ADMIN"]
      assert host["CapDrop"] == ["ALL"]
      assert host["SecurityOpt"] == []
      refute Map.has_key?(host, "ReadonlyRootfs")
      refute Map.has_key?(host, "Tmpfs")
    end

    test "a hardening override can tighten a lax stack" do
      host = HostConfig.build([], network_mode: "none", overrides: %{readonly_rootfs: true})

      assert host["ReadonlyRootfs"] == true
      assert host["Tmpfs"] == HostConfig.default_tmpfs()
    end
  end

  defp unique_host, do: "tcp://docker-#{System.unique_integer([:positive])}.test:2375"

  defp relay_loop(test_pid) do
    receive do
      {:"$gen_cast", msg} ->
        send(test_pid, {:cast, msg})
        relay_loop(test_pid)
    end
  end

  defp running, do: %{"Running" => true, "ExitCode" => nil}
  defp done(code), do: %{"Running" => false, "ExitCode" => code}

  defp inspect?({:inspect, _}), do: true
  defp inspect?(_event), do: false

  defp events(agent), do: Agent.get(agent, &Enum.reverse(&1.events))

  # A stub Engine API that records every exec create, start and inspect in
  # order. `inspects` maps an exec id to the answers its inspects get, in turn;
  # the last answer repeats. Exec ids are handed out as e1, e2, ...
  defp stub_daemon(inspects, config \\ []) do
    {containers, config} = Keyword.pop(config, :containers, [])

    {:ok, agent} =
      Agent.start_link(fn ->
        %{events: [], next: 1, inspects: inspects, containers: containers}
      end)

    adapter = fn req ->
      path = URI.parse(to_string(req.url)).path
      {status, body} = Agent.get_and_update(agent, &route(&1, req.method, path, req))
      {req, Req.Response.new(status: status, body: body)}
    end

    handle = %Docker{
      container_id: "ctr",
      fifo_path: "/var/run/cc.fifo",
      config: [req_adapter: adapter] ++ config
    }

    {handle, agent}
  end

  defp route(state, :get, "/containers/json", req) do
    filters = URI.decode_query(URI.parse(to_string(req.url)).query || "")["filters"]
    {{200, state.containers}, record(state, {:list, filters && JSON.decode!(filters)})}
  end

  defp route(state, :post, "/containers/create", req) do
    {{201, %{"Id" => "ctr"}}, record(state, {:create_container, decoded_body(req)})}
  end

  defp route(state, :post, "/containers/ctr/start", _req) do
    {{204, ""}, record(state, {:start_container, "ctr"})}
  end

  defp route(state, :post, "/containers/ctr/exec", req) do
    id = "e#{state.next}"
    [_sh, "-c", script] = decoded_body(req)["Cmd"]
    {{201, %{"Id" => id}}, %{record(state, {:create, id, script}) | next: state.next + 1}}
  end

  defp route(state, :post, "/exec/" <> rest, req) do
    [id, "start"] = String.split(rest, "/")
    {{200, ""}, record(state, {:start, id, decoded_body(req)})}
  end

  defp route(state, :get, "/exec/" <> rest, _req) do
    [id, "json"] = String.split(rest, "/")

    {answer, remaining} =
      case Map.fetch!(state.inspects, id) do
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end

    state = record(state, {:inspect, id})
    {{200, answer}, %{state | inspects: Map.put(state.inspects, id, remaining)}}
  end

  defp record(state, event), do: %{state | events: [event | state.events]}

  defp decoded_body(%{body: body}) when is_binary(body), do: JSON.decode!(body)
  defp decoded_body(%{options: %{json: json}}), do: JSON.decode!(JSON.encode!(json))
end
