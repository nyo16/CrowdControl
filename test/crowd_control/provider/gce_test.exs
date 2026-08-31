defmodule CrowdControl.Provider.GceTest do
  @moduledoc """
  Integration tests against a **real, billed** GCP project. Excluded by default
  (see `test/test_helper.exs`); nothing here runs unless you ask for it:

      REL=https://github.com/nyo16/CrowdControl/releases/download/sandboxd-v0.1.0

      CC_GCE_PROJECT=my-project \\
      CC_GCE_ZONE=us-central1-a \\
      CC_GCE_ACCESS_TOKEN="$(gcloud auth print-access-token)" \\
      CC_GCE_SANDBOXD_URL=$REL/sandboxd-linux-amd64.tar.gz \\
      CC_GCE_SANDBOXD_SHA256="$(curl -fsSL $REL/sandboxd-linux-amd64.tar.gz.sha256 | cut -d' ' -f1)" \\
      mix test --include gce test/crowd_control/provider/gce_test.exs

  The agent tarball has its own release channel, `sandboxd-v*`, so it can be
  published without publishing the Hex package — see `.github/workflows/ci.yml`.
  Any URL the VM can reach over plain HTTPS works; a GCS object or your own
  mirror is fine, and the checksum is what makes the source untrusted.

  Optional: `CC_GCE_MACHINE_TYPE` (default `e2-small`), `CC_GCE_SUBNETWORK`,
  `CC_GCE_TAGS` (comma-separated, for your own firewall rule).

  ## Credentials

  A **static access token**, deliberately, not Goth: `goth` is an optional
  dependency *of* `gcp_compute` and is not in this project's `mix.lock`, so it
  is not available here. `gcloud auth print-access-token` mints one that lives
  about an hour — long enough for a run, and short enough that leaking it into
  a CI log is a bounded incident rather than a key rotation.

  ## Required IAM

  The token's principal needs, in the target project:

    * `compute.instances.create`, `compute.instances.delete`,
      `compute.instances.get`, `compute.instances.list`
    * `compute.disks.create` (the boot disk)
    * `compute.subnetworks.use` and `compute.subnetworks.useExternalIp`
      (the latter only while `external_ip: true`, which is the default)
    * `compute.zoneOperations.get` and `compute.zoneOperations.wait`

  `roles/compute.instanceAdmin.v1` covers all of them. No
  `roles/iam.serviceAccountUser` is needed, because this provider attaches no
  service account — if you add `:service_account`, you will need it, and the
  sandboxed CLI will be able to mint project credentials from the metadata
  server.

  ## Network

  The VM's sshd must be reachable from this machine on TCP 22. The default VPC's
  `default-allow-ssh` rule permits `0.0.0.0/0`, which is why
  `CrowdControl.Provider.Gce`'s moduledoc tells you to scope your own rule with
  `:tags` instead. The VM also needs outbound internet (or Cloud NAT plus a
  private mirror) for `apt-get` and the release download.

  ## Cost

  Spot `e2-small` VMs, deleted in `on_exit` and backstopped by
  `scheduling.maxRunDuration` so that a crashed test run still cannot leak one.
  Two VMs per run: one healthy sandbox, and one deliberately-broken bootstrap
  that must leave nothing behind.
  """

  # Needs a live GCP project, credentials, and several minutes of boot time.
  use ExUnit.Case, async: false

  alias CrowdControl.Backend.Sandboxd.API, as: AgentAPI
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Gce
  alias CrowdControl.Provider.Gce.API
  alias CrowdControl.Provider.Gce.Tunnel
  alias CrowdControl.Store

  @moduletag :gce

  # A cold Debian boot plus apt-get plus a release download is minutes, not
  # seconds, and ExUnit's default 60s timeout would fail the test rather than
  # the provider.
  @moduletag timeout: 900_000

  setup_all do
    # Any stable value works; the secret only has to outlive this run, and
    # generating it keeps a real one out of the environment.
    Application.put_env(
      :crowd_control,
      :sandboxd_secret,
      32 |> :crypto.strong_rand_bytes() |> Base.encode64()
    )

    on_exit(fn -> Application.delete_env(:crowd_control, :sandboxd_secret) end)

    {:ok, base: base_opts()}
  end

  # One test for the whole lifecycle, on purpose. The resource is billed and the
  # teardown must be guaranteed, so ExUnit's random intra-module test order is a
  # hazard rather than a feature here: a `release/1` test running first would
  # destroy the VM the others need.
  test "acquire, health, exec, reconnect, list_live, age, release", %{base: base} do
    session_key = Store.new_key()
    owner = "cc-gce-test-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
    opts = base ++ [session_key: session_key, owner: owner]

    {:ok, config} = API.config(opts)
    on_exit(fn -> force_delete(config, session_key) end)

    # --- acquire: returns only once GET /v1/health answered through the tunnel
    assert {:ok, handle, endpoint} = Gce.acquire(opts)

    assert handle.instance_name == "cc-sbx-" <> session_key
    assert handle.owner == owner
    assert endpoint.base_url =~ ~r{^http://127\.0\.0\.1:\d+$}
    assert is_pid(endpoint.transport)
    assert AgentAPI.health(endpoint) == :ok

    # --- the sandbox really executes things
    assert :ok = AgentAPI.exec(endpoint, "/bin/echo", ["hello from the sandbox"], %{})
    assert {:ok, %{alive: false, exit_status: 0, bytes: bytes}} = await_exit(endpoint)
    assert bytes > 0

    # --- age, for the reaper's grace window
    age = Gce.age_ms(handle)
    assert is_integer(age) and age > 0

    # --- list_live sees it, scoped to this owner
    assert {:ok, live} = Gce.list_live(opts)
    assert Enum.any?(live, &(&1.instance_name == handle.instance_name))
    assert Enum.all?(live, &(&1.owner == owner))

    # A different owner must not see it: the label is a hash of the owner, and
    # the reaper's whole safety property rests on that filter.
    assert {:ok, others} = Gce.list_live(Keyword.put(opts, :owner, owner <> "-other"))
    refute Enum.any?(others, &(&1.instance_name == handle.instance_name))

    # --- reconnect from a *persisted* handle: five fields, no credentials
    scrubbed = Gce.scrub(handle)
    refute_present(:erlang.term_to_binary(scrubbed), Provider.token(session_key), "the token")

    Tunnel.close(endpoint.transport)

    assert {:ok, reconnected, second} =
             Gce.reconnect(%{scrubbed | config: opts})

    assert second.base_url != endpoint.base_url
    assert AgentAPI.health(second) == :ok

    # --- release: idempotent, and the VM is really gone afterwards
    assert :ok = Gce.release(reconnected)
    assert :ok = Gce.release(reconnected)

    assert {:error, {:gce, {:not_found, _}}} =
             API.get_instance(config, handle.instance_name, zone: handle.zone)
  end

  test "a bootstrap that fails leaves no instance behind", %{base: base} do
    # The highest-stakes path in the provider: a leaked spot VM bills until
    # someone notices it. `set -e` in the startup script means a failing
    # bootstrap never installs the agent, so health never answers.
    session_key = Store.new_key()

    opts =
      base ++
        [
          session_key: session_key,
          owner: "cc-gce-test-rollback",
          bootstrap_script: "exit 1",
          ready_timeout: 180_000
        ]

    {:ok, config} = API.config(opts)
    on_exit(fn -> force_delete(config, session_key) end)

    assert {:error, reason} = Gce.acquire(opts)
    # Either the agent never came up, or the tunnel never authenticated —
    # both are legitimate here, and both must still delete the VM.
    assert match?({:sandboxd, _}, reason) or match?({:gce, {:tunnel, _}}, reason)

    assert {:error, {:gce, {:not_found, _}}} =
             API.get_instance(config, "cc-sbx-" <> session_key, zone: API.zone(config))
  end

  test "release/1 is idempotent for an instance that never existed", %{base: base} do
    session_key = Store.new_key()

    handle = %Gce{
      project: env!("CC_GCE_PROJECT"),
      zone: zone(),
      instance_name: "cc-sbx-" <> session_key,
      session_key: session_key,
      owner: "cc-gce-test-missing",
      config: base
    }

    assert :ok = Gce.release(handle)
    assert :ok = Gce.release(handle)
  end

  # --- helpers ---

  defp base_opts do
    [
      project: env!("CC_GCE_PROJECT"),
      zone: zone(),
      token_provider: {GcpCompute.TokenProvider.Static, env!("CC_GCE_ACCESS_TOKEN")},
      sandboxd_url: env!("CC_GCE_SANDBOXD_URL"),
      sandboxd_sha256: env!("CC_GCE_SANDBOXD_SHA256"),
      machine_type: System.get_env("CC_GCE_MACHINE_TYPE", "e2-small"),
      # Measured: 31s is the real requirement for this exact shape (no bootstrap
      # script, tarball in a same-region bucket), and 39.9s end to end. Kept well
      # above that rather than at the default, because a spot VM can be scheduled
      # onto a busy host and this suite failing for that reason would be noise.
      ready_timeout: 240_000
    ]
    |> put_env_opt(:subnetwork, "CC_GCE_SUBNETWORK")
    |> put_tags()
  end

  defp zone, do: System.get_env("CC_GCE_ZONE", "us-central1-a")

  defp put_env_opt(opts, key, variable) do
    case System.get_env(variable) do
      nil -> opts
      value -> Keyword.put(opts, key, value)
    end
  end

  defp put_tags(opts) do
    case System.get_env("CC_GCE_TAGS") do
      nil -> opts
      tags -> Keyword.put(opts, :tags, String.split(tags, ",", trim: true))
    end
  end

  defp env!(variable) do
    System.get_env(variable) ||
      raise """
      #{variable} is required by test/crowd_control/provider/gce_test.exs.

      See this file's moduledoc for the full invocation and the IAM roles the
      token needs.
      """
  end

  defp await_exit(endpoint, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 60_000

    case AgentAPI.status(endpoint, 5_000) do
      {:ok, %{alive: false, started: true}} = done ->
        done

      {:ok, _still_running} ->
        if System.monotonic_time(:millisecond) < deadline do
          await_exit(endpoint, deadline)
        else
          flunk("the sandbox CLI never exited")
        end

      {:error, reason} ->
        flunk("GET /v1/status failed: #{inspect(reason)}")
    end
  end

  # Belt and braces: release/1 is what the library does, this is what makes a
  # failed assertion mid-test still not leave a billed VM running.
  defp force_delete(config, session_key) do
    API.delete_and_wait(config, "cc-sbx-" <> session_key, zone: API.zone(config))
  end

  defp refute_present(bytes, secret, label) do
    assert :binary.match(bytes, secret) == :nomatch, "#{label} survived into the term"
  end
end
