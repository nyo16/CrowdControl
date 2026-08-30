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

  describe "a failed upgrade is normalized by open_exec itself (blocker: a normalizer nothing calls)" do
    # No `capture_log/1` in this block, deliberately: measured, `open_exec/5`
    # logs nothing at all on a rejected upgrade. The 2 KB line the normalization
    # exists to prevent was emitted by the *reader*, one layer up, so capturing
    # here would silence nothing and assert nothing.
    #
    # 404: the Pod, container or subresource was not there. 400: a container
    # name the Pod does not have. 403: a subprotocol the apiserver refuses.
    # All three measured live; 400 must not collapse into the 404 bucket.
    for status <- [404, 400, 403] do
      test "HTTP #{status} becomes {:upgrade_failed, #{status}} and carries no TLS material" do
        status = unquote(status)

        server =
          start_supervised!({K8sFakeServer, scripts: [[status: status]], user: :client_cert})

        result = API.open_exec(K8sFakeServer.config(server), "cc-x", ["true"], self())

        # Equality, not a pattern: `{:error, {:k8s, _}}` is satisfied by every
        # reason in the vocabulary, including the 2 KB MatchError blob this
        # normalization exists to stop.
        assert result == {:error, {:k8s, {:upgrade_failed, status}}}

        # `user: :client_cert` means the kubeconfig really does carry a client
        # certificate, so the DER is in the `%Req.Request{}` that the raw
        # upgrade error nests — inspecting that term wholesale is what put
        # `cert: <<48, 130, ...>>` into a log line.
        refute inspect(result) =~ "cert"
        refute inspect(result) =~ "Req.Request"
      end
    end

    test "a bearer token never reaches the error term, though it does reach the wire" do
      token = "eyJSOTALLYASECRETSERVICEACCOUNTTOKEN"

      server =
        start_supervised!({K8sFakeServer, scripts: [[status: 404]], user: %{"token" => token}})

      result = API.open_exec(K8sFakeServer.config(server), "cc-x", ["true"], self())

      assert result == {:error, {:k8s, {:upgrade_failed, 404}}}

      # Req's Inspect impl redacts the `authorization` header and the `:auth`
      # option, but passes every other option through untouched — so
      # `req.options.kubeconfig.current_user["token"]` prints in full. That is
      # the in-cluster ServiceAccount posture, i.e. production.
      refute inspect(result) =~ "SECRET"

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

      assert_receive :connected
      assert_receive {:stdout, "out-1"}
      assert_receive {:stderr, "err-1"}
      assert_receive {:error, @success}
      assert_receive {:close, 1000, ""}
      assert_receive {:exec_down, ^exec, :normal}

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
        start_supervised!(
          {K8sFakeServer,
           scripts: [
             [
               frames: [{:stdout, "before-drop"}, {:sleep, 50}],
               finish: :abort
             ]
           ]}
        )

      # `Connect.format_status/1` calls a `format_status/1` that `PodExec` does
      # not define, so every abnormal channel exit logs a crash report. Captured
      # so it does not scroll the suite, and asserted so the capture is not a
      # silencer.
      {reason, log} =
        with_log(fn ->
          assert {:ok, exec} =
                   API.open_exec(K8sFakeServer.config(server), "cc-x", ["tail"], self())

          assert_receive :connected
          assert_receive {:stdout, "before-drop"}
          assert_receive {:exec_down, ^exec, reason}, 2_000
          reason
        end)

      assert reason == %Mint.TransportError{reason: :closed}

      # The crash report names the transport failure and nothing else: no
      # request struct, and therefore no client certificate and no kubeconfig.
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

      assert_receive :connected
      assert_receive {:stdout, "line"}
      assert_receive {:close, 1000, ""}
      assert_receive {:exec_down, ^exec, :normal}
      refute_received {:EXIT, _pid, _reason}
    end
  end
end
