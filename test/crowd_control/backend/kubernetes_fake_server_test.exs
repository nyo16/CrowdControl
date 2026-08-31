defmodule CrowdControl.Backend.KubernetesFakeServerTest do
  # The websocket half of Backend.Kubernetes, driven through a real TLS socket
  # instead of a stub. Hermetic and in the default suite: CrowdControl.K8sFakeServer
  # binds an ephemeral loopback port, so there is no cluster and nothing shared
  # between tests.
  #
  # Every outcome here is one a live cluster cannot be made to produce on
  # demand — a rejected upgrade, a scripted exit status, a connection that dies
  # mid-stream — and none of them is reachable through the `:req_adapter` seam,
  # because kubereq overwrites `:adapter` on every `:connect` operation. See the
  # K8sFakeServer module comment.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.K8sFakeServer

  @subprotocol "v4.channel.k8s.io"

  # Verbatim v4 channel-3 payloads measured on v1.35.6+orb1. The `message` is
  # this node's container runtime talking; the assertions read `details.causes`.
  @failure ~s({"metadata":{},"status":"Failure","message":"command terminated with non-zero exit code: Error executing in Docker Container: 7","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"7"}]}})
  @success ~s({"metadata":{},"status":"Success"})

  describe "a failed upgrade is normalized (blocker: a raw struct in the failure reason)" do
    # The upgrade is no longer attempted before `open_exec/5` returns.
    #
    # kubereq 0.4.5 changed the model: its Req adapter answers a synthetic `101`
    # and casts the real request to the connection process, so `start_link/1`
    # returns `{:ok, pid}` while the handshake is still in flight and a rejected
    # upgrade cannot surface as a return value at all. Measured: `open_exec/5`
    # returns `{:ok, pid}`, the consumer is told `:connected` — which is now
    # evidence of nothing — and only then does the connection process die
    # carrying `%Mint.WebSocket.UpgradeFailureError{}`.
    #
    # So these tests assert the *asynchronous* contract, which is the only one
    # the dependency now offers. It reaches the consumer as
    # `{:exec_down, pid, reason}` because `open_exec/5` owns the link — the same
    # mechanism that stops a channel death from killing a non-trapping caller.
    #
    # 404: the Pod, container or subresource was not there. 400: a container
    # name the Pod does not have. 403: a subprotocol the apiserver refuses.
    # All three measured live; 400 must not collapse into the 404 bucket.
    for status <- [404, 400, 403] do
      test "HTTP #{status} arrives as {:upgrade_failed, #{status}} and carries no TLS material" do
        status = unquote(status)

        server =
          start_supervised!({K8sFakeServer, scripts: [[status: status]], user: :client_cert})

        assert {:ok, channel} =
                 API.open_exec(K8sFakeServer.config(server), "cc-x", ["true"], self())

        # Equality, not a pattern: `{:k8s, _}` is satisfied by every reason in
        # the vocabulary, including the raw struct this normalization exists to
        # replace.
        assert_receive {:exec_down, ^channel, reason}, 5_000
        assert reason == {:k8s, {:upgrade_failed, status}}

        # `user: :client_cert` means the kubeconfig really does carry a client
        # certificate, so the DER is reachable from the raw error term — passing
        # that through is what put `cert: <<48, 130, ...>>` into a log line.
        refute inspect(reason) =~ "cert"
        refute inspect(reason) =~ "Req.Request"
      end
    end

    test "a bearer token never reaches the error term, though it does reach the wire" do
      token = "eyJSOTALLYASECRETSERVICEACCOUNTTOKEN"

      server =
        start_supervised!({K8sFakeServer, scripts: [[status: 404]], user: %{"token" => token}})

      assert {:ok, channel} =
               API.open_exec(K8sFakeServer.config(server), "cc-x", ["true"], self())

      assert_receive {:exec_down, ^channel, reason}, 5_000
      assert reason == {:k8s, {:upgrade_failed, 404}}

      # Req's Inspect impl redacts the `authorization` header and the `:auth`
      # option, but passes every other option through untouched — so
      # `req.options.kubeconfig.current_user["token"]` prints in full. That is
      # the in-cluster ServiceAccount posture, i.e. production.
      refute inspect(reason) =~ "SECRET"

      # And the refutation is about normalization, not about a kubeconfig that
      # never carried a token in the first place.
      assert [request] = K8sFakeServer.requests(server)
      assert request =~ "authorization: Bearer #{token}"
    end
  end

  describe "exec frames reach the consumer (blocker: a reader that cannot see stderr)" do
    test "scripted stdout, stderr and status frames arrive as messages" do
      server =
        start_supervised!(
          {K8sFakeServer,
           scripts: [
             [
               subprotocol: @subprotocol,
               frames: [{:stdout, "out-1"}, {:stderr, "err-1"}, {:status, @success}]
             ]
           ]}
        )

      assert {:ok, exec} =
               API.open_exec(
                 K8sFakeServer.config(server),
                 "cc-x",
                 ["tail", "-c", "+1", "-f", "/var/log/cc/out.jsonl"],
                 self(),
                 stderr: true,
                 container: "sandbox"
               )

      # Explicit timeouts, not the 100 ms default. The listener holds scripted
      # frames back by a settling window (so they cannot be swallowed as body
      # parts of the 101 — see the module doc), and that window plus TLS setup
      # under a loaded async suite exceeds 100 ms often enough to flake. The
      # property under test is that the frames arrive in order, not that they
      # arrive within a tenth of a second.
      assert_receive :connected, 2_000
      assert_receive {:stdout, "out-1"}, 2_000
      assert_receive {:stderr, "err-1"}, 2_000
      assert_receive {:error, @success}, 2_000
      assert_receive {:close, 1000, ""}, 2_000
      assert_receive {:exec_down, ^exec, :normal}, 2_000

      # The exec parameters are query params, so the request head is where
      # `stderr: true` becomes observable. Without it the kubelet makes channel
      # 2 an IgnoreChannel and discards stderr server-side, which is what made
      # the reader's `{:stderr, _}` clause dead code.
      assert [request] = K8sFakeServer.requests(server)
      assert request =~ "stderr=true"
      assert request =~ "container=sandbox"
      assert request =~ "sec-websocket-protocol: #{@subprotocol}"
    end
  end

  describe "exec exit codes over v4.channel.k8s.io (blocker: a non-zero exec reported as success)" do
    test "exec_once returns the channel-3 status, not the stdout it also collected" do
      server =
        start_supervised!(
          {K8sFakeServer,
           scripts: [
             [subprotocol: @subprotocol, frames: [{:stdout, "out"}, {:status, @failure}]]
           ]}
        )

      config = K8sFakeServer.config(server)

      # A2, verbatim: `details.causes[0].message` is the decimal string "7", and
      # the stdout that arrived alongside it must not become an `{:ok, _}`.
      assert {:error, {:k8s, {:exit_status, 7}}} =
               API.exec_once(config, "cc-x", ["/bin/sh", "-c", "printf out; exit 7"])

      # A3: v4 emits a channel-3 frame on success too, so "no news is good news"
      # is the wrong reading of the channel — the Success record has to be
      # decoded, not merely tolerated.
      :ok =
        K8sFakeServer.script(server,
          subprotocol: @subprotocol,
          frames: [{:stdout, "ok"}, {:status, @success}]
        )

      assert {:ok, "ok"} = API.exec_once(config, "cc-x", ["/bin/sh", "-c", "printf ok"])

      # Both execs negotiated v4. Under v1 the exit code is only available as
      # runtime-specific prose, so the header is what makes the tuple above a
      # code rather than a string.
      assert [failed, succeeded] = K8sFakeServer.requests(server)
      assert failed =~ "sec-websocket-protocol: #{@subprotocol}"
      assert succeeded =~ "sec-websocket-protocol: #{@subprotocol}"
    end
  end

  describe "a mid-stream drop (blocker: a channel death that kills its caller)" do
    test "an abrupt close arrives as {:exec_down, pid, transport error}" do
      server =
        start_supervised!({K8sFakeServer,
         scripts: [
           [
             # 300 ms, not 50. `finish: :abort` is an abortive close, and an RST
             # discards whatever is still sitting unread in the peer's receive
             # buffer — so a frame written just before it can vanish, and did
             # once the client's read timing changed under kubereq 0.4.5. The
             # gap has to be wide enough that "the frame was delivered" is not
             # a race. It is loopback: 300 ms is enormous.
             frames: [{:stdout, "before-drop"}, {:sleep, 300}],
             finish: :abort
           ]
         ]})

      # `Connect.format_status/1` calls a `format_status/1` that `PodExec` does
      # not define, so every abnormal channel exit logs a crash report. Captured
      # so it does not scroll the suite, and asserted so the capture is not a
      # silencer.
      {reason, log} =
        with_log(fn ->
          assert {:ok, exec} =
                   API.open_exec(K8sFakeServer.config(server), "cc-x", ["tail"], self())

          # Note this is no longer evidence of an established channel: since
          # kubereq 0.4.5 it is sent before the upgrade is attempted.
          assert_receive :connected, 2_000

          assert_receive {:stdout, "before-drop"}, 2_000
          assert_receive {:exec_down, ^exec, reason}, 3_000
          reason
        end)

      # Normalized by `open_exec/5`'s owner, not the raw Mint struct: one
      # vocabulary regardless of which kubereq reported it, and regardless of
      # whether it arrived synchronously or asynchronously.
      assert reason == {:k8s, {:transport, :closed}}

      # The crash report names the transport failure and nothing else: no
      # request struct, and therefore no client certificate and no kubeconfig.
      # `CrowdControl.LogRedactor` is what holds that second line true — kubereq
      # 0.4.5 puts the whole cast, request included, in its last-message report.
      assert log =~ "Mint.TransportError"
      refute log =~ "Req.Request"

      # A message, not a signal. This test process does not trap exits, so a
      # linked channel would have killed it before this line; the assertions
      # above are only reachable because `open_exec/5` owns the link itself.
      refute_received {:EXIT, _pid, _reason}
    end

    test "a graceful close arrives as {:close, 1000, \"\"}" do
      server =
        start_supervised!(
          {K8sFakeServer, scripts: [[frames: [{:stdout, "line"}], finish: :close]]}
        )

      assert {:ok, exec} =
               API.open_exec(K8sFakeServer.config(server), "cc-x", ["tail"], self())

      assert_receive :connected, 2_000
      assert_receive {:stdout, "line"}, 2_000
      assert_receive {:close, 1000, ""}, 2_000
      assert_receive {:exec_down, ^exec, :normal}, 2_000
      refute_received {:EXIT, _pid, _reason}
    end
  end
end
