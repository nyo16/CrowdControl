defmodule CrowdControl.Provider.Gce do
  @moduledoc """
  One Google Compute Engine VM per sandbox, running `sandboxd`, reached through
  an SSH tunnel to the VM's loopback.

  Requires the optional `:gcp_compute` dependency and the OTP `:ssh`
  application. Nothing else: no `gcloud`, no IAP client, no agent on the host.

      CrowdControl.run("hello",
        backend:
          {CrowdControl.Backend.Sandboxd,
           provider:
             {CrowdControl.Provider.Gce,
              project: "my-project",
              zone: "us-central1-a",
              sandboxd_url: "https://.../sandboxd-linux-amd64.tar.gz",
              sandboxd_sha256: "…64 hex…"}}
      )

  ## Network posture, chosen rather than inherited

  `external_ip` defaults to `true`, and that is the *safe* default here only
  because of what surrounds it:

    * `sandboxd` binds `127.0.0.1` on the VM, so the agent is not on the
      network at all. It is reachable exclusively through the caller's SSH
      tunnel, whose local listener is bound to loopback on this node.
    * TCP 22 is therefore the only reachable port, authenticated by a
      per-session ed25519 key with `PasswordAuthentication` never in play.

  Two consequences to decide about deliberately rather than discover:

    * **The default VPC allows `0.0.0.0/0` on port 22.** On such a network the
      VM's sshd is internet-facing (publickey-only). Pass `:tags` and attach a
      firewall rule scoped to your egress addresses if that is not acceptable;
      the provider cannot do it for you, since it creates no firewall rules.
    * `external_ip: false` is the hardened mode: no public address at all. It
      requires same-VPC connectivity from the node that calls `acquire/1` —
      there is no pure-Elixir IAP tunnel client — and Cloud NAT (or a private
      artifact mirror), because the startup script fetches `apt` packages and
      the `sandboxd` release over the network.

  Note that `gcp_compute`'s own `:external_ip` default is also `true`, so this
  is stated rather than relied upon: a provider that forgot it would ship
  public sandbox VMs.

  ## A leaked spot VM bills forever

  This is the highest-stakes failure in the provider, so it is defended twice:

    * **Every** failure on the acquire path destroys the instance before
      returning, including a failed `instances.insert` — whose failure modes
      include an operation poll that timed out *after* the VM was created. The
      instance name is derived from the session key before the insert, so the
      rollback can always name the VM.
    * `scheduling.maxRunDuration` plus spot's `instanceTerminationAction: DELETE`
      is a **server-side** backstop that needs no BEAM. If this node dies
      mid-`acquire/1`, nothing local knows the VM exists and
      `CrowdControl.Reaper` never sees it; GCE deletes it anyway.

  `:max_run_duration` therefore has no "off": a caller who wants a long-lived
  sandbox passes a large number.

  ## `:ready_timeout`, measured

  Measured on a real spot `e2-small` in `us-central1-a`, no `:bootstrap_script`,
  release tarball in a same-region bucket:

  | phase | telemetry `:phase` | time |
  |---|---|---|
  | insert accepted, operation DONE | `:insert` | 8.9s |
  | RUNNING with an address | `:running` | 0.0s |
  | sshd accepts, authenticates, forwards | `:ssh` | 23.8s |
  | agent answers `GET /v1/health` | `:health` | 7.3s |
  | **`acquire/1` end to end** | | **39.9s** |

  `:ready_timeout` bounds the last three — it starts once the insert operation is
  DONE — so the measured requirement is **31.1s**. The default is `180_000`, about
  six times that, because the number this has to survive is not the one above: it
  is the same boot with a `:bootstrap_script` that installs a CLI. `:running`
  costing nothing is worth noticing — by the time the operation reports DONE the
  guest is already RUNNING with an address, so nearly all of the wait is the guest
  finishing its own boot, `apt-get`, and the release download.

  Raise it for a heavy bootstrap; lower it for a prebuilt image, where 60s is
  ample. Attach to `[:crowd_control, :gce, :phase]` and measure your own image
  rather than guessing — that is what the events are for. No behaviour in this
  module depends on the specific value, but `:max_run_duration`'s floor is derived
  from it, so an inflated `:ready_timeout` inflates the orphan backstop too.

  ## Telemetry

  `acquire/1` emits one event per phase, on success and on failure:

      [:crowd_control, :gce, :phase]
      measurements: %{duration_ms: non_neg_integer()}
      metadata:     %{phase: :insert | :running | :ssh | :health,
                      result: :ok | :error,
                      instance_name: String.t(),
                      zone: String.t()}

  A failing phase is emitted with `result: :error`, which is the one a caller
  most needs: "it timed out" is not actionable, "`:ssh` timed out after 180s"
  names the firewall rule.

  ## What is persisted, and what reattach needs

  The `Store` record keeps five fields — project, zone, instance name, owner,
  session key. `c:CrowdControl.Provider.scrub/1` drops everything else, because
  everything else is either a credential (`%GcpCompute.Config{}` holds a live
  token-provider argument; `:api_key`/`:env` may hold real keys) or a local pid.

  So a *different* node reattaching to a sandbox needs the client config from
  configuration rather than from the record:

      config :crowd_control,
        gce: [project: "my-project", zone: "us-central1-a"]

  Anything else `reconnect/1` reads from options — `:agent_port`,
  `:ready_timeout`, `:ssh_port` — belongs in the same place if it is not the
  default. `CrowdControl.Reaper`'s own reattach path is unaffected: it passes
  the handles `list_live/1` returned, which carry the options it was called
  with.

  The tunnel's keypair is not persisted either, and does not need to be: it is
  derived from the session key on every connect. See
  `CrowdControl.Provider.Gce.Tunnel`.

  ## Labels reject `.`, so the Docker keys cannot be reused

  GCE label keys and values allow only lowercase letters, digits, `-` and `_`.
  `crowd_control.session` is therefore illegal, and so is a raw owner like
  `nonode@nohost`. This provider uses `crowd_control-session`,
  `crowd_control-owner-hash` (a sha256 prefix, exactly the trick
  `CrowdControl.Backend.Kubernetes` uses for the same reason) and
  `crowd_control-agent`, and puts the **raw** owner in instance metadata, where
  values are unconstrained. `CrowdControl.Reaper` re-checks the raw owner
  exactly before destroying anything, so both gates stay honest.

  ## Options

  Client:

    * `:project`, `:zone`, `:token_provider` — see
      `GcpCompute.Config.new/1`; or pass a ready `%GcpCompute.Config{}` as
      `:gce_config`. Application env under `:gce` fills in the rest.

  Agent image (required — see `CrowdControl.Provider.Gce.Startup`):

    * `:sandboxd_url` — release tarball URL
    * `:sandboxd_sha256` — its SHA-256; mandatory, never skipped
    * `:bootstrap_script` — shell run as root before the agent is installed

  Instance shape, all passed through to `GcpCompute.Instance.spec/1`:

    * `:machine_type`, `:source_image`, `:disk_size_gb`, `:network`,
      `:subnetwork`, `:tags`, `:service_account`, `:scopes`
    * `:spot` — default `true`
    * `:external_ip` — default `true`; see above
    * `:max_run_duration` — seconds, and there is no "off": a caller who wants
      a long-lived sandbox passes a large number. Defaults to
      `:ready_timeout` + the session's own `:timeout` + 5 minutes, and an
      explicit value below `:ready_timeout` + 5 minutes is refused — a deadline
      that can expire while `acquire/1` is still waiting deletes live work and
      reports it as a failed bootstrap.
    * `:metadata` — extra instance metadata. This provider's own keys are
      merged **over** it: a caller-supplied `ssh-keys` would lock the tunnel
      out of its own sandbox.

  Timing and transport:

    * `:ready_timeout` — operation DONE → healthy agent, default `180_000`;
      measured requirement is 31s for a sandbox with no bootstrap script
    * `:insert_timeout`, `:delete_timeout` — operation polls, default `300_000`
    * `:agent_port` — default `8080`, `:capture_path` — default
      `/var/log/cc/out.jsonl`
    * `:ssh_port` — default `22`
    * `:host_key_fp` — pin the VM's host key; see
      `CrowdControl.Provider.Gce.Tunnel` for why nothing supplies it by default
    * `:req_adapter` — test seam, threaded into the agent endpoint's `Req`
      options. The GCP client's own seam is `:req_options` inside the config.

  No service account is attached unless `:service_account` is set, and that is
  deliberate: with one, the sandboxed CLI can mint project credentials from the
  metadata server with the granted scopes.
  """

  @behaviour CrowdControl.Provider

  # `:telemetry` is not a dependency of this library. It arrives transitively
  # with `:gcp_compute` (req -> finch -> telemetry), which every caller who can
  # reach `phase/3` necessarily has, so the emit is safe where it runs. Without
  # that optional dep the module still compiles, and this keeps it from warning
  # in projects that never touch the GCE provider.
  @compile {:no_warn_undefined, :telemetry}

  require Logger

  alias CrowdControl.Backend.Sandboxd.API, as: AgentAPI
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Endpoint
  alias CrowdControl.Provider.Gce.API
  alias CrowdControl.Provider.Gce.Startup
  alias CrowdControl.Provider.Gce.Tunnel
  alias CrowdControl.ReqAdapter
  alias CrowdControl.Store

  @session_label "crowd_control-session"
  @owner_label "crowd_control-owner-hash"
  @agent_label "crowd_control-agent"
  @agent_value "sandboxd"

  @owner_metadata_key "cc-owner"

  @default_agent_port 8080
  # ~6x the measured 31.1s, sized for a bootstrap script that installs a CLI
  # rather than for the bare case. See the moduledoc's measurement table.
  @default_ready_timeout 180_000
  @default_operation_timeout 300_000

  @status_poll_interval 2_000

  # The server-side deadline has to outlast the two things that legitimately
  # keep a sandbox alive -- the readiness window and the session's own run
  # budget -- plus enough slack to tear down. A shorter one deletes live work.
  @teardown_headroom 300
  # CrowdControl.Session's own default :timeout, in seconds.
  @default_session_ttl 300

  # Everything the caller may shape about the VM itself. Deliberately a
  # whitelist: forwarding the whole option list would hand
  # GcpCompute.Instance.spec/1 keys it validates against, and a typo in an
  # unrelated session option would become a spec error.
  @spec_passthrough [
    :machine_type,
    :source_image,
    :disk_size_gb,
    :network,
    :subnetwork,
    :tags,
    :service_account,
    :scopes
  ]

  @rfc1035 ~r/^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$/

  defstruct [
    :project,
    :zone,
    :instance_name,
    :session_key,
    :owner,
    :tunnel,
    config: []
  ]

  @type t :: %__MODULE__{
          project: String.t() | nil,
          zone: String.t() | nil,
          instance_name: String.t() | nil,
          session_key: String.t() | nil,
          owner: String.t() | nil,
          tunnel: pid() | nil,
          config: keyword()
        }

  # --- acquire ---

  @impl true
  def acquire(opts) do
    with :ok <- API.ensure_gcp_compute!(),
         {:ok, session_key} <- fetch_session_key(opts),
         {:ok, name} <- instance_name(session_key),
         {:ok, config} <- API.config(opts),
         handle = handle(opts, session_key, name, config),
         {:ok, spec} <- instance_spec(handle) do
      start(handle, config, spec)
    end
  end

  defp handle(opts, session_key, name, config) do
    %__MODULE__{
      project: API.project(config),
      zone: API.zone(config),
      instance_name: name,
      session_key: session_key,
      owner: opts[:owner] || Store.owner_id(),
      config: opts
    }
  end

  # Deliberately not one `with` chain with an `else`, for the same reason
  # CrowdControl.Provider.Docker.start/2 is not: an `else` branch cannot see
  # rebindings made in the body, so the handle there would still carry
  # `tunnel: nil` and the rollback would leave an authenticated SSH connection
  # holding a local listener open. Each step hands the *updated* handle to the
  # next, and rollback is called from the scope that knows what exists.
  defp start(handle, config, spec) do
    case phase(handle, :insert, fn ->
           API.insert_and_wait(config, spec, timeout: insert_timeout(handle), zone: handle.zone)
         end) do
      {:ok, instance} ->
        await_running(handle, config, instance)

      # Rolled back even though the insert reported failure: `insert_and_wait`
      # also fails when the *operation poll* timed out, and that happens with a
      # VM already created and billing. A delete of something that never
      # existed is a 404, i.e. success, so this is safe on every insert failure
      # — worth one extra API call on a path that is already failing.
      {:error, reason} ->
        rollback(handle, config, reason)
    end
  end

  defp await_running(handle, config, instance) do
    deadline = System.monotonic_time(:millisecond) + ready_timeout(handle)

    case phase(handle, :running, fn -> poll_host(handle, config, instance, deadline) end) do
      {:ok, host} -> open_tunnel(handle, config, host, deadline)
      {:error, reason} -> rollback(handle, config, reason)
    end
  end

  # `insert_and_wait` returns when the *operation* is DONE, which is before the
  # guest has finished booting and can be before an address is assigned.
  defp poll_host(handle, config, instance, deadline) do
    case host(handle, instance) do
      {:ok, host} ->
        {:ok, host}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) + @status_poll_interval < deadline do
          Process.sleep(@status_poll_interval)
          refresh_and_poll(handle, config, deadline)
        else
          {:error, reason}
        end
    end
  end

  defp refresh_and_poll(handle, config, deadline) do
    case API.get_instance(config, handle.instance_name, zone: handle.zone) do
      {:ok, refreshed} -> poll_host(handle, config, refreshed, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  defp host(handle, %{status: "RUNNING"} = instance) do
    case address(handle, instance) do
      nil -> {:error, {:gce, {:no_address, external_ip?(handle.config)}}}
      address -> {:ok, address}
    end
  end

  defp host(_handle, %{status: status}), do: {:error, {:gce, {:not_running, status}}}

  # With no external address the tunnel targets the VM's internal IP, which
  # only resolves into a route from inside the same VPC. That is the whole cost
  # of the hardened mode.
  defp address(handle, instance) do
    if external_ip?(handle.config), do: instance.external_ip, else: instance.internal_ip
  end

  defp open_tunnel(handle, config, host, deadline) do
    case phase(handle, :ssh, fn ->
           Tunnel.open(host, handle.session_key, tunnel_opts(handle, deadline))
         end) do
      {:ok, local_port, conn} ->
        verify_health(%{handle | tunnel: conn}, config, local_port, deadline)

      {:error, reason} ->
        rollback(handle, config, reason)
    end
  end

  # Four telemetry events, because `acquire/1` is minutes long and was opaque.
  #
  # `:ready_timeout`'s documentation asks the caller to raise it for a heavy
  # bootstrap and lower it for a prebuilt image — advice they could only follow by
  # guessing, since nothing reported where the minutes actually went. The phases
  # are the four questions worth asking separately:
  #
  #   * `:insert` — the API accepted it and the operation reached DONE
  #   * `:running` — the guest is RUNNING and has an address
  #   * `:ssh`     — sshd accepts, authenticates, and forwards a port
  #   * `:health`  — the agent answers `GET /v1/health`, which is the only real
  #                  readiness signal and the one that contains `apt-get`, the
  #                  caller's bootstrap and the release download
  #
  # Emitted on failure too, with `result: :error` — a phase that timed out is
  # exactly the one a caller needs to see.
  #
  #     :telemetry.attach("gce", [:crowd_control, :gce, :phase], &handler/4, nil)
  defp phase(handle, name, fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    duration = System.monotonic_time(:millisecond) - started

    :telemetry.execute(
      [:crowd_control, :gce, :phase],
      %{duration_ms: duration},
      %{
        phase: name,
        result: if(match?({:error, _}, result), do: :error, else: :ok),
        instance_name: handle.instance_name,
        zone: handle.zone
      }
    )

    result
  end

  # `{:ok, port}` from the tunnel is not evidence the agent is reachable — the
  # remote end is never probed at setup time — so this is the only readiness
  # signal in the whole provider.
  defp verify_health(handle, config, local_port, deadline) do
    endpoint = endpoint(handle, local_port)

    case phase(handle, :health, fn -> AgentAPI.await_health(endpoint, remaining(deadline)) end) do
      :ok -> {:ok, handle, endpoint}
      {:error, reason} -> rollback(handle, config, health_reason(handle, reason))
    end
  end

  # Every agent transport failure reads as `:socket_closed_remotely`, whether
  # the agent is not listening yet, forwarding was denied, the SSH connection
  # dropped, or the VM is gone. The connection ref is the only thing that can
  # tell those apart, so a dead one replaces the (correct but useless) HTTP
  # reason.
  defp health_reason(handle, reason) do
    if Tunnel.alive?(handle.tunnel), do: reason, else: {:gce, {:tunnel, :connection_lost}}
  end

  defp rollback(handle, config, reason) do
    _ = destroy(handle, config)
    {:error, reason}
  end

  # --- spec ---

  defp instance_spec(handle) do
    with {:ok, startup_script} <- Startup.render(handle.config),
         {:ok, max_run_duration} <- max_run_duration(handle.config) do
      handle.config
      |> Keyword.take(@spec_passthrough)
      |> Keyword.merge(
        name: handle.instance_name,
        zone: handle.zone,
        spot: Keyword.get(handle.config, :spot, true),
        external_ip: external_ip?(handle.config),
        max_run_duration: max_run_duration,
        startup_script: startup_script,
        metadata: metadata(handle),
        labels: labels(handle)
      )
      |> API.instance_spec()
    end
  end

  defp metadata(handle) do
    caller = stringify(handle.config[:metadata] || %{})

    # Ours merged over the caller's, never under it.
    Map.merge(caller, %{
      "ssh-keys" => Tunnel.metadata_ssh_keys(handle.session_key),
      # Both are load-bearing rather than tidy. The guest agent ignores
      # metadata `ssh-keys` **entirely** when OS Login is enabled, and appends
      # every project-wide key unless project keys are blocked — so without
      # these two the tunnel's reachability and the sandbox's exposure would
      # both be decided by whatever the project happens to default to.
      "enable-oslogin" => "FALSE",
      "block-project-ssh-keys" => "true",
      # The agent's bearer token. Metadata, not the script body: the script is
      # readable by every project viewer, and this way the token exists only in
      # the agent process's environment. See Startup's moduledoc.
      Startup.token_metadata_key() => Provider.token(handle.session_key),
      @owner_metadata_key => handle.owner
    })
  end

  defp labels(handle) do
    %{
      @session_label => handle.session_key,
      @owner_label => owner_label(handle.owner),
      @agent_label => @agent_value
    }
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  @doc false
  # `Store.owner_id/0` defaults to `to_string(node())` = "nonode@nohost", and
  # `@` is not a legal GCE label value. Sanitizing would be lossy, and two
  # owners collapsing to one label would let one node's reaper destroy
  # another's VMs -- so the label is a hash used purely as a server-side
  # selector, and the raw owner round-trips through metadata, where values are
  # unconstrained.
  @spec owner_label(String.t() | nil) :: String.t()
  def owner_label(owner) do
    :sha256
    |> :crypto.hash(to_string(owner))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc false
  # Deterministic from the session key, so that a crashed run's VM is found and
  # deleted rather than orphaned under a random name, and so that the rollback
  # path can name a VM whose insert never reported back. It also makes a
  # duplicate acquire a 409 rather than two live, billed instances.
  @spec instance_name(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def instance_name(session_key) when is_binary(session_key) do
    name = "cc-sbx-" <> session_key

    if Regex.match?(@rfc1035, name) do
      {:ok, name}
    else
      {:error, {:gce, {:invalid_name, session_key}}}
    end
  end

  def instance_name(session_key), do: {:error, {:gce, {:invalid_name, session_key}}}

  # The server-side orphan backstop, derived rather than fixed: it must outlast
  # the readiness window plus the session's own run budget, or it would delete
  # a VM that is still doing what it was created for -- and an expiry during
  # acquire/1 looks exactly like a bootstrap that failed. An explicit value
  # below that minimum is refused for the same reason.
  defp max_run_duration(opts) do
    minimum = div(ready_timeout_ms(opts), 1000) + @teardown_headroom

    case opts[:max_run_duration] do
      nil ->
        {:ok, minimum + session_ttl(opts)}

      seconds when is_integer(seconds) and seconds >= minimum ->
        {:ok, seconds}

      other ->
        {:error, {:gce, {:bad_max_run_duration, other}}}
    end
  end

  defp session_ttl(opts) do
    case opts[:timeout] do
      ms when is_integer(ms) and ms > 0 -> div(ms, 1000)
      _ -> @default_session_ttl
    end
  end

  # --- reconnect ---

  @impl true
  def reconnect(%__MODULE__{instance_name: nil}), do: {:error, {:gce, :not_provisioned}}

  def reconnect(%__MODULE__{} = handle) do
    # An existing connection is closed first, not reused: `:ssh` has no API to
    # remove a single forward listener, so a second tunnel on the same
    # connection would leave the first listener accepting connections forever.
    Tunnel.close(handle.tunnel)
    handle = %{handle | tunnel: nil}

    with {:ok, config} <- API.config(handle.config),
         {:ok, instance} <- API.get_instance(config, handle.instance_name, zone: handle.zone),
         {:ok, host} <- host(handle, instance),
         deadline = System.monotonic_time(:millisecond) + ready_timeout(handle),
         {:ok, local_port, conn} <-
           Tunnel.open(host, handle.session_key, tunnel_opts(handle, deadline)) do
      reconnected = %{handle | tunnel: conn}
      endpoint = endpoint(reconnected, local_port)

      # Never a rollback: a sandbox this node cannot reattach to is still a live
      # sandbox, and destroying it here would turn a transient tunnel failure
      # into lost work. Reaping is CrowdControl.Reaper's decision.
      case AgentAPI.await_health(endpoint, remaining(deadline)) do
        :ok ->
          {:ok, reconnected, endpoint}

        {:error, reason} ->
          Tunnel.close(conn)
          {:error, health_reason(reconnected, reason)}
      end
    end
  end

  defp endpoint(handle, local_port) do
    %Endpoint{
      base_url: "http://127.0.0.1:#{local_port}",
      token: Provider.token(handle.session_key),
      req_options: ReqAdapter.req_options(handle.config[:req_adapter]),
      # The tunnel's lifetime is the endpoint's, which is what makes it the
      # endpoint's business and never the persisted handle's.
      transport: handle.tunnel
    }
  end

  defp tunnel_opts(handle, deadline) do
    [
      deadline: deadline,
      agent_port: handle.config[:agent_port] || @default_agent_port,
      ssh_port: handle.config[:ssh_port],
      host_key_fp: handle.config[:host_key_fp]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # --- release ---

  @impl true
  def release(%__MODULE__{instance_name: nil} = handle) do
    Tunnel.close(handle.tunnel)
    :ok
  end

  def release(%__MODULE__{} = handle) do
    case API.config(handle.config) do
      {:ok, config} ->
        destroy(handle, config)

      {:error, reason} ->
        # Teardown cannot fail loudly: CrowdControl.Session calls release/1 from
        # several paths that must all complete. A VM that outlives us is bounded
        # by maxRunDuration rather than permanent, which is exactly what that
        # backstop is for.
        Tunnel.close(handle.tunnel)

        Logger.warning("sandboxd GCE release could not build a client config: #{inspect(reason)}")

        :ok
    end
  end

  # The tunnel first: closing it after the delete would leave a local listener
  # accepting connections to a VM that no longer exists, and every one of those
  # would fail as a transport error rather than as "gone".
  defp destroy(handle, config) do
    Tunnel.close(handle.tunnel)

    case API.delete_and_wait(config, handle.instance_name,
           zone: handle.zone,
           timeout: delete_timeout(handle)
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "sandboxd GCE instance destroy failed for #{handle.instance_name}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # --- list_live / age_ms / scrub ---

  @impl true
  def list_live(opts) do
    owner = opts[:owner] || Store.owner_id()

    with {:ok, config} <- API.config(opts) do
      filter = ~s(labels.#{@owner_label} = "#{owner_label(owner)}")

      case API.list_all(config, filter, zone: API.zone(config)) do
        {:ok, instances} ->
          {:ok,
           instances
           |> Enum.filter(&(&1.labels[@agent_label] == @agent_value))
           |> Enum.map(&handle_from_instance(&1, opts, config, owner))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The owner filter is server-side because it is what bounds the number of
  # pages; the agent label is filtered here instead. A compound `AND` filter
  # expression is the kind of thing that either works or makes every sweep
  # return an API error — and an erroring list_live/1 blinds the reaper
  # completely, while a locally-filtered one cannot.
  defp handle_from_instance(instance, opts, config, owner) do
    %__MODULE__{
      project: API.project(config),
      zone: API.zone(config),
      instance_name: instance.name,
      session_key: instance.labels[@session_label],
      # Raw, out of metadata: the label is only a hash, and
      # CrowdControl.Reaper compares raw owners exactly before destroying
      # anything.
      owner: instance.metadata[@owner_metadata_key] || owner,
      config: opts
    }
  end

  @impl true
  def age_ms(%__MODULE__{instance_name: nil}), do: nil

  def age_ms(%__MODULE__{} = handle) do
    with {:ok, config} <- API.config(handle.config),
         {:ok, %{created_at: %DateTime{} = created_at}} <-
           API.get_instance(config, handle.instance_name, zone: handle.zone) do
      max(DateTime.diff(DateTime.utc_now(), created_at, :millisecond), 0)
    else
      # Unknown age, not zero: the reaper reads nil as "assume young", and
      # guessing zero would make it destroy a VM it could not date.
      _ -> nil
    end
  end

  @impl true
  def scrub(%__MODULE__{} = handle) do
    # Rebuilt from five fields rather than edited: `config` can carry
    # `:api_key`, `:env`, and a `%GcpCompute.Config{}` whose token provider is
    # a live credential, so a future option would leak by omission. `:tunnel`
    # is a local pid, meaningless in a record that outlives the node.
    %__MODULE__{
      project: handle.project,
      zone: handle.zone,
      instance_name: handle.instance_name,
      session_key: handle.session_key,
      owner: handle.owner
    }
  end

  # --- private ---

  defp fetch_session_key(opts) do
    case opts[:session_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:gce, :session_key_required}}
    end
  end

  defp external_ip?(config), do: Keyword.get(config, :external_ip, true)

  defp ready_timeout(handle), do: ready_timeout_ms(handle.config)
  defp ready_timeout_ms(opts), do: opts[:ready_timeout] || @default_ready_timeout
  defp insert_timeout(handle), do: handle.config[:insert_timeout] || @default_operation_timeout
  defp delete_timeout(handle), do: handle.config[:delete_timeout] || @default_operation_timeout

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
