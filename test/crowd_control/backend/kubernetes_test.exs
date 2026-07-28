defmodule CrowdControl.Backend.KubernetesTest do
  # Needs a live Kubernetes cluster. Excluded by default (see test_helper.exs);
  # run with `mix test --include k8s`.
  #
  # OrbStack environment hazard, verified during planning and worth knowing
  # before debugging this backend: a *successful* busybox `wget` to an external
  # host makes the Pod's PID 1 exit 0, so the Pod goes `Succeeded` with
  # `reason: Completed` and no kubelet event at all. DNS alone, `nc -z` alone
  # and a *failed* `wget` all leave the Pod `Running`; only a successful
  # external HTTP fetch triggers it. Nothing here relies on egress, so it does
  # not touch these tests -- but it will make any `:unrestricted` egress test
  # someone adds later look like a spurious Pod death.
  use ExUnit.Case, async: false

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Store

  @moduletag :k8s
  @image "busybox:1.36"
  @container "cc"

  # A stand-in for the real CLI: echoes each stdin line back as a JSON line.
  @echo_cli ["-c", ~S|while IFS= read -r l; do printf '{"echo":"%s"}\n' "$l"; done|]

  setup do
    owner = "cc-test-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
    on_exit(fn -> destroy_all(owner) end)
    {:ok, owner: owner, opts: base_opts(owner)}
  end

  # The Pod name is derived from the session key, so the key must be a legal
  # RFC 1123 label -- Store.new_key/0 is what Session supplies and the only
  # thing pod_name/1 accepts without complaint.
  defp base_opts(owner) do
    [
      image: @image,
      owner: owner,
      session_key: Store.new_key(),
      timeout: 30_000,
      exec_timeout: 30_000
    ]
  end

  defp destroy_all(owner) do
    case Kubernetes.list_live(owner: owner) do
      {:ok, handles} -> Enum.each(handles, &Kubernetes.destroy/1)
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

  # Run a command in the sandbox container and return its stdout. Unlike
  # Docker's raw stream this arrives already demuxed -- kubereq owns the
  # channel framing.
  defp run(handle, cmd) do
    {:ok, stdout} = API.exec_once(handle.config, handle.pod_name, cmd, container: @container)
    stdout
  end

  defp sh(handle, script), do: run(handle, ["/bin/sh", "-c", script])

  defp write_tee(handle, content) do
    sh(handle, "mkdir -p /var/log/cc && printf '%s' '#{content}' > /var/log/cc/out.jsonl")
  end

  # A kubeconfig whose server nothing is listening on. Req retries are disabled
  # in API.client/2, so this fails in milliseconds rather than after backoff.
  defp unreachable_kubeconfig do
    Kubereq.Kubeconfig.new!(
      current_context: "unreachable",
      current_cluster: %{"server" => "https://127.0.0.1:1"},
      current_user: %{},
      contexts: [],
      clusters: [],
      users: [],
      current_namespace: "default"
    )
  end

  describe "provision/1" do
    test "creates a Running Pod with the required labels and annotation",
         %{opts: opts, owner: owner} do
      assert {:ok, handle} = Kubernetes.provision(opts)
      assert handle.pod_name == "cc-" <> opts[:session_key]

      assert {:ok, pod} = API.get_pod(opts, handle.pod_name)
      assert pod["status"]["phase"] == "Running"

      # restartPolicy Never is non-negotiable: a restarted container truncates
      # the tee file and invalidates every persisted byte offset.
      assert pod["spec"]["restartPolicy"] == "Never"

      labels = pod["metadata"]["labels"]
      assert labels["crowd_control.session"] == opts[:session_key]
      assert labels["crowd_control.owner_hash"] == Kubernetes.owner_label(owner)
      assert {_ms, ""} = Integer.parse(labels["crowd_control.created_at"])

      # The raw owner rides an annotation because label values cannot hold one;
      # Reaper.owned_by?/3 compares it exactly.
      assert pod["metadata"]["annotations"]["crowd_control.owner"] == owner

      assert Kubernetes.alive?(handle)
      Kubernetes.destroy(handle)
    end

    test "requires an :image and surfaces an unreachable cluster as a normalized error" do
      assert {:error, {:k8s, :image_required}} = Kubernetes.provision(owner: "x")

      assert {:error, {:k8s, _}} =
               Kubernetes.provision(
                 image: @image,
                 owner: "cc-test-unreachable",
                 session_key: Store.new_key(),
                 kubeconfig: unreachable_kubeconfig()
               )
    end

    test "the init container builds the fifo and tee dir, under a read-only root too",
         %{opts: opts, owner: owner} do
      {:ok, handle} = Kubernetes.provision(opts)

      assert sh(handle, "test -p /var/run/cc.fifo && echo FIFO_OK") =~ "FIFO_OK"
      assert sh(handle, "test -d /var/log/cc && echo DIR_OK") =~ "DIR_OK"

      Kubernetes.destroy(handle)

      # readonly_rootfs is a pure toggle precisely because both load-bearing
      # paths are already emptyDir volumes -- the init container has to hand the
      # FIFO across, and a container's own writable layer is not shared.
      {:ok, ro} = Kubernetes.provision(base_opts(owner) ++ [readonly_rootfs: true])

      assert sh(ro, "test -p /var/run/cc.fifo && echo FIFO_OK") =~ "FIFO_OK"
      assert sh(ro, "test -d /var/log/cc && echo DIR_OK") =~ "DIR_OK"

      # Bound to a name rather than inlined: at 99 columns the inline form sits
      # right on the formatter's wrap threshold, and Elixir 1.18 and 1.20
      # disagree about which side of it the line falls on. CI checks formatting
      # with one of them and contributors may run the other.
      rootfs = sh(ro, "touch /etc/nope 2>/dev/null && echo WRITABLE || echo READONLY")

      assert rootfs =~ "READONLY",
             "the root filesystem stayed writable under readonly_rootfs: true"

      Kubernetes.destroy(ro)
    end
  end

  describe "exec/4 and write/2 — the FIFO path" do
    test "multiple prompts are all delivered and the Pod survives", %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)
      assert {:ok, handle} = Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      # Each write is an independent short exec. With a plain `< fifo` redirect
      # the first one would EOF the CLI and collapse the pipeline; the `3<>`
      # holder fd must survive all three.
      for msg <- ~w(alpha bravo charlie) do
        assert :ok = Kubernetes.write(handle, msg <> "\n")
        Process.sleep(300)
      end

      Process.sleep(500)

      assert Kubernetes.alive?(handle), "the pod died — the FIFO EOF'd on writer detach"

      tee = sh(handle, "cat /var/log/cc/out.jsonl")
      assert tee =~ "alpha"
      assert tee =~ "bravo"
      assert tee =~ "charlie"

      Kubernetes.destroy(handle)
    end

    test "a prompt containing shell metacharacters is not executed", %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)
      {:ok, handle} = Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      # If escaping leaked, the substitution would run and /tmp/pwned appear.
      :ok = Kubernetes.write(handle, "$(touch /tmp/pwned)`touch /tmp/pwned2`\n")
      Process.sleep(800)

      refute sh(handle, "test -f /tmp/pwned && echo YES || echo NO") =~ "YES"
      refute sh(handle, "test -f /tmp/pwned2 && echo YES || echo NO") =~ "YES"

      tee = sh(handle, "cat /var/log/cc/out.jsonl")
      assert tee =~ "touch /tmp/pwned", "the literal text should round-trip, unexecuted"

      Kubernetes.destroy(handle)
    end
  end

  describe "start_reader/3 — live streaming" do
    test "delivers stdout as casts and reaches the session", %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)
      {:ok, handle} = Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      {:ok, reader} = Kubernetes.start_reader(handle, relay(), Backend.new_cursor())
      assert is_pid(reader)

      :ok = Kubernetes.write(handle, "hello\n")

      # The exec channel opens with a zero-byte stdout frame, which the reader
      # drops: the FIRST cast a session sees must already carry output, or
      # "the reader produced data" is untrue at the moment a caller waits on it.
      assert_receive {:cast, {:stdout_data, first}}, 15_000
      refute first == "", "an empty opening frame reached the session"
      assert first =~ "hello"

      Kubernetes.destroy(handle)
    end
  end

  describe "byte-exact resume — the centerpiece" do
    test "reattaching at a mid-line offset reconstructs the line with no loss or duplication",
         %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)

      # A deterministic, known-byte tee file. Writing it directly (rather than
      # racing a live CLI) is what makes the offset arithmetic exact.
      content = ~s({"n":1}\n{"n":2}\n{"n":3}\n)
      assert byte_size(content) == 24

      write_tee(handle, content)

      # Cut at byte 12, which lands INSIDE the second line:
      #   bytes 0..7   = {"n":1}\n   -> already consumed as a whole line
      #   bytes 8..11  = {"n"        -> the partial line the session was holding
      #   bytes 12..   = :2}\n{"n":3}\n
      offset = 12
      buffer = ~s({"n")

      {:ok, _reader} =
        Kubernetes.start_reader(handle, relay(), %{byte_offset: offset, buffer: buffer})

      resumed = collect_casts(5_000)

      # The backend must return exactly the bytes from the offset on — it must
      # NOT re-send the buffer, which the session already holds.
      assert resumed == ~s(:2}\n{"n":3}\n),
             "resumed payload was #{inspect(resumed)}"

      # And the session's reconstruction is byte-identical to the original tail.
      assert buffer <> resumed == binary_part(content, 8, byte_size(content) - 8)
      assert buffer <> resumed == ~s({"n":2}\n{"n":3}\n)

      Kubernetes.destroy(handle)
    end

    test "resuming at offset 0 is identical to start_reader", %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)
      content = "line-one\nline-two\n"

      write_tee(handle, content)

      {:ok, _} = Kubernetes.start_reader(handle, relay(), %{byte_offset: 0, buffer: ""})
      assert collect_casts(5_000) == content

      Kubernetes.destroy(handle)
    end

    test "survives backpressure pause/resume with byte-exact output", %{opts: opts} do
      # Backpressure has no flow-control primitive on an exec websocket, so
      # "pause" is closing the channel and "resume" is a fresh `tail -c +offset`
      # from the bytes already delivered. Every cycle is therefore an
      # opportunity to lose or duplicate a byte. A tiny watermark over a known
      # payload forces many cycles; any slip shows up as a mismatch.
      {:ok, handle} = Kubernetes.provision(opts)

      # 200 fixed-width lines = 7800 bytes, far more than the 1 KiB watermark,
      # so the reader is forced to cycle repeatedly rather than once.
      lines = for i <- 1..200, do: String.pad_leading("#{i}", 38, "0")
      expected = Enum.map_join(lines, "", &(&1 <> "\n"))
      assert byte_size(expected) == 200 * 39

      sh(
        handle,
        "mkdir -p /var/log/cc && for i in $(seq 1 200); do " <>
          "printf '%038d\\n' \"$i\"; done > /var/log/cc/out.jsonl"
      )

      handle = %{handle | config: Keyword.put(handle.config, :max_inflight_bytes, 1024)}

      # This relay stands in for Session: it forwards output to the test AND
      # acks consumed bytes back to the reader, which is what lifts each pause.
      test_pid = self()
      relay = spawn_link(fn -> acking_relay(test_pid, nil) end)

      {:ok, reader} = Kubernetes.start_reader(handle, relay, Backend.new_cursor())
      send(relay, {:reader, reader})

      received = collect_until(byte_size(expected), 60_000)

      assert byte_size(received) == byte_size(expected),
             "got #{byte_size(received)} bytes, expected #{byte_size(expected)}"

      assert received == expected, "output corrupted across a backpressure reconnect"

      Kubernetes.destroy(handle)
    end

    test "a killed exec channel reconnects at the offset instead of ending the session",
         %{opts: opts} do
      # `tail -f` never ends while the Pod lives, so a close frame means the
      # CHANNEL dropped, not the stream. Casting :eof here — which is what the
      # Docker reader does on `:done` — would end a live session over a blip.
      {:ok, handle} = Kubernetes.provision(opts)

      first = Enum.map_join(1..5, "", &"first-#{&1}\n")
      second = Enum.map_join(1..5, "", &"second-#{&1}\n")

      write_tee(handle, first)

      {:ok, _reader} = Kubernetes.start_reader(handle, relay(), Backend.new_cursor())

      assert collect_until(byte_size(first), 30_000) == first

      # Drop the reader's channel out from under it. Killing `tail` is what the
      # API server sees as the exec ending, which is exactly a transport blip.
      sh(handle, "kill -9 $(pidof tail) 2>/dev/null; echo killed")

      # Reconnect backoff starts at 100ms; appending immediately also proves the
      # resume reads from the file rather than from a live pipe.
      sh(handle, "printf '%s' '#{second}' >> /var/log/cc/out.jsonl")

      assert collect_until(byte_size(second), 60_000) == second,
             "the reconnect lost or duplicated bytes across the offset"

      refute_receive {:cast, :eof}, 1_000

      Kubernetes.destroy(handle)
    end

    test "reattach/2 succeeds while the Pod lives and fails once it is gone", %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)

      assert {:ok, ^handle} = Kubernetes.reattach(handle, Backend.new_cursor())

      Kubernetes.destroy(handle)

      assert eventually(fn ->
               match?(
                 {:error, {:k8s, {:not_found, _}}},
                 Kubernetes.reattach(handle, Backend.new_cursor())
               )
             end),
             "reattach still resolved a destroyed Pod"
    end
  end

  describe "list_live/1 and destroy/1" do
    test "list_live is owner-scoped and carries the session key and raw owner back",
         %{opts: opts, owner: owner} do
      {:ok, mine} = Kubernetes.provision(opts)
      foreign = "other-owner-#{owner}"
      {:ok, theirs} = Kubernetes.provision(base_opts(foreign))

      on_exit(fn ->
        Kubernetes.destroy(theirs)
        destroy_all(foreign)
      end)

      {:ok, live} = Kubernetes.list_live(owner: owner)
      names = Enum.map(live, & &1.pod_name)

      assert mine.pod_name in names
      refute theirs.pod_name in names, "list_live leaked another owner's Pod"

      found = Enum.find(live, &(&1.pod_name == mine.pod_name))
      assert found.session_key == opts[:session_key]

      # The selector is a hash; this is the annotation round-tripping back so
      # Reaper.owned_by?/3 can re-check the raw string.
      assert found.owner == owner

      Kubernetes.destroy(mine)
    end

    test "destroy removes the Pod, is idempotent, and takes the managed policy with it",
         %{opts: opts, owner: owner} do
      # network_probe: false because OrbStack does not enforce NetworkPolicy and
      # the preflight would refuse to provision at all — see the :deny_all test.
      opts = opts ++ [network: :deny_all, network_probe: false]
      {:ok, handle} = Kubernetes.provision(opts)
      assert Kubernetes.alive?(handle)

      policy = handle.pod_name <> "-deny-all"
      assert {:ok, _} = API.get_network_policy(opts, policy)

      assert :ok = Kubernetes.destroy(handle)

      assert eventually(fn ->
               {:ok, live} = Kubernetes.list_live(owner: owner)
               handle.pod_name not in Enum.map(live, & &1.pod_name)
             end)

      assert eventually(fn ->
               match?({:error, {:k8s, {:not_found, _}}}, API.get_network_policy(opts, policy))
             end),
             "the managed deny-all policy outlived its Pod"

      # A repeat destroy hits a 404, which the contract requires be treated as
      # success — Session calls destroy/1 from several teardown paths.
      assert :ok = Kubernetes.destroy(handle)
      refute Kubernetes.alive?(handle)
    end

    test "list_live returns an error (not an empty list) when the API server is unreachable" do
      # This distinction is the single most dangerous thing in the reaper: an
      # error misread as "nothing is live" would destroy every live sandbox.
      assert {:error, _} =
               Kubernetes.list_live(
                 owner: "cc-test-unreachable",
                 kubeconfig: unreachable_kubeconfig()
               )
    end
  end

  describe "credential injection" do
    # Pure credential tests live in kubernetes_unit_test.exs — they need no cluster.
    test "the real api key never appears in the sandbox's process list", %{opts: opts} do
      # The Kubernetes exec API has no `env` parameter at all, so the secret
      # travels the exec stdin channel into a 0600 file that the launch command
      # sources and unlinks. It never enters argv, and this is the proof.
      {:ok, handle} = Kubernetes.provision(opts)

      {:ok, handle} =
        Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{
          "ANTHROPIC_API_KEY" => "sk-should-not-show"
        })

      Process.sleep(800)

      ps = run(handle, ["ps", "-o", "args"])

      # Guards the refute below against a silently empty stdout, which would
      # make it pass without ever having looked at a process list.
      assert ps =~ "sleep infinity", "ps produced nothing to inspect"
      refute ps =~ "sk-should-not-show", "secret leaked into the sandbox's argv"

      Kubernetes.destroy(handle)
    end

    test "the env file is unlinked once the CLI is running", %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)

      {:ok, handle} =
        Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{
          "ANTHROPIC_API_KEY" => "sk-should-not-show"
        })

      Process.sleep(800)

      assert sh(handle, "ls /var/run/cc.env >/dev/null 2>&1 && echo PRESENT || echo GONE") =~
               "GONE",
             "the env file survived the launch — the secret is readable out of the sandbox"

      Kubernetes.destroy(handle)
    end

    test "a proxied session's CLI sees the proxy URL, not the real key", %{opts: opts} do
      opts =
        opts ++
          [
            proxy_url: "http://proxy.internal:8080",
            session_token: "sess-abc",
            api_key: "sk-real",
            # Required now: with a proxy in play the backend refuses to infer a
            # network posture.
            network: :unrestricted
          ]

      {:ok, handle} = Kubernetes.provision(opts)

      {:ok, handle} =
        Kubernetes.exec(handle, "/bin/sh", ["-c", "env > /var/log/cc/env.txt; sleep 30"], %{
          "ANTHROPIC_API_KEY" => "sk-real",
          "ANTHROPIC_BASE_URL" => "https://api.anthropic.com"
        })

      Process.sleep(1_000)

      env_dump = sh(handle, "cat /var/log/cc/env.txt")

      assert env_dump =~ "ANTHROPIC_BASE_URL=http://proxy.internal:8080"
      assert env_dump =~ "ANTHROPIC_API_KEY=sess-abc"
      refute env_dump =~ "sk-real", "the real provider key reached the sandbox"

      Kubernetes.destroy(handle)
    end
  end

  describe "await_exit/2" do
    test "reports the exit code once the Pod stops, and nil once it is gone", %{opts: opts} do
      # provision/1 always makes PID 1 `sleep infinity`, and PID 1 of a PID
      # namespace cannot be signalled from inside it — so observing a real exit
      # code needs a Pod whose sandbox container exits on its own.
      handle = exiting_pod(opts, 42)

      assert eventually(fn -> Kubernetes.await_exit(handle, 1_000) == {:ok, 42} end, 60_000),
             "await_exit never reported the terminated container's exit code"

      Kubernetes.destroy(handle)

      assert eventually(fn -> Kubernetes.await_exit(handle, 1_000) == {:ok, nil} end),
             "a deleted Pod must read as exited, or the Reaper never prunes its record"
    end
  end

  describe "network posture" do
    test "deny_all refuses to provision on a cluster that does not enforce NetworkPolicy",
         %{opts: opts} do
      # OrbStack accepts NetworkPolicy objects and enforces none of them, so the
      # D5 preflight must refuse rather than report a boundary that is not
      # there. The result is cached in :persistent_term per cluster URL, so this
      # may or may not actually run a probe Pod — the returned error is the
      # assertion either way.
      assert {:error, {:k8s, :network_policy_not_enforced}} =
               Kubernetes.provision(opts ++ [network: :deny_all])
    end
  end

  # --- helpers ---

  # A Pod built from the real manifest but whose sandbox container exits with
  # `code`, so `await_exit/2` has a terminated containerStatus to read.
  defp exiting_pod(opts, code) do
    {:ok, pod_name} = Kubernetes.pod_name(opts[:session_key])

    handle = %Kubernetes{
      pod_name: pod_name,
      namespace: API.namespace(opts),
      image: @image,
      tee_path: "/var/log/cc/out.jsonl",
      fifo_path: "/var/run/cc.fifo",
      env_path: "/var/run/cc.env",
      session_key: opts[:session_key],
      owner: opts[:owner],
      config: opts
    }

    manifest =
      handle
      |> Kubernetes.pod_manifest()
      |> update_in(["spec", "containers"], fn [container] ->
        [Map.put(container, "command", ["/bin/sh", "-c", "exit #{code}"])]
      end)

    {:ok, _} = API.create_pod(opts, manifest)
    handle
  end

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
