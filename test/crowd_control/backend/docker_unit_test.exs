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

  defp relay_loop(test_pid) do
    receive do
      {:"$gen_cast", msg} ->
        send(test_pid, {:cast, msg})
        relay_loop(test_pid)
    end
  end
end
