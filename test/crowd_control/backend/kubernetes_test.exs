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

  import ExUnit.CaptureLog

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Store

  @moduletag :k8s
  @image "busybox:1.36"
  @container "cc"

  # An image reference that cannot resolve, so no container ever starts. A pull
  # failure is reported within seconds and never retried into Running, which
  # makes it the cheapest deterministic "Pod that never runs".
  @unpullable_image "nope/nope:doesnotexist"

  # A stand-in for the real CLI: echoes each stdin line back as a JSON line.
  @echo_cli ["-c", ~S|while IFS= read -r l; do printf '{"echo":"%s"}\n' "$l"; done|]

  # Sweep leftovers from a previous run, once per module and before anything
  # provisions.
  #
  # Two classes of object outlive a killed run and no owner-scoped selector can
  # reach either. The enforcement probe creates `cc-netpol-probe-<hex>` and
  # `cc-netpol-ctl-<hex>` Pods plus a NetworkPolicy of the same name; it removes
  # them in an `after` block, which does not run when the process is *killed* --
  # and ExUnit kills the test process on a timeout -- and it labels them
  # `crowd_control.probe` with no owner hash, so destroy_all/1's selector can
  # never match them. The managed deny-all policy leaks for a different reason:
  # destroy/1's delete_managed_policy/1 is gated on the *caller's*
  # config[:network], so a handle rebuilt without it deletes the Pod and leaves
  # `<pod>-deny-all` behind.
  #
  # Deliberately not a per-test on_exit: the probe reads the phases of the Pods
  # it just created, so a sweep running while a probe is in flight would delete
  # them out from under it. Module setup is the one point at which no probe of
  # this suite can be running, so a killed run self-heals on the next one rather
  # than being cleaned mid-flight.
  setup_all do
    sweep_residue()
    :ok
  end

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

  # A label-selector delete that ignores phase, and deliberately NOT
  # Kubernetes.list_live/1: list_live/1 filters `phase == "Running"`, so a Pod
  # that failed mid-test is invisible to cleanup *forever*. That is not a
  # hypothetical -- two Pods sat on this cluster for 33 days before an audit
  # found them, one `Error` and one `ContainerStatusUnknown`, both left by tests
  # that clean up through here. API.list_all/4 does not filter by phase; keep it
  # that way.
  defp destroy_all(owner) do
    selectors = [{"crowd_control.owner_hash", Kubernetes.owner_label(owner)}]

    case API.list_all([], nil, label_selectors: selectors) do
      {:ok, pods} -> Enum.each(pods, &destroy_by_name(object_name(&1)))
      {:error, _} -> :ok
    end
  end

  # Deleting the Pod directly rather than through Kubernetes.destroy/1 skips
  # delete_managed_policy/1, so the paired policy is named explicitly. A Pod
  # without one answers 404, which is the expected case and not worth reporting.
  defp destroy_by_name(name) do
    API.delete_pod([], name)
    API.delete_network_policy([], name <> "-deny-all")
  end

  defp sweep_residue do
    Enum.each(leftover_probe_pods(), &API.delete_pod([], &1))
    Enum.each(leftover_policies(), &API.delete_network_policy([], &1))
  rescue
    # Fail open and quiet. Cleanup that raises turns an unrelated test failure
    # into a confusing one, and leftover residue is a cost, not a wrong answer.
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # By name prefix rather than by the `crowd_control.probe` label: the names are
  # what the probe derives its policy name from, so a change to the labels
  # cannot make this silently stop matching.
  defp leftover_probe_pods do
    case API.list_all([]) do
      {:ok, pods} ->
        pods |> Enum.map(&object_name/1) |> Enum.filter(&String.starts_with?(&1, "cc-netpol-"))

      {:error, _} ->
        []
    end
  end

  # API has no NetworkPolicy list -- nothing in lib/ needs one -- so the resource
  # is named here. Every policy this project creates is `cc-`-prefixed: the
  # probe's is the probe Pod's name, the managed one is `<pod>-deny-all`.
  defp leftover_policies do
    req = API.client([], api_version: "networking.k8s.io/v1", kind: "NetworkPolicy")

    case API.normalize(Kubereq.list(req, API.namespace([]), params: [limit: 500])) do
      {:ok, %{"items" => items}} ->
        items |> Enum.map(&object_name/1) |> Enum.filter(&String.starts_with?(&1, "cc-"))

      _ ->
        []
    end
  end

  defp object_name(object), do: get_in(object, ["metadata", "name"])

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

      # Pinned to the exact reason, not `{:k8s, _}`. That looser match is
      # satisfied by every reason in the vocabulary, so it stayed green for months
      # while the reason it "checked" was a 2 KB dump of a %Req.Request{} carrying
      # client-certificate material. A test that cannot fail is not coverage.
      assert {:error, {:k8s, {:transport, :econnrefused}}} =
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

    test "a second exec/4 is refused and leaves the tee file and credential file alone",
         %{opts: opts} do
      # `tee` opens the tee file `O_TRUNC`, so a second launch silently truncated
      # it — after which every persisted byte offset pointed into a different
      # file and the session replayed or skipped output with no error anywhere.
      {:ok, handle} = Kubernetes.provision(opts)
      {:ok, handle} = Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      :ok = Kubernetes.write(handle, "accumulated\n")
      Process.sleep(500)

      # Guards the comparison below against a vacuous pass: with an empty tee
      # file, a truncation is indistinguishable from doing nothing.
      before = sh(handle, "cat #{handle.tee_path}")

      assert before =~ "accumulated",
             "nothing accumulated in the tee file, so a truncation would be invisible"

      assert {:error, {:k8s, :already_started}} =
               Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{})

      # The refusal is not the damage this prevents. This is: the bytes a
      # persisted cursor refers to are still there, byte for byte.
      assert sh(handle, "cat #{handle.tee_path}") == before

      # And the guard runs *before* the credential write, not after. Only the
      # launcher unlinks that file, so a refused exec that re-planted it would
      # leave the provider key readable inside the sandbox for the rest of the
      # session.
      env = sh(handle, "ls #{handle.env_path} >/dev/null 2>&1 && echo PRESENT || echo GONE")
      assert env =~ "GONE", "a refused exec re-planted the credential file"

      Kubernetes.destroy(handle)
    end

    test "a write/2 that outruns its budget is indeterminate, not a plain timeout",
         %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)
      {:ok, handle} = Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      # 1 ms cannot cover a TLS handshake plus a websocket upgrade, so the
      # timeout happens on every run rather than racing.
      starved = %{handle | config: Keyword.put(handle.config, :exec_timeout, 1)}

      # Deliberately not `{:k8s, :exec_timeout}`. `bounded/2` brutal-kills the
      # exec task and the Mint socket dies with it, but the API server may
      # already have run the `printf` — so the prompt may or may not be in the
      # FIFO. Reported as a generic timeout, the obvious response is a retry,
      # which delivers the prompt twice.
      assert {:error, {:k8s, :write_indeterminate}} = Kubernetes.write(starved, "maybe\n")

      # No assertion about whether "maybe" landed: that is precisely the unknown
      # the reason names. What must still hold is that the budget is what failed
      # and not the sandbox.
      assert :ok = Kubernetes.write(handle, "certain\n")
      Process.sleep(500)
      assert sh(handle, "cat #{handle.tee_path}") =~ "certain"

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

      # `refute first == ""` used to stand here, described as proof that the
      # reader drops a zero-byte opening frame. Measured on v1.35.6+orb1 across
      # stdin true/false and silent and immediate commands: this apiserver sends
      # **no** such frame, so the refute could never fail. The clause it claimed
      # to defend is cheap insurance, not a load-bearing filter, and no test
      # should claim to depend on it.
      #
      # What is worth asserting is the actual contract: the first cast a session
      # sees carries the round-tripped prompt, byte for byte.
      assert_receive {:cast, {:stdout_data, first}}, 15_000

      assert first == ~s({"echo":"hello"}\n),
             "the first cast must be the CLI's answer, not a framing artefact"

      Kubernetes.destroy(handle)
    end

    test "a killed CLI ends the session and the Pod, rather than hanging both forever",
         %{opts: opts} do
      # The defect this pins: PID 1 was `sleep infinity`, and the CLI is a
      # grandchild after `setsid`, so nothing in the container noticed it die.
      # The container stayed Running, `tail -f` never ended, no `:eof` was ever
      # cast, and the session waited forever while the Pod billed forever. A
      # crashed CLI is the single most likely failure in production.
      {:ok, handle} = Kubernetes.provision(opts)
      {:ok, handle} = Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      {:ok, _reader} = Kubernetes.start_reader(handle, relay(), Backend.new_cursor())

      :ok = Kubernetes.write(handle, "hello\n")
      assert_receive {:cast, {:stdout_data, first}}, 15_000
      assert first =~ "hello", "the session must be genuinely live before it is killed"
      assert Kubernetes.alive?(handle)

      # SIGKILL, not SIGTERM: the CLI gets no chance to tidy up, which is the
      # worst case.
      #
      # Two things about this pattern, both learned the hard way. `[I]FS` keeps it
      # from matching this very command's own argv. Excluding `cc.env` keeps it
      # from matching the *launcher* shells, whose argv embeds the CLI's script
      # text verbatim — killing those instead takes out the process that reports
      # the status, which is a different failure (covered by the next test).
      sh(
        handle,
        "kill -9 $(ps -o pid,args | grep '[I]FS= read' | grep -v cc.env | awk '{print $1}')"
      )

      # Every one of these was broken before, and each is a different half of it.
      assert_receive {:cast, :eof}, 30_000

      assert eventually(fn -> not Kubernetes.alive?(handle) end, 30_000),
             "the Pod outlived its CLI and keeps billing"

      # 137 = 128 + SIGKILL. The launcher captures the CLI's status and PID 1
      # adopts it, so the Pod's exit code is the CLI's rather than a fiction.
      assert {:ok, 137} = Kubernetes.await_exit(handle, 30_000)

      Kubernetes.destroy(handle)
    end

    test "a launcher killed before it can report a status still ends the session",
         %{opts: opts} do
      # The status file is the launcher's job, so killing the launcher is the one
      # way to guarantee it never arrives. PID 1 waiting on that file alone would
      # hang exactly as it did before — the same bug, one level up. This is the
      # OOM-killed-process-group case, and it was found by a test whose kill
      # pattern matched too much.
      {:ok, handle} = Kubernetes.provision(opts)
      {:ok, handle} = Kubernetes.exec(handle, "/bin/sh", @echo_cli, %{})
      Process.sleep(500)

      {:ok, _reader} = Kubernetes.start_reader(handle, relay(), Backend.new_cursor())
      :ok = Kubernetes.write(handle, "hello\n")
      assert_receive {:cast, {:stdout_data, _}}, 15_000

      # Everything the CLI's script text appears in, launcher shells included:
      # the whole process group except PID 1, killed without warning.
      sh(handle, "kill -9 $(ps -o pid,args | grep '[I]FS= read' | awk '{print $1}')")

      assert_receive {:cast, :eof}, 30_000

      assert eventually(fn -> not Kubernetes.alive?(handle) end, 30_000),
             "PID 1 waited forever for a status no surviving process could write"

      # 1, not 137: the CLI's real status died with the launcher, and inventing a
      # specific code would be a lie. "Something went wrong" is the honest answer.
      assert {:ok, 1} = Kubernetes.await_exit(handle, 30_000)

      Kubernetes.destroy(handle)
    end

    test "a dead consumer takes its exec channel with it", %{opts: opts} do
      # `API.open_exec/5` keeps the link inside its own owner process, so nothing
      # else would notice a reader that died — the channel would sit open against
      # the API server for as long as the owner lived. The owner monitors the
      # consumer for exactly this reason, and only a real channel can prove it.
      {:ok, handle} = Kubernetes.provision(opts)

      consumer = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, channel} =
               API.open_exec(
                 handle.config,
                 handle.pod_name,
                 ["tail", "-f", "/dev/null"],
                 consumer,
                 container: @container
               )

      assert Process.alive?(channel)

      Process.exit(consumer, :kill)

      assert eventually(fn -> not Process.alive?(channel) end, 5_000),
             "the exec channel outlived the process it was delivering to"

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
      #
      # The provocation is asserted rather than assumed. This used to be
      # `kill -9 $(pidof tail) 2>/dev/null; echo killed` — which kills nothing at
      # all when `pidof` matches nothing, while `echo` kept the exec's status at
      # 0. The test then passed identically whether or not a channel was ever
      # dropped, so it defended nothing on the run that mattered.
      tail_pid = handle |> sh("pidof tail | awk '{print $1}'") |> String.trim()

      assert tail_pid != "",
             "no `tail` was running, so no channel was dropped and the reconnect below is untested"

      sh(handle, "kill -9 #{tail_pid}")

      assert eventually(
               fn ->
                 handle
                 |> sh("kill -0 #{tail_pid} 2>/dev/null && echo alive || echo gone")
                 |> String.trim() == "gone"
               end,
               5_000
             ),
             "the reader's `tail` survived the kill, so the channel never dropped"

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

  describe "reader failure reasons" do
    test "giving up names the container's own error, not just the transport", %{opts: opts} do
      # Deliberately no write_tee/2. The init container creates /var/log/cc but
      # not out.jsonl, so `tail -c +1 -f` exits 1 at once with
      # "tail: can't open '<path>': No such file or directory" on channel 2 —
      # and that line exists only because open_stream/1 asks for `stderr: true`.
      # With `exec_params/2`'s default of false the kubelet never opens channel 2
      # at all and the reader's `{:stderr, _}` clause is dead code, which is what
      # this test would notice.
      {:ok, handle} = Kubernetes.provision(opts)

      log =
        capture_log(fn ->
          {:ok, _reader} = Kubernetes.start_reader(handle, relay(), Backend.new_cursor())

          # Five failed opens with jittered 100/200/400/800/1600 ms backoff, so
          # this settles in about three seconds.
          assert_receive {:cast, :eof}, 30_000
        end)

      assert log =~ "giving up", "the reader ended the session without saying why"

      assert log =~ "tail: can't open",
             "the give-up reason carried no container diagnostics: #{log}"

      assert log =~ handle.tee_path, "the give-up reason did not name the file it could not read"

      Kubernetes.destroy(handle)
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
      #
      # The sentinel is the CLI itself, not PID 1's command: PID 1 used to be
      # `sleep infinity` and that string was the guard, which coupled a security
      # assertion to an unrelated implementation detail. The CLI is what this
      # test is about, and it is running by construction here.
      assert ps =~ "ps -o args" or ps =~ "/bin/sh", "ps produced nothing to inspect"
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

    test "an env-file write that cannot create the file is an error, not a launched CLI",
         %{opts: opts} do
      # This is the one exec whose failure used to be invisible: `await_close/1`
      # returned :ok on the first close frame and discarded channel 3, so a write
      # that could not create the file looked fine and the CLI started with no
      # credentials — failing later, somewhere else, for a reason that named none
      # of this.
      {:ok, handle} = Kubernetes.provision(opts)

      # Assert the provocation before relying on it. `write_env_file/2` bounds
      # the read with `head -c <bytes>` rather than `cat` (which would need a
      # stdin EOF, and closing the socket to deliver one races the channel-3
      # status), so this mirrors the real command: a redirect into a directory
      # that does not exist is a genuine non-zero exit, and 1 is the code
      # busybox `sh` reports for it.
      assert sh(handle, "head -c 5 > /no-such-dir/cc.env </dev/null; echo code=$?") =~ "code=1"

      unwritable = %{handle | env_path: "/no-such-dir/cc.env"}

      assert {:error, {:k8s, {:exit_status, 1}}} =
               Kubernetes.exec(unwritable, "/bin/sh", @echo_cli, %{})

      # Nothing was launched either. The launcher publishes its pid before it
      # does anything else, so the absence of that file is proof the pipeline
      # never ran — a failed credential write must not leave a CLI running
      # without credentials.
      launcher =
        sh(handle, "ls /var/run/cc.launcher >/dev/null 2>&1 && echo PRESENT || echo GONE")

      assert launcher =~ "GONE", "the CLI was launched despite having no credential file"

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

  describe "exec exit codes over v4.channel.k8s.io" do
    test "a non-zero command is an error rather than a started session", %{opts: opts} do
      {:ok, handle} = Kubernetes.provision(opts)

      assert {:ok, "ok"} =
               API.exec_once(handle.config, handle.pod_name, ["/bin/sh", "-c", "printf ok"],
                 container: @container
               )

      # `{:exit_status, 7}` rather than `{:exec_failed, _}` is itself the
      # assertion that `v4.channel.k8s.io` was negotiated: under v1 channel 3
      # carries runtime-specific English -- "Error executing in Docker Container:
      # 7" on this node, "command terminated with exit code 7" on containerd --
      # and the code is not portably extractable from it. Channel 3 arrives
      # regardless of the `stderr` parameter, so nothing extra is asked for here.
      assert {:error, {:k8s, {:exit_status, 7}}} =
               API.exec_once(
                 handle.config,
                 handle.pod_name,
                 ["/bin/sh", "-c", "printf out; exit 7"],
                 container: @container
               )

      # The same contract through the backend rather than through API. A FIFO
      # path that does not exist makes the container's `printf` fail, and
      # `collect_exec/1` used to drop channel 3 -- so write/2 read `{:ok, ""}` as
      # a delivered prompt.
      lost = %{handle | fifo_path: "/no-such-dir/cc.fifo"}
      assert {:error, {:k8s, {:exit_status, 1}}} = Kubernetes.write(lost, "lost\n")

      Kubernetes.destroy(handle)
    end
  end

  describe "API.logs/3 — the diagnostic channel" do
    test "reports silence, output, :previous and a container that never started apart",
         %{owner: owner} do
      # Case 1, both halves, on one container: "nothing to say" and "here are
      # the bytes" must be distinguishable, because this is the channel a
      # provisioning failure is diagnosed through. The container waits for a
      # file, so the silent window is not a race.
      #
      # `log_params/1` pins `follow: false`, which is what makes either fetch
      # return at all: kubereq's real default is `follow: true`, and in follow
      # mode the first frame is a zero-byte `{:stdout, ""}` and the stream never
      # ends -- the call would come back as `:exec_timeout` from bounded/2.
      running =
        owner
        |> base_opts()
        |> planted_handle(@image)
        |> plant_pod(
          &put_command(&1, [
            "/bin/sh",
            "-c",
            "while [ ! -f /tmp/go ]; do sleep 0.2; done; echo hello-logs; sleep 300"
          ])
        )

      assert eventually(fn -> pod_phase(running) == "Running" end, 60_000)

      # An empty body, not an error. With `follow: false` the API server writes
      # the body and drops the connection, which kubereq surfaces as an abnormal
      # `%Mint.TransportError{reason: :closed}` exit -- so reading that as a
      # failure made "the container said nothing" indistinguishable from "the
      # fetch failed", in the one call whose entire job is diagnosis.
      assert {:ok, ""} = API.logs(running.config, running.pod_name, container: @container)

      sh(running, "touch /tmp/go")

      assert eventually(
               fn ->
                 API.logs(running.config, running.pod_name, container: @container) ==
                   {:ok, "hello-logs\n"}
               end,
               20_000
             ),
             "the container's output never came back byte-exact"

      Kubernetes.destroy(running)

      # Case 2: `:previous`. A *terminated* container's logs are still readable
      # while the Pod exists -- that is the provisioning-failure case this
      # channel exists for -- while under `restartPolicy: Never` there is no
      # previous instance at all, and the API server refuses the upgrade with
      # 400 rather than serving an empty body. Distinct from case 1's `{:ok, ""}`
      # on purpose: "no such container" is not "the container said nothing".
      # The pair is also what pins the parameter to the wire -- drop `:previous`
      # and both calls return the same bytes.
      dead =
        owner
        |> base_opts()
        |> planted_handle(@image)
        |> plant_pod(&put_command(&1, ["/bin/sh", "-c", "echo dying-words; exit 3"]))

      assert eventually(fn -> pod_phase(dead) == "Failed" end, 60_000)
      assert {:ok, "dying-words\n"} = API.logs(dead.config, dead.pod_name, container: @container)

      assert {:error, {:k8s, {:upgrade_failed, 400}}} =
               API.logs(dead.config, dead.pod_name, container: @container, previous: true)

      Kubernetes.destroy(dead)

      # Case 3: a container that never started. There is nothing to read and the
      # API server says so with 400 rather than an empty body, so the Pod's own
      # waiting message is the only source that explains anything. The init
      # container shares the sandbox image, so the pull failure lands in
      # `initContainerStatuses`.
      bad = owner |> base_opts() |> planted_handle(@unpullable_image) |> plant_pod(& &1)

      assert eventually(fn -> pull_failure(bad) end, 90_000),
             "the image pull never failed, so the 400 below would prove nothing"

      assert {:error, {:k8s, {:upgrade_failed, 400}}} =
               API.logs(bad.config, bad.pod_name, container: @container)

      Kubernetes.destroy(bad)

      # ...and the fallback itself, through the only path that reaches it:
      # provision/1 diagnoses before it rolls the Pod back, precisely because
      # afterwards there is nothing left to ask.
      log =
        capture_log(fn ->
          assert {:error, {:k8s, {:pod_not_ready, reason}}} =
                   Kubernetes.provision(Keyword.put(base_opts(owner), :image, @unpullable_image))

          assert reason in ["ErrImagePull", "ImagePullBackOff"]
        end)

      assert log =~ "container is waiting:",
             "logs answered 400 and nothing fell back to the waiting message: #{log}"

      assert log =~ "nope/nope", "the waiting message did not name the image that could not pull"
    end
  end

  # --- helpers ---

  # The handle provision/1 would build for `opts`, without creating anything.
  # The Pods below cannot come from provision/1: it fixes the sandbox
  # container's command, and it rolls back any Pod that never reaches Running --
  # which is exactly the Pod a log test needs to read.
  defp planted_handle(opts, image) do
    {:ok, pod_name} = Kubernetes.pod_name(opts[:session_key])

    %Kubernetes{
      pod_name: pod_name,
      namespace: API.namespace(opts),
      image: image,
      tee_path: "/var/log/cc/out.jsonl",
      fifo_path: "/var/run/cc.fifo",
      env_path: "/var/run/cc.env",
      session_key: opts[:session_key],
      owner: opts[:owner],
      config: opts
    }
  end

  # Built from the real manifest, so the owner label destroy_all/1 selects on is
  # the real one -- a planted Pod that dies mid-test is still reachable by
  # cleanup.
  defp plant_pod(handle, transform) do
    {:ok, _pod} = API.create_pod(handle.config, transform.(Kubernetes.pod_manifest(handle)))
    handle
  end

  defp put_command(manifest, command) do
    update_in(manifest, ["spec", "containers"], fn [container] ->
      [Map.put(container, "command", command)]
    end)
  end

  # A Pod whose sandbox container exits with `code`, so `await_exit/2` has a
  # terminated containerStatus to read.
  defp exiting_pod(opts, code) do
    opts
    |> planted_handle(@image)
    |> plant_pod(&put_command(&1, ["/bin/sh", "-c", "exit #{code}"]))
  end

  defp pod_phase(handle) do
    case API.get_pod(handle.config, handle.pod_name) do
      {:ok, pod} -> get_in(pod, ["status", "phase"])
      {:error, _reason} -> nil
    end
  end

  # ErrImagePull first, then ImagePullBackOff once the kubelet starts backing
  # off; either means no container will ever start. Both lists, init first, for
  # the same reason the backend reads both: the init container shares the
  # sandbox image, so an unpullable image fails there while `containerStatuses`
  # is still absent.
  defp pull_failure(handle) do
    with {:ok, pod} <- API.get_pod(handle.config, handle.pod_name),
         %{"reason" => reason, "message" => message} <- waiting_state(pod) do
      reason in ["ErrImagePull", "ImagePullBackOff"] and message != ""
    else
      _ -> false
    end
  end

  defp waiting_state(pod) do
    ["initContainerStatuses", "containerStatuses"]
    |> Enum.flat_map(&(pod |> get_in(["status", &1]) |> List.wrap()))
    |> Enum.find_value(&get_in(&1, ["state", "waiting"]))
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
