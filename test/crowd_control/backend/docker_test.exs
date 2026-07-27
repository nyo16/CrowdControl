defmodule CrowdControl.Backend.DockerTest do
  # Needs a live Docker daemon. Excluded by default (see test_helper.exs); run
  # with `mix test --include docker`.
  use ExUnit.Case, async: false

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Docker
  alias CrowdControl.Backend.Docker.{API, Demux}

  @moduletag :docker
  @image "alpine:latest"

  # A stand-in for the real CLI: echoes each stdin line back as a JSON line.
  @echo_cli ["-c", ~S|while IFS= read -r l; do printf '{"echo":"%s"}\n' "$l"; done|]

  setup do
    owner = "cc-test-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
    on_exit(fn -> destroy_all(owner) end)
    {:ok, owner: owner, opts: base_opts(owner)}
  end

  defp base_opts(owner) do
    [image: @image, owner: owner, session_key: "key-#{owner}", timeout: 15_000]
  end

  defp destroy_all(owner) do
    case Docker.list_live(owner: owner) do
      {:ok, handles} -> Enum.each(handles, &Docker.destroy/1)
      _ -> :ok
    end
  end

  # GenServer.cast/2 to a plain pid arrives as {:"$gen_cast", msg}; relay them
  # back to the test process so assert_receive can be used.
  defp relay do
    test = self()
    spawn_link(fn -> relay_loop(test) end)
  end

  defp relay_loop(test) do
    receive do
      {:"$gen_cast", msg} ->
        send(test, {:cast, msg})
        relay_loop(test)
    end
  end

  # Run a command in the container and return its stdout, demuxed.
  defp run(handle, cmd) do
    {:ok, %{"Id" => exec_id}} =
      API.request(handle.config, :post, "/containers/#{handle.container_id}/exec",
        json: %{"AttachStdout" => true, "AttachStderr" => false, "Tty" => false, "Cmd" => cmd}
      )

    {:ok, raw} =
      API.request(handle.config, :post, "/exec/#{exec_id}/start",
        json: %{"Detach" => false, "Tty" => false},
        decode_body: false
      )

    {payloads, _} = Demux.feed(Demux.new(), raw)
    IO.iodata_to_binary(payloads)
  end

  describe "provision/1" do
    test "creates and starts a container with the required config", %{opts: opts, owner: owner} do
      assert {:ok, handle} = Docker.provision(opts)
      assert is_binary(handle.container_id)

      assert {:ok, info} = API.request(opts, :get, "/containers/#{handle.container_id}/json")

      assert info["State"]["Running"]

      # RestartPolicy "no" is non-negotiable: a restart truncates the tee file
      # and invalidates every persisted byte offset.
      assert info["HostConfig"]["RestartPolicy"]["Name"] == "no"
      assert info["HostConfig"]["NetworkMode"] == "none"

      labels = info["Config"]["Labels"]
      assert labels["crowd_control.owner"] == owner
      assert labels["crowd_control.session"] == "key-#{owner}"
      assert {_ms, ""} = Integer.parse(labels["crowd_control.created_at"])

      assert Docker.alive?(handle)
      Docker.destroy(handle)
    end

    test "applies hardening defaults — the sandbox runs untrusted code", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)
      {:ok, info} = API.request(opts, :get, "/containers/#{handle.container_id}/json")
      host = info["HostConfig"]

      assert host["CapDrop"] == ["ALL"], "a CLI needs no Linux capabilities"
      assert "no-new-privileges:true" in (host["SecurityOpt"] || [])

      # Memory and NanoCpus do not bound PIDs, so a fork bomb in model output
      # would otherwise exhaust the host.
      assert host["PidsLimit"] == 512

      Docker.destroy(handle)
    end

    test "hardening defaults are overridable", %{opts: opts} do
      opts = opts ++ [pids_limit: 64, cap_drop: ["NET_RAW"]]
      {:ok, handle} = Docker.provision(opts)
      {:ok, info} = API.request(opts, :get, "/containers/#{handle.container_id}/json")

      assert info["HostConfig"]["PidsLimit"] == 64
      assert info["HostConfig"]["CapDrop"] == ["NET_RAW"]

      Docker.destroy(handle)
    end

    test "readonly_rootfs is opt-in and still lets the entrypoint build its fifo",
         %{opts: opts} do
      {:ok, handle} = Docker.provision(opts ++ [readonly_rootfs: true])
      {:ok, info} = API.request(opts, :get, "/containers/#{handle.container_id}/json")

      assert info["HostConfig"]["ReadonlyRootfs"] == true

      # The tmpfs defaults exist precisely so a read-only root does not break
      # the fifo and tee paths the design depends on.
      assert run(handle, ["sh", "-c", "test -p /var/run/cc.fifo && echo FIFO_OK"]) =~ "FIFO_OK"
      assert run(handle, ["sh", "-c", "test -d /var/log/cc && echo DIR_OK"]) =~ "DIR_OK"

      Docker.destroy(handle)
    end

    test "the entrypoint creates the fifo and tee directory", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)

      assert run(handle, ["sh", "-c", "test -p /var/run/cc.fifo && echo FIFO_OK"]) =~ "FIFO_OK"
      assert run(handle, ["sh", "-c", "test -d /var/log/cc && echo DIR_OK"]) =~ "DIR_OK"

      Docker.destroy(handle)
    end

    test "requires an :image" do
      assert {:error, {:docker, :image_required}} = Docker.provision(owner: "x")
    end

    test "surfaces a bad docker host as a normalized error" do
      assert {:error, {:docker, {:bad_host, _}}} =
               Docker.provision(image: @image, docker_host: "carrier-pigeon://nope")
    end
  end

  describe "exec/4 and write/2 — the FIFO path" do
    test "multiple prompts are all delivered and the container survives", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)
      assert {:ok, handle} = Docker.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      # Each write is an independent detaching exec. With a plain `< fifo`
      # redirect the first one would EOF the CLI and kill the container; the
      # holder-fd form must survive all three.
      for msg <- ~w(alpha bravo charlie) do
        assert :ok = Docker.write(handle, msg <> "\n")
        Process.sleep(300)
      end

      Process.sleep(500)

      assert Docker.alive?(handle), "container died — the FIFO EOF'd on writer detach"

      tee = run(handle, ["cat", "/var/log/cc/out.jsonl"])
      assert tee =~ "alpha"
      assert tee =~ "bravo"
      assert tee =~ "charlie"

      Docker.destroy(handle)
    end

    test "a prompt containing shell metacharacters is not executed", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)
      {:ok, handle} = Docker.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      # If escaping leaked, the substitution would run and /tmp/pwned appear.
      :ok = Docker.write(handle, "$(touch /tmp/pwned)`touch /tmp/pwned2`\n")
      Process.sleep(800)

      refute run(handle, ["sh", "-c", "test -f /tmp/pwned && echo YES || echo NO"]) =~ "YES"
      refute run(handle, ["sh", "-c", "test -f /tmp/pwned2 && echo YES || echo NO"]) =~ "YES"

      tee = run(handle, ["cat", "/var/log/cc/out.jsonl"])
      assert tee =~ "touch /tmp/pwned", "the literal text should round-trip, unexecuted"

      Docker.destroy(handle)
    end
  end

  describe "start_reader/3 — live streaming" do
    test "delivers stdout as casts and reaches the session", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)
      {:ok, handle} = Docker.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      {:ok, reader} = Docker.start_reader(handle, relay(), Backend.new_cursor())
      assert is_pid(reader)

      :ok = Docker.write(handle, "hello\n")

      assert_receive {:cast, {:stdout_data, data}}, 10_000
      assert data =~ "hello"

      Docker.destroy(handle)
    end
  end

  describe "byte-exact resume — the centerpiece" do
    test "reattaching at a mid-line offset reconstructs the line with no loss or duplication",
         %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)

      # A deterministic, known-byte tee file. Writing it directly (rather than
      # racing a live CLI) is what makes the offset arithmetic exact.
      content = ~s({"n":1}\n{"n":2}\n{"n":3}\n)
      assert byte_size(content) == 24

      run(handle, [
        "sh",
        "-c",
        "mkdir -p /var/log/cc && printf '%s' '#{content}' > /var/log/cc/out.jsonl"
      ])

      # Cut at byte 12, which lands INSIDE the second line:
      #   bytes 0..7   = {"n":1}\n   -> already consumed as a whole line
      #   bytes 8..11  = {"n"        -> the partial line the session was holding
      #   bytes 12..   = :2}\n{"n":3}\n
      offset = 12
      buffer = ~s({"n")

      {:ok, _reader} =
        Docker.start_reader(handle, relay(), %{byte_offset: offset, buffer: buffer})

      resumed = collect_casts(3_000)

      # The backend must return exactly the bytes from the offset on — it must
      # NOT re-send the buffer, which the session already holds.
      assert resumed == ~s(:2}\n{"n":3}\n),
             "resumed payload was #{inspect(resumed)}"

      # And the session's reconstruction is byte-identical to the original tail.
      assert buffer <> resumed == binary_part(content, 8, byte_size(content) - 8)
      assert buffer <> resumed == ~s({"n":2}\n{"n":3}\n)

      Docker.destroy(handle)
    end

    test "resuming at offset 0 is identical to start_reader", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)
      content = "line-one\nline-two\n"

      run(handle, [
        "sh",
        "-c",
        "mkdir -p /var/log/cc && printf '%s' '#{content}' > /var/log/cc/out.jsonl"
      ])

      {:ok, _} = Docker.start_reader(handle, relay(), %{byte_offset: 0, buffer: ""})
      assert collect_casts(3_000) == content

      Docker.destroy(handle)
    end

    test "survives backpressure pause/resume with byte-exact output", %{opts: opts} do
      # THE regression test for the demux-reset blocker. Backpressure cancels the
      # HTTP stream and re-opens it from the delivered offset. Docker's 8-byte
      # frame headers are per-connection, so carrying demux state across that
      # reconnect desyncs the parser and silently corrupts output. A tiny
      # watermark forces many pause/resume cycles over a known payload; any
      # desync shows up as a mismatch.
      {:ok, handle} = Docker.provision(opts)

      # 200 fixed-width lines = 8000 bytes, far more than the 1 KiB watermark,
      # so the reader is forced to cycle repeatedly rather than once.
      lines = for i <- 1..200, do: String.pad_leading("#{i}", 38, "0")
      expected = Enum.map_join(lines, "", &(&1 <> "\n"))
      assert byte_size(expected) == 200 * 39

      run(handle, [
        "sh",
        "-c",
        "mkdir -p /var/log/cc && for i in $(seq 1 200); do " <>
          "printf '%038d\\n' \"$i\"; done > /var/log/cc/out.jsonl"
      ])

      handle = %{handle | config: Keyword.put(handle.config, :max_inflight_bytes, 1024)}

      # This relay stands in for Session: it forwards output to the test AND
      # acks consumed bytes back to the reader, which is what lifts each pause.
      test_pid = self()
      relay = spawn_link(fn -> acking_relay(test_pid, nil) end)

      {:ok, reader} = Docker.start_reader(handle, relay, Backend.new_cursor())
      send(relay, {:reader, reader})

      received = collect_until(byte_size(expected), 20_000)

      assert byte_size(received) == byte_size(expected),
             "got #{byte_size(received)} bytes, expected #{byte_size(expected)}"

      assert received == expected, "output corrupted across a backpressure reconnect"

      Docker.destroy(handle)
    end

    test "reattach/2 succeeds while the container lives and fails once it is gone", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)

      assert {:ok, ^handle} = Docker.reattach(handle, Backend.new_cursor())

      Docker.destroy(handle)
      assert {:error, {:docker, {:not_found, _}}} = Docker.reattach(handle, Backend.new_cursor())
    end
  end

  describe "list_live/1 and destroy/1" do
    test "list_live is scoped to the owner label", %{opts: opts, owner: owner} do
      {:ok, mine} = Docker.provision(opts)
      {:ok, theirs} = Docker.provision(base_opts("other-owner-#{owner}"))

      on_exit(fn ->
        Docker.destroy(theirs)
        destroy_all("other-owner-#{owner}")
      end)

      {:ok, live} = Docker.list_live(owner: owner)
      ids = Enum.map(live, & &1.container_id)

      assert mine.container_id in ids
      refute theirs.container_id in ids, "list_live leaked another owner's container"

      Docker.destroy(mine)
    end

    test "list_live carries the session key back from the label", %{opts: opts, owner: owner} do
      {:ok, handle} = Docker.provision(opts)

      {:ok, [found]} = Docker.list_live(owner: owner)
      assert found.session_key == "key-#{owner}"
      assert found.owner == owner

      Docker.destroy(handle)
    end

    test "destroy removes the container and is idempotent", %{opts: opts, owner: owner} do
      {:ok, handle} = Docker.provision(opts)
      assert Docker.alive?(handle)

      assert :ok = Docker.destroy(handle)

      # Poll list_live until the daemon reflects the removal.
      assert eventually(fn ->
               {:ok, live} = Docker.list_live(owner: owner)
               handle.container_id not in Enum.map(live, & &1.container_id)
             end)

      # A repeat destroy hits a 404, which the contract requires be treated as
      # success — Session calls destroy/1 from several teardown paths.
      assert :ok = Docker.destroy(handle)
      refute Docker.alive?(handle)
    end

    test "list_live returns an error (not an empty list) when the daemon is unreachable" do
      # This distinction is the single most dangerous thing in the reaper: an
      # error misread as "nothing is live" would destroy every live sandbox.
      assert {:error, _} = Docker.list_live(docker_host: "unix:///nonexistent/docker.sock")
    end
  end

  describe "credential injection" do
    # Pure credential tests live in docker_unit_test.exs — they need no daemon.
    test "the real api key never appears in the container's process list", %{opts: opts} do
      # Even without a proxy, secrets go through `export` inside the exec'd
      # shell, never as argv — so they are not visible to `ps` in the container.
      {:ok, handle} = Docker.provision(opts)

      {:ok, handle} =
        Docker.exec(handle, "/bin/sh", @echo_cli, %{"ANTHROPIC_API_KEY" => "sk-should-not-show"})

      Process.sleep(500)

      ps = run(handle, ["ps", "-o", "args"])
      refute ps =~ "sk-should-not-show", "secret leaked into the container's argv"

      Docker.destroy(handle)
    end

    test "a proxied session's CLI sees the proxy URL, not the real key", %{opts: opts} do
      opts =
        opts ++
          [
            proxy_url: "http://proxy.internal:8080",
            session_token: "sess-abc",
            api_key: "sk-real",
            # Required now: the backend refuses to infer a network mode.
            network_mode: "none"
          ]

      {:ok, handle} = Docker.provision(opts)

      {:ok, handle} =
        Docker.exec(handle, "/bin/sh", ["-c", "env > /var/log/cc/env.txt; sleep 30"], %{
          "ANTHROPIC_API_KEY" => "sk-real",
          "ANTHROPIC_BASE_URL" => "https://api.anthropic.com"
        })

      Process.sleep(800)

      env_dump = run(handle, ["cat", "/var/log/cc/env.txt"])

      assert env_dump =~ "ANTHROPIC_BASE_URL=http://proxy.internal:8080"
      assert env_dump =~ "ANTHROPIC_API_KEY=sess-abc"
      refute env_dump =~ "sk-real", "the real provider key reached the sandbox"

      Docker.destroy(handle)
    end
  end

  describe "await_exit/2" do
    test "reports the exit code once the container stops", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)

      API.request(opts, :post, "/containers/#{handle.container_id}/stop", params: [t: 0])
      assert eventually(fn -> match?({:ok, _}, Docker.await_exit(handle, 1_000)) end)

      Docker.destroy(handle)
    end

    test "reports {:ok, nil} for a container that no longer exists", %{opts: opts} do
      {:ok, handle} = Docker.provision(opts)
      Docker.destroy(handle)

      assert eventually(fn -> Docker.await_exit(handle, 1_000) == {:ok, nil} end)
    end
  end

  # --- helpers ---

  # Forwards stdout to the test and acks it back to the reader, so the
  # backpressure watermark is actually released and the stream resumes.
  defp acking_relay(test_pid, reader) do
    receive do
      {:reader, pid} ->
        acking_relay(test_pid, pid)

      {:"$gen_cast", {:stdout_data, data}} ->
        send(test_pid, {:cast, {:stdout_data, data}})
        if is_pid(reader), do: send(reader, {:cc_ack, byte_size(data)})
        acking_relay(test_pid, reader)

      {:"$gen_cast", msg} ->
        send(test_pid, {:cast, msg})
        acking_relay(test_pid, reader)
    end
  end

  defp collect_until(target_bytes, timeout, acc \\ "") do
    if byte_size(acc) >= target_bytes do
      acc
    else
      receive do
        {:cast, {:stdout_data, data}} -> collect_until(target_bytes, timeout, acc <> data)
        {:cast, :eof} -> acc
      after
        timeout -> acc
      end
    end
  end

  defp collect_casts(timeout, acc \\ "") do
    receive do
      {:cast, {:stdout_data, data}} -> collect_casts(500, acc <> data)
      {:cast, :eof} -> acc
    after
      timeout -> acc
    end
  end

  defp eventually(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(100)
        do_eventually(fun, deadline)
    end
  end
end
