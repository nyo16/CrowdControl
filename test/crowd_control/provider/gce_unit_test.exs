defmodule CrowdControl.GceFakeAgent do
  @moduledoc false
  # sandboxd's stand-in on the far side of the tunnel. A real listening socket
  # rather than a Req adapter, because the property under test is that bytes
  # cross a real SSH connection.

  @spec start(keyword()) :: {:ok, pos_integer(), pid()}
  def start(opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: :loopback, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    {:ok, port, spawn(fn -> accept(listen, status) end)}
  end

  defp accept(listen, status) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.send(socket, response(status))
        :gen_tcp.close(socket)
        accept(listen, status)

      {:error, _closed} ->
        :ok
    end
  end

  defp response(200), do: http(200, "OK", ~s({"ok":true}))
  defp response(status), do: http(status, "Service Unavailable", ~s({"error":"not ready"}))

  defp http(status, reason, body) do
    [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end
end

defmodule CrowdControl.GceFakeVmKeyCb do
  @moduledoc false
  # The fake VM's sshd key callback. `host_key/2` and `is_auth_key/3` are both
  # mandatory on the server side, and a daemon's host-key algorithms come from
  # `preferred_algorithms`'s `public_key` list rather than from
  # `pref_public_key_algs` — get that wrong and `:ssh.daemon/3` fails with
  # "No host key available".

  @behaviour :ssh_server_key_api

  @impl true
  def host_key(:"ssh-ed25519", opts) do
    case private(opts, :host_key) do
      :undefined -> {:error, ~c"no host key"}
      key -> {:ok, key}
    end
  end

  def host_key(algorithm, _opts), do: {:error, ~c"unsupported algorithm: #{algorithm}"}

  @impl true
  def is_auth_key(key, _user, opts), do: key in private(opts, :auth_keys)

  defp private(opts, key) do
    :proplists.get_value(key, :proplists.get_value(:key_cb_private, opts, []), :undefined)
  end
end

defmodule CrowdControl.Provider.GceUnitTest do
  # Hermetic and credential-free. Every Compute API call is answered by a stub
  # Req adapter, and the "VM" on the far side of the SSH tunnel is an
  # in-process `:ssh.daemon` plus a `:gen_tcp` stand-in for `sandboxd` — a real
  # listening socket, because the property those tests exist for is that bytes
  # traverse a real tunnel, which a stubbed HTTP adapter would bypass entirely.
  #
  # No GCP credentials, no `gcloud`, no network. Everything that genuinely
  # needs a project lives in test/crowd_control/provider/gce_test.exs.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Sandboxd.API, as: AgentAPI
  alias CrowdControl.GceFakeAgent
  alias CrowdControl.GceFakeVmKeyCb
  alias CrowdControl.GcpReqStub
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Gce
  alias CrowdControl.Provider.Gce.API
  alias CrowdControl.Provider.Gce.Startup
  alias CrowdControl.Provider.Gce.Tunnel

  # No @secret here and no setup mutating :sandboxd_secret: test_helper.exs sets
  # one for the whole suite. A per-module secret raced every other async module
  # deriving a token from it, which showed up as an intermittent 401 through
  # this file's SSH tunnel.
  @session "abcdef0123456789abcdef0123456789"
  @other_session "00000000000000000000000000000000"
  @instance "cc-sbx-abcdef0123456789abcdef0123456789"

  @instances "/projects/cc-test/zones/us-central1-a/instances"
  @instance_path "/projects/cc-test/zones/us-central1-a/instances/cc-sbx-abcdef0123456789abcdef0123456789"

  @url "https://example.test/sandboxd-linux-amd64.tar.gz"
  @sha256 "9f2fcb1b3a4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7"

  describe "required options (blocker: a billed VM that cannot be reconnected to)" do
    test "refuses without a session key, which every derived secret depends on" do
      assert {:error, {:gce, :session_key_required}} =
               Gce.acquire(acquire_opts(nil, session_key: nil))
    end

    test "refuses a session key that would make an illegal instance name" do
      assert {:error, {:gce, {:invalid_name, "Bad Name"}}} =
               Gce.acquire(acquire_opts(nil, session_key: "Bad Name"))
    end

    test "refuses without :sandboxd_url" do
      {config, _stub} = GcpReqStub.new(&never_called/1)

      assert {:error, {:gce, :sandboxd_url_required}} =
               Gce.acquire(acquire_opts(config, sandboxd_url: nil))
    end

    test "every validation gate runs before any HTTP happens" do
      # A router that raises proves nothing reached the transport: a VM must
      # never be created from options that were going to be rejected anyway.
      {config, _stub} = GcpReqStub.new(&never_called/1)

      assert {:error, {:gce, :sandboxd_sha256_required}} =
               Gce.acquire(acquire_opts(config, sandboxd_sha256: nil))
    end
  end

  describe "the release is verified, never trusted (blocker: an unverified binary run as a service)" do
    test "a missing checksum is an error, not a skipped check" do
      assert {:error, {:gce, :sandboxd_sha256_required}} = Startup.render(sandboxd_url: @url)
    end

    test "rejects a checksum that is not 64 hex characters" do
      assert {:error, {:gce, {:bad_sandboxd_sha256, "deadbeef"}}} =
               Startup.render(sandboxd_url: @url, sandboxd_sha256: "deadbeef")
    end

    test "the archive is verified against that checksum before it is extracted" do
      script = render()

      assert script =~ "printf '%s  %s\\n' '#{@sha256}'"
      assert script =~ "sha256sum -c -"

      # Order is as load-bearing as presence: a checksum verified after
      # extraction is a checksum verified after the payload is already on disk.
      {verify_at, _length} = :binary.match(script, "sha256sum -c -")
      {extract_at, _length} = :binary.match(script, "tar -xzf")
      assert verify_at < extract_at
    end

    test "installs libssl3 and libncurses6, which the embedded ERTS needs" do
      # Both were established by the release failing to boot without them on a
      # bare Debian image: include_erts ships ERTS, but crypto's NIF still
      # links against the system OpenSSL.
      script = render()

      assert script =~ "libssl3"
      assert script =~ "libncurses6"
    end

    test "the artifact fetch follows redirects, and the metadata fetch does not" do
      # Found by pointing the integration suite at this project's *own* published
      # release. A GitHub release asset answers 302 and redirects to
      # objects.githubusercontent.com, so `curl -fsS` without -L treated the
      # redirect as a failure: the bootstrap died and `acquire/1` reported a health
      # timeout on a VM that was already billing. The documented URL could never
      # have worked.
      #
      # Safe here specifically because the checksum above is mandatory: a redirect
      # to somewhere else produces a mismatch and the agent is never installed.
      script = render()
      # The command spans a shell line-continuation, so the match has to cross it.
      assert script =~ ~r/curl -fsSL[\s\S]{0,200}'#{Regex.escape(@url)}'/,
             "the release fetch must follow redirects; a GitHub release asset is a 302"

      # The opposite requirement, one line down: the metadata server never
      # redirects, and following a redirect from it would turn a link-local
      # credential fetch into a request at somewhere else's choosing.
      assert script =~ "curl -fsS -H 'Metadata-Flavor: Google'"
      refute script =~ "curl -fsSL -H 'Metadata-Flavor: Google'"
    end

    test "rejects a URL that could break out of its shell quoting" do
      assert {:error, {:gce, {:bad_sandboxd_url, _}}} =
               Startup.render(
                 sandboxd_url: "https://example.test/x';rm -rf /;'",
                 sandboxd_sha256: @sha256
               )
    end
  end

  describe "no secret reaches the script body (blocker: a token readable by every project viewer)" do
    test "the token travels in metadata and appears nowhere in the script" do
      metadata = metadata(insert_body())
      token = Provider.token(@session)

      assert metadata["cc-sandboxd-token"] == token
      refute metadata["startup-script"] =~ token
    end

    test "the launcher reads the token from the metadata server at start" do
      script = render()

      assert script =~ "Metadata-Flavor: Google"
      assert script =~ "attributes/cc-sandboxd-token"
      assert script =~ "export CC_SANDBOXD_TOKEN"
    end

    test "the agent binds loopback, because the tunnel is the only way in" do
      assert render() =~ "export CC_SANDBOXD_BIND='127.0.0.1'"
    end

    test "the ssh private key appears nowhere in the insert request" do
      refute_present(
        :erlang.term_to_binary(insert_body()),
        private_key(@session),
        "the ssh private key"
      )
    end
  end

  describe "instance spec (blocker: a public sandbox VM, or an orphan with no server-side deadline)" do
    test "spot VMs delete themselves on termination" do
      scheduling = insert_body()["scheduling"]

      assert scheduling["provisioningModel"] == "SPOT"
      assert scheduling["instanceTerminationAction"] == "DELETE"
    end

    test "maxRunDuration always outlasts the session it is meant to backstop" do
      # The backstop that needs no BEAM: if this node dies mid-acquire, nothing
      # local knows the VM exists and only GCE can still delete it. It must
      # still never fire while the session is legitimately running.
      %{"seconds" => derived} = insert_body(timeout: 60_000)["scheduling"]["maxRunDuration"]

      assert derived > 60
    end

    test "an explicit deadline is honoured" do
      assert insert_body(max_run_duration: 3_600)["scheduling"]["maxRunDuration"] == %{
               "seconds" => 3_600
             }
    end

    test "refuses a deadline that could expire while acquire/1 is still waiting" do
      {config, _stub} = GcpReqStub.new(&never_called/1)

      assert {:error, {:gce, {:bad_max_run_duration, 30}}} =
               Gce.acquire(acquire_opts(config, max_run_duration: 30, ready_timeout: 120_000))
    end

    test "an external address is attached by default and can be refused" do
      [nic] = insert_body()["networkInterfaces"]
      assert [%{"type" => "ONE_TO_ONE_NAT"}] = nic["accessConfigs"]

      [hardened] = insert_body(external_ip: false)["networkInterfaces"]
      refute Map.has_key?(hardened, "accessConfigs")
    end

    test "no service account is attached unless one is asked for" do
      # With one, the sandboxed CLI can mint project credentials from the
      # metadata server for every granted scope.
      refute Map.has_key?(insert_body(), "serviceAccounts")

      assert [%{"email" => "sa@cc-test.iam.gserviceaccount.com"}] =
               insert_body(service_account: "sa@cc-test.iam.gserviceaccount.com")[
                 "serviceAccounts"
               ]
    end

    test "the startup script rides in metadata, under the key GCE runs" do
      script = metadata(insert_body())["startup-script"]

      assert script =~ "#!/bin/bash"
      assert script =~ "cc-sandboxd.service"
    end
  end

  describe "labels and metadata (blocker: a reaper that destroys another owner's VM)" do
    test "no label key contains a dot, which GCE rejects outright" do
      labels = insert_body()["labels"]

      assert map_size(labels) == 3

      for key <- Map.keys(labels) do
        refute key =~ ".", "#{key} would be rejected by GCE"
        assert key =~ ~r/^[a-z][a-z0-9_-]*$/
      end
    end

    test "the owner label is a hash and the raw owner round-trips through metadata" do
      body = insert_body()

      # "nonode@nohost" is not a legal label value, and sanitizing it would let
      # two owners collapse into one selector.
      assert body["labels"]["crowd_control-owner-hash"] == Gce.owner_label("node-a")
      assert metadata(body)["cc-owner"] == "node-a"
      assert body["labels"]["crowd_control-session"] == @session
      assert body["labels"]["crowd_control-agent"] == "sandboxd"
    end

    test "the ssh key and the token cannot be overridden by caller metadata" do
      metadata =
        metadata(
          insert_body(metadata: %{"ssh-keys" => "attacker:key", "cc-sandboxd-token" => "nope"})
        )

      assert metadata["ssh-keys"] == Tunnel.metadata_ssh_keys(@session)
      assert metadata["cc-sandboxd-token"] == Provider.token(@session)

      # Both are load-bearing: OS Login makes the guest agent ignore metadata
      # ssh-keys entirely, and unblocked project keys are appended to ours.
      assert metadata["enable-oslogin"] == "FALSE"
      assert metadata["block-project-ssh-keys"] == "true"
    end
  end

  describe "acquire rollback (blocker: a leaked spot VM billing forever)" do
    test "a failed insert still deletes the instance" do
      # insert_and_wait also fails when the *operation poll* timed out, which
      # happens with a VM already created and billing. The name is derived
      # before the insert precisely so this delete can always be issued.
      {config, stub} =
        GcpReqStub.new(fn
          {:post, @instances} -> {500, GcpReqStub.error(500, "backend error")}
          {:delete, @instance_path} -> {200, GcpReqStub.operation()}
        end)

      assert {:error, {:gce, {:http_status, 500, _}}} = Gce.acquire(acquire_opts(config, []))
      assert {:delete, @instance_path} in GcpReqStub.calls(stub)
    end

    test "an operation that completes with an error deletes the instance" do
      {config, stub} =
        GcpReqStub.new(fn
          {:post, @instances} ->
            {200,
             GcpReqStub.operation("DONE", %{
               "error" => %{"errors" => [%{"message" => "ZONE_RESOURCE_POOL_EXHAUSTED"}]}
             })}

          {:delete, @instance_path} ->
            {200, GcpReqStub.operation()}
        end)

      assert {:error, {:gce, {:operation_failed, "ZONE_RESOURCE_POOL_EXHAUSTED"}}} =
               Gce.acquire(acquire_opts(config, []))

      assert {:delete, @instance_path} in GcpReqStub.calls(stub)
    end

    test "an instance that never reaches RUNNING is deleted" do
      {config, stub} =
        GcpReqStub.new(fn
          {:post, @instances} -> {200, GcpReqStub.operation()}
          {:get, @instance_path} -> {200, GcpReqStub.instance(@instance, status: "PROVISIONING")}
          {:delete, @instance_path} -> {200, GcpReqStub.operation()}
        end)

      assert {:error, {:gce, {:not_running, "PROVISIONING"}}} =
               Gce.acquire(acquire_opts(config, []))

      assert {:delete, @instance_path} in GcpReqStub.calls(stub)
    end

    test "a RUNNING instance with no usable address is deleted" do
      {config, stub} =
        GcpReqStub.new(fn
          {:post, @instances} -> {200, GcpReqStub.operation()}
          {:get, @instance_path} -> {200, GcpReqStub.instance(@instance, external_ip: nil)}
          {:delete, @instance_path} -> {200, GcpReqStub.operation()}
        end)

      assert {:error, {:gce, {:no_address, true}}} = Gce.acquire(acquire_opts(config, []))
      assert {:delete, @instance_path} in GcpReqStub.calls(stub)
    end

    test "an agent that never answers health deletes the instance" do
      # The tunnel opens fine here — it never probes the remote end — so health
      # polling is the only thing that can catch this.
      vm = fake_vm(status: 503)

      {config, stub} =
        GcpReqStub.new(fn
          {:post, @instances} ->
            {200, GcpReqStub.operation()}

          {:get, @instance_path} ->
            {200, GcpReqStub.instance(@instance, external_ip: "127.0.0.1")}

          {:delete, @instance_path} ->
            {200, GcpReqStub.operation()}
        end)

      assert {:error, {:sandboxd, {:ready_timeout, _}}} =
               Gce.acquire(acquire_opts(config, tunnel_opts(vm) ++ [ready_timeout: 900]))

      assert {:delete, @instance_path} in GcpReqStub.calls(stub)
    end
  end

  describe "the tunnel (blocker: an agent port published on every interface, or a MITM'd VM)" do
    test "acquire only returns once health has answered through the tunnel" do
      vm = fake_vm()
      {config, _stub} = GcpReqStub.new(&running_vm/1)

      assert {:ok, handle, endpoint} = Gce.acquire(acquire_opts(config, tunnel_opts(vm)))
      on_exit(fn -> Tunnel.close(endpoint.transport) end)

      assert handle.instance_name == @instance
      assert endpoint.base_url =~ ~r{^http://127\.0\.0\.1:\d+$}
      assert is_pid(endpoint.transport)
      assert Tunnel.alive?(endpoint.transport)

      # Not a stub: this request crosses the SSH connection.
      assert AgentAPI.health(endpoint) == :ok
      assert endpoint.token == Provider.token(@session)
    end

    test "the forwarded port is bound to loopback only" do
      # `:any` instead of `:loopback` publishes the sandbox agent on every
      # interface of *this* host and still returns a perfectly normal
      # `{:ok, port}`. There is no error to catch, so there is only this.
      vm = fake_vm()
      {config, _stub} = GcpReqStub.new(&running_vm/1)

      assert {:ok, _handle, endpoint} = Gce.acquire(acquire_opts(config, tunnel_opts(vm)))
      on_exit(fn -> Tunnel.close(endpoint.transport) end)

      %{port: port} = URI.parse(endpoint.base_url)

      assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], 1_000)
      :gen_tcp.close(socket)

      case non_loopback_address() do
        nil -> :ok
        address -> assert {:error, _} = :gen_tcp.connect(address, port, [active: false], 1_000)
      end
    end

    test "a host key that does not match the pin is rejected, with the real fingerprint" do
      # `false` from is_host_key/5 would NOT reject the key, and
      # :ssh.connect/4 replaces the reason with the useless "Key exchange
      # failed" unless the callback reports it out of band.
      vm = fake_vm()

      assert {:error, {:gce, {:tunnel, {:host_key_mismatch, fingerprint}}}} =
               Tunnel.open("127.0.0.1", @session,
                 ssh_port: vm.ssh_port,
                 agent_port: vm.agent_port,
                 host_key_fp: "SHA256:definitely-not-this-host-key"
               )

      assert fingerprint == vm.host_key_fp
    end

    test "reconnect rebuilds the path on a new local port" do
      vm = fake_vm()
      {config, _stub} = GcpReqStub.new(&running_vm/1)

      assert {:ok, handle, first} = Gce.acquire(acquire_opts(config, tunnel_opts(vm)))

      # The shape CrowdControl.Reaper reattaches with: a scrubbed handle whose
      # options the caller supplied again. Nothing about the endpoint survives
      # — not the port, not the connection, and not the keypair, which is
      # re-derived from the session key.
      reattaching = %{Gce.scrub(handle) | config: acquire_opts(config, tunnel_opts(vm))}

      assert {:ok, reconnected, second} = Gce.reconnect(reattaching)
      on_exit(fn -> Tunnel.close(second.transport) end)

      assert second.base_url != first.base_url
      assert reconnected.instance_name == @instance
      assert AgentAPI.health(second) == :ok

      Tunnel.close(first.transport)
    end

    test "reconnect refuses a handle that never had an instance" do
      assert {:error, {:gce, :not_provisioned}} = Gce.reconnect(%Gce{})
    end
  end

  describe "keypair derivation (blocker: a live sandbox no restart can ever reach again)" do
    test "the same session key derives the same keypair" do
      # gcp_compute has no instances.setMetadata, so a VM's authorized_keys is
      # fixed at create time. A random key would leave every sandbox
      # unreachable after a node restart.
      assert Tunnel.keypair(@session) == Tunnel.keypair(@session)
      assert Tunnel.keypair(@session) != Tunnel.keypair(@other_session)
    end

    test "the seed is the agent token, hashed" do
      # Pinned deliberately: this derivation is a compatibility surface. If it
      # changes, every already-running sandbox becomes permanently unreachable,
      # because its authorized_keys cannot be updated.
      assert private_key(@session) ==
               :crypto.hash(:sha256, "cc-gce-ssh/v1" <> Provider.token(@session))
    end

    test "the metadata line is the format the guest agent parses" do
      line = Tunnel.metadata_ssh_keys(@session)

      assert "ccsandbox:" <> key_value = line
      assert key_value =~ ~r{^ssh-ed25519 [A-Za-z0-9+/]+=* crowd_control$}

      # Round-trips through OTP's own parser, back to the derived public key.
      assert [{public_key, _attributes}] = :ssh_file.decode(key_value, :auth_keys)
      assert public_key == @session |> Tunnel.keypair() |> :ssh_file.extract_public_key()
    end

    test "the non-expiring form is used, so no malformed expireOn can void the key" do
      # A `google-ssh {json}` comment whose expireOn does not parse makes the
      # guest agent drop the key entirely — total, silent loss of access.
      # Exposure is bounded by VM deletion and maxRunDuration instead.
      refute Tunnel.metadata_ssh_keys(@session) =~ "google-ssh"
    end
  end

  describe "release/1 (blocker: a teardown that fails on the second call)" do
    test "is idempotent, because already-gone is the desired end state" do
      {config, _stub} =
        GcpReqStub.new(fn {:delete, @instance_path} ->
          {404, GcpReqStub.error(404, "not found")}
        end)

      handle = handle(gce_config: config)

      assert :ok = Gce.release(handle)
      assert :ok = Gce.release(handle)
    end

    test "tolerates a transport failure rather than raising in teardown" do
      {config, _stub} =
        GcpReqStub.new(fn {:delete, _} -> %Req.TransportError{reason: :econnrefused} end)

      assert :ok = Gce.release(handle(gce_config: config))
    end

    test "is a no-op for a handle that never got an instance" do
      assert :ok = Gce.release(%Gce{})
    end

    test "cannot fail loudly even with an unusable client config" do
      # Session calls release/1 from paths that must all complete. A VM that
      # outlives us is bounded by maxRunDuration rather than permanent.
      assert :ok = Gce.release(handle(gce_config: :not_a_config))
    end
  end

  describe "list_live/1 (blocker: a reaper pruning live, billed sandboxes)" do
    test "paginates exhaustively, threading the page token" do
      {:ok, pages} = Agent.start_link(fn -> 0 end)

      {config, stub} =
        GcpReqStub.new(fn {:get, @instances} ->
          case Agent.get_and_update(pages, &{&1, &1 + 1}) do
            0 -> {200, GcpReqStub.list_page([live("one")], "token-2")}
            1 -> {200, GcpReqStub.list_page([live("two")], "token-3")}
            2 -> {200, GcpReqStub.list_page([live("three")])}
          end
        end)

      assert {:ok, handles} = Gce.list_live(gce_config: config, owner: "node-a")
      assert Enum.map(handles, & &1.instance_name) == ["one", "two", "three"]

      assert GcpReqStub.params(stub, 1)["pageToken"] == "token-2"
      assert GcpReqStub.params(stub, 2)["pageToken"] == "token-3"
    end

    test "a mid-pagination failure is an error, never a shorter list" do
      # A short list makes the reaper read a live sandbox as stale and delete
      # its store record, orphaning a running, billed VM permanently.
      {:ok, pages} = Agent.start_link(fn -> 0 end)

      {config, _stub} =
        GcpReqStub.new(fn {:get, @instances} ->
          case Agent.get_and_update(pages, &{&1, &1 + 1}) do
            0 -> {200, GcpReqStub.list_page([live("one")], "token-2")}
            _ -> {503, GcpReqStub.error(503, "unavailable")}
          end
        end)

      assert {:error, {:gce, {:http_status, 503, _}}} =
               Gce.list_live(gce_config: config, owner: "node-a")
    end

    test "filters server-side on the owner hash" do
      {config, stub} =
        GcpReqStub.new(fn {:get, @instances} -> {200, GcpReqStub.list_page([])} end)

      assert {:ok, []} = Gce.list_live(gce_config: config, owner: "node-a")

      assert GcpReqStub.params(stub, 0)["filter"] ==
               ~s(labels.crowd_control-owner-hash = "#{Gce.owner_label("node-a")}")
    end

    test "ignores instances that are not sandboxd sandboxes" do
      {config, _stub} =
        GcpReqStub.new(fn {:get, @instances} ->
          {200,
           GcpReqStub.list_page([
             live("ours"),
             GcpReqStub.instance("theirs",
               labels: %{"crowd_control-owner-hash" => Gce.owner_label("node-a")}
             )
           ])}
        end)

      assert {:ok, [handle]} = Gce.list_live(gce_config: config, owner: "node-a")
      assert handle.instance_name == "ours"
    end

    test "lifts the session key from the label and the raw owner from metadata" do
      {config, _stub} =
        GcpReqStub.new(fn {:get, @instances} -> {200, GcpReqStub.list_page([live("ours")])} end)

      assert {:ok, [handle]} = Gce.list_live(gce_config: config, owner: "node-a")

      assert handle.session_key == @session
      # The label is only a hash; the reaper compares raw owners exactly before
      # destroying anything.
      assert handle.owner == "node-a"
      assert handle.project == "cc-test"
      assert handle.zone == "us-central1-a"
    end
  end

  describe "age_ms/1 (blocker: reaping a sandbox that is still being provisioned)" do
    test "is measured from the instance's own creation timestamp" do
      created = DateTime.utc_now() |> DateTime.add(-90, :second) |> DateTime.to_iso8601()

      {config, _stub} =
        GcpReqStub.new(fn {:get, @instance_path} ->
          {200, GcpReqStub.instance(@instance, created_at: created)}
        end)

      assert_in_delta Gce.age_ms(handle(gce_config: config)), 90_000, 5_000
    end

    test "is nil rather than zero when the age cannot be established" do
      # The reaper reads nil as "assume young"; guessing zero would make it
      # destroy a VM it could not date.
      {config, _stub} = GcpReqStub.new(fn {:get, _} -> {403, GcpReqStub.error(403, "denied")} end)

      assert Gce.age_ms(handle(gce_config: config)) == nil
      assert Gce.age_ms(%Gce{}) == nil
    end
  end

  describe "scrub/1 (blocker: a live GCP credential in a Store record on disk)" do
    test "keeps exactly the five fields that name the resource" do
      {config, _stub} = GcpReqStub.new(&never_called/1)

      scrubbed = Gce.scrub(handle(gce_config: config, api_key: "sk-real"))

      assert scrubbed.project == "cc-test"
      assert scrubbed.zone == "us-central1-a"
      assert scrubbed.instance_name == @instance
      assert scrubbed.session_key == @session
      assert scrubbed.owner == "node-a"
      assert scrubbed.config == []
      assert scrubbed.tunnel == nil
    end

    test "the persisted bytes carry no config, no token and no private key" do
      {config, _stub} = GcpReqStub.new(&never_called/1)

      bytes =
        handle(gce_config: config, api_key: "sk-real", env: %{"ANTHROPIC_API_KEY" => "sk-also"})
        |> Gce.scrub()
        |> :erlang.term_to_binary()

      # inspect/1 would be vacuous here: both Provider.Endpoint and
      # GcpCompute.Config redact themselves, so only the raw term proves
      # absence.
      refute_present(bytes, "GcpCompute.Config", "the client config")
      refute_present(bytes, Provider.token(@session), "the agent token")
      refute_present(bytes, private_key(@session), "the ssh private key")
      refute_present(bytes, "local-token", "the GCP access token")
      refute_present(bytes, "sk-real", "an API key")
      refute_present(bytes, "sk-also", "an API key from :env")
    end

    test "the scrubbed handle survives term_to_binary and stays usable" do
      {config, _stub} = GcpReqStub.new(&never_called/1)

      round_tripped =
        handle(gce_config: config)
        |> Gce.scrub()
        |> :erlang.term_to_binary()
        |> :erlang.binary_to_term()

      assert round_tripped.instance_name == @instance
      # Enough to re-derive everything else: the token, the keypair, the name.
      assert round_tripped.session_key == @session
    end
  end

  describe "error normalization (blocker: a bearer token inside an error tuple)" do
    test "maps each failure onto one vocabulary" do
      assert {:error, {:gce, {:http_status, 403, "denied"}}} = get_error(403, "denied")
      assert {:error, {:gce, {:not_found, "gone"}}} = get_error(404, "gone")
    end

    test "a transport failure carries a message and not the credential" do
      {config, _stub} =
        GcpReqStub.new(fn {:get, _} -> %Req.TransportError{reason: :econnrefused} end)

      assert {:error, {:gce, {:transport, message}} = reason} =
               API.get_instance(config, @instance)

      assert is_binary(message)

      # The dep's %Error{} keeps the Req exception — whose request headers carry
      # the bearer token — in :body. Only messages may travel.
      refute_present(:erlang.term_to_binary(reason), "local-token", "the GCP access token")
    end

    test "a config that is not a config is refused before any call" do
      assert {:error, {:gce, {:bad_config, _}}} = API.config(gce_config: :nope)
    end
  end

  describe "config resolution (blocker: a reattach that cannot find its credentials)" do
    test "falls back to application env, which is the only reattach path" do
      # scrub/1 drops the token provider, so a node reattaching to a sandbox it
      # did not create has nowhere else to read it from.
      Application.put_env(:crowd_control, :gce, project: "from-env", zone: "europe-west4-a")
      on_exit(fn -> Application.delete_env(:crowd_control, :gce) end)

      assert {:ok, config} = API.config([])
      assert API.project(config) == "from-env"
      assert API.zone(config) == "europe-west4-a"

      # Explicit options still win over env.
      assert {:ok, overridden} = API.config(project: "from-opts")
      assert API.project(overridden) == "from-opts"
    end

    test "reports a missing project rather than inventing one" do
      assert {:error, {:gce, {:bad_config, _}}} = API.config(zone: "us-central1-a")
    end
  end

  # --- helpers ---

  defp acquire_opts(config, extra) do
    base = [
      session_key: @session,
      owner: "node-a",
      sandboxd_url: @url,
      sandboxd_sha256: @sha256,
      ready_timeout: 300
    ]

    base = if config, do: [{:gce_config, config} | base], else: base

    # Keyword.merge, so an `extra` of `sandboxd_url: nil` really removes the
    # option rather than being shadowed by the default.
    Keyword.merge(base, extra)
  end

  defp handle(config) do
    %Gce{
      project: "cc-test",
      zone: "us-central1-a",
      instance_name: @instance,
      session_key: @session,
      owner: "node-a",
      config: config
    }
  end

  defp tunnel_opts(vm) do
    [ssh_port: vm.ssh_port, agent_port: vm.agent_port, host_key_fp: vm.host_key_fp]
  end

  # Drives acquire far enough to have sent the insert body, then stops at "not
  # RUNNING": the spec is fully formed by then, and this needs no SSH.
  defp insert_body(extra \\ []) do
    {config, stub} =
      GcpReqStub.new(fn
        {:post, @instances} -> {200, GcpReqStub.operation()}
        {:get, @instance_path} -> {200, GcpReqStub.instance(@instance, status: "PROVISIONING")}
        {:delete, @instance_path} -> {200, GcpReqStub.operation()}
      end)

    assert {:error, {:gce, {:not_running, "PROVISIONING"}}} =
             Gce.acquire(acquire_opts(config, extra))

    [body | _rest] = GcpReqStub.bodies(stub)
    body
  end

  defp metadata(insert_body) do
    insert_body["metadata"]["items"] |> Map.new(&{&1["key"], &1["value"]})
  end

  defp render(extra \\ []) do
    assert {:ok, script} =
             Startup.render(Keyword.merge([sandboxd_url: @url, sandboxd_sha256: @sha256], extra))

    script
  end

  defp private_key(session_key) do
    {:ECPrivateKey, _version, private, _curve, _public, _other} = Tunnel.keypair(session_key)
    private
  end

  defp get_error(status, message) do
    {config, _stub} =
      GcpReqStub.new(fn {:get, _} -> {status, GcpReqStub.error(status, message)} end)

    API.get_instance(config, @instance)
  end

  defp running_vm({:post, @instances}), do: {200, GcpReqStub.operation()}

  defp running_vm({:get, @instance_path}),
    do: {200, GcpReqStub.instance(@instance, external_ip: "127.0.0.1")}

  # A rollback delete must be stubbed even in the happy-path router. Without it
  # an acquire/1 that fails for an unrelated reason raises "unstubbed GCP
  # Compute API call: {:delete, ...}" from inside its own cleanup, which hides
  # the actual failure behind the cleanup's.
  defp running_vm({:delete, @instance_path}), do: {200, GcpReqStub.operation()}

  defp live(name) do
    GcpReqStub.instance(name,
      labels: %{
        "crowd_control-session" => @session,
        "crowd_control-owner-hash" => Gce.owner_label("node-a"),
        "crowd_control-agent" => "sandboxd"
      },
      metadata: %{"cc-owner" => "node-a"}
    )
  end

  defp never_called(key), do: raise("no HTTP should have happened, but got: #{inspect(key)}")

  defp refute_present(bytes, secret, label) do
    assert :binary.match(bytes, secret) == :nomatch, "#{label} survived into the term"
  end

  defp non_loopback_address do
    {:ok, interfaces} = :inet.getifaddrs()

    Enum.find_value(interfaces, fn {_name, options} ->
      Enum.find_value(options, fn
        {:addr, {a, _b, _c, _d} = address} when a != 127 -> address
        _other -> nil
      end)
    end)
  end

  # A stand-in for one sandbox VM: OTP's own sshd with an in-memory host key,
  # authorizing this session's derived key, plus a listening stand-in for
  # sandboxd on the VM's "loopback".
  defp fake_vm(opts \\ []) do
    {:ok, _started} = Application.ensure_all_started(:ssh)

    {:ok, agent_port, agent} = GceFakeAgent.start(opts)
    on_exit(fn -> Process.exit(agent, :kill) end)

    dir = Path.join(System.tmp_dir!(), "cc-gce-ssh")
    File.mkdir_p!(dir)

    host_key = :public_key.generate_key({:namedCurve, :ed25519})
    authorized = @session |> Tunnel.keypair() |> :ssh_file.extract_public_key()

    {:ok, daemon} =
      :ssh.daemon(:loopback, 0, [
        {:key_cb, {GceFakeVmKeyCb, [host_key: host_key, auth_keys: [authorized]]}},
        {:system_dir, String.to_charlist(dir)},
        {:user_dir, String.to_charlist(dir)},
        {:auth_methods, ~c"publickey"},
        {:preferred_algorithms, [public_key: [:"ssh-ed25519"]]},
        # The server-side option is `tcpip_tunnel_in`; `tcpip_tunnel_to_server`
        # is only the client function's name.
        {:tcpip_tunnel_in, true},
        {:max_channels, 16}
      ])

    on_exit(fn -> :ssh.stop_daemon(daemon) end)

    {:ok, info} = :ssh.daemon_info(daemon)

    %{
      ssh_port: info[:port],
      agent_port: agent_port,
      host_key_fp:
        to_string(:ssh.hostkey_fingerprint(:sha256, :ssh_file.extract_public_key(host_key)))
    }
  end
end
