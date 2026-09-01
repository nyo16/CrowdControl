defmodule CrowdControl.Provider.Compose do
  @moduledoc """
  A per-session Docker *stack* — sandbox plus sidecars — over the Engine API.

  Same job as `CrowdControl.Provider.Docker`, one container more, and one
  property that provider provably cannot have: a **structural** egress block on
  the sandbox that still leaves the agent reachable from the host.

  There is no `docker compose` dependency and there must never be one. The
  Engine API has no compose endpoints — compose is a client-side Go plugin that
  synthesises exactly the calls below — so shelling out would buy a binary
  dependency, a YAML round trip and a second error vocabulary in exchange for
  nothing.

  ## The network shape, and why it needs two containers

  The measured constraint, confirmed six independent ways against a live
  daemon:

  > On one container, `Internal: true` and a published port are mutually
  > exclusive. Publishing requires at least one *non-internal* endpoint, and
  > attaching one restores full internet egress.

  So the sandbox and the thing the host talks to cannot be the same container:

    1. **`<project>-sbx`** — `Internal: true`. The sandbox sits here and *only*
       here. This is the one strong egress primitive: no default route exists at
       all, so the internet, the Docker host, containers on every other Docker
       network and Docker's own embedded DNS are unreachable structurally
       rather than by a missing NAT rule.
    2. **`<project>-pub`** — non-internal, so `PortBindings` actually bind, but
       with `com.docker.network.bridge.enable_ip_masquerade=false` so the one
       container attached to it has no internet either.
    3. **`<project>-egress`** — a plain NAT bridge, created **only** if some
       sidecar declares `egress: :allow`. If nothing asks, it never exists.

  A **forwarder** sidecar is dual-homed on 1 and 2 and publishes the agent port
  on `127.0.0.1:0`. It runs
  `socat TCP-LISTEN:<port>,fork,reuseaddr TCP:<sandbox>:<port>`, addressing the
  sandbox by its network alias. `fork` is not decorative: a single-slot
  forwarder (`busybox nc -e`) dropped two of three concurrent requests in
  testing, and `CrowdControl.Backend.Sandboxd` holds a long-lived chunked
  stream open for the whole session.

  The forwarder's second network is attached with
  `POST /networks/{id}/connect` after create, not by listing two endpoints in
  `POST /containers/create`: create-time dual attach is `HTTP 400` below API
  1.44, and daemons still report `MinAPIVersion` 1.40. The connect-after-create
  path is verified to produce an identical container.

  ## Options

  Stack:

    * `:services` — sidecar specs, each a map (see below). Default `[]`.
    * `:sandbox_service` — the name the sandbox container is given, default
      `"sandbox"`. A spec in `:services` with this name *is* the sandbox: it
      supplies the image, command, env and mounts, and the provider overlays
      the agent contract on it. With no such spec the sandbox is synthesised
      from `:image` alone.
    * `:forwarder_service` — the name the forwarder is given, default
      `"forwarder"`. Always synthesised; see `:forwarder_image`.
    * `:forwarder_image` — default `"alpine/socat:1.8.1.3"`. Any image with
      `socat` on `PATH` works; the provider sets `Entrypoint` itself.
    * `:network` — `[internal: true, driver: "bridge", options: %{}]`. See the
      warning below.
    * `:volumes` — named volume *declarations*, `[%{name: "workspace"}]`.
      Created as `<project>-<name>` and destroyed with the stack. Note this is
      a declaration list, not a mount list: a service mounts one by naming it
      in its own `:volumes`, and only Compose creates the storage it mounts —
      Docker and Kubernetes expect it to exist already.
    * `:ready` — per-service healthchecks, `%{"db" => %{test: [...]}}`.
    * `:project_name` — default `"cc-<session_key>"`.
    * `:proxy_service` — the sidecar fronting the egress proxy. See below.
    * `:health_timeout` — deadline for the healthcheck poll, default `60_000`.

  Agent, exactly as `CrowdControl.Provider.Docker` takes them: `:image`,
  `:agent_port`, `:capture_path`, `:ready_timeout`, `:req_adapter`,
  `:docker_host`, `:timeout`.

  Hardening (`:cpus`, `:memory`, `:cap_drop`, `:security_opt`, `:pids_limit`,
  `:user`, `:readonly_rootfs`, `:tmpfs`) comes from these top-level options and
  applies to **every** container in the stack, through
  `CrowdControl.Backend.Docker.HostConfig`. There are deliberately no
  per-service overrides: one posture per stack is the whole reason that module
  exists, and a sidecar quietly weaker than the sandbox it shares a network
  with is not a useful thing to be able to express.

  ### Service spec

      %{
        name: "proxy",                      # required, unique, DNS-safe
        image: "cc/egress-proxy:1.2.3",     # required
        egress: :allow,                     # required for sidecars, see below
        entrypoint: ["/proxy"],             # optional
        command: ["--listen", ":8080"],     # optional
        env: %{"LOG_LEVEL" => "info"},      # optional
        volumes: [                          # see `CrowdControl.Volume`
          %{name: "cache", target: "/cache", read_only: false},
          %{host_path: "/srv/in", target: "/in", read_only: true}
        ],
        depends_on: ["db"],                 # optional, topologically ordered
        user: "1000:1000",                  # optional
        port: 8080                          # only read for :proxy_service
      }

  Every service gets its `name` as an alias on the sandbox network, so services
  address each other by name and nothing has to learn an IP.

  ## Posture is never inferred

    * `:egress` on a sidecar is **required** and has no default. `:none` keeps
      it on the internal network only; `:allow` also attaches it to the NAT
      bridge. Omitting it is `{:error, {:compose, {:egress_required, name}}}`,
      for the same reason `CrowdControl.Backend.Docker` refuses to guess
      `:network_mode` and `CrowdControl.Provider.Docker` refuses to guess
      `:egress`. A sidecar with `:allow` sits on both networks and *can* relay
      the internet into the sandbox — which is exactly what an egress proxy is
      for, and exactly why saying so is mandatory.
    * The sandbox service can never carry `:allow`; asking is
      `{:error, {:compose, :sandbox_egress_forbidden}}`.
    * `network: [internal: false]` is accepted, and gives the sandbox a NAT
      bridge and full internet. It is the one option here that throws away the
      module's reason to exist, so it exists only as an explicit, typed-out
      act.

  ## Egress proxy

  No proxy ships with this library; `SECURITY.md` specifies what a conforming
  one must do. Naming one with `:proxy_service` wires both halves of that
  contract:

    * the sandbox's environment goes through
      `CrowdControl.Backend.Credentials.apply_credentials/2` —
      `ANTHROPIC_BASE_URL` points at the proxy's alias and `ANTHROPIC_API_KEY`
      becomes a per-session token, with any real `:api_key` **removed** rather
      than overridden;
    * the proxy receives `CC_SESSION_TOKEN` (the minted token, so it can
      recognise the session) and the real `ANTHROPIC_API_KEY` (so it can
      substitute it upstream).

  The proxy must declare `egress: :allow`, or it could not reach the upstream
  API and the sandbox would fail in a way that looked like a model bug:
  `{:error, {:compose, {:proxy_needs_egress, name}}}`.

  With no `:proxy_service`, `:api_key` is placed in the sandbox's own
  environment unchanged and no `ANTHROPIC_BASE_URL` is set. That is the honest
  no-proxy posture — the sandbox holds a real provider credential — and it is
  what makes the removal above observable rather than notional. `:api_key` and
  `:session_token` are both in `CrowdControl.Store.secret_keys/0`, so neither
  survives `scrub/1` into a Store record.

  Unlike `CrowdControl.Backend.Docker`, this provider needs no explicit
  `:network_mode` to make the proxy enforcing. There is no `bridge` to
  accidentally choose: the sandbox network is created by this module, is
  internal by default, and lives and dies with the session.

  ## The published port is never persisted

  Every `stop`/`start`/`restart` allocates a **new** ephemeral host port, and
  while a container is stopped `NetworkSettings.Ports` is `{}` rather than
  reporting the old one. `reconnect/1` therefore always re-reads the
  forwarder's port. Measured behaviour, not caution.
  """

  @behaviour CrowdControl.Provider

  @compile {:no_warn_undefined, Req}

  require Logger

  alias CrowdControl.Backend.Credentials
  alias CrowdControl.Backend.Docker.API
  alias CrowdControl.Backend.Docker.HostConfig
  alias CrowdControl.Backend.Sandboxd.API, as: AgentAPI
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Docker
  alias CrowdControl.Provider.Endpoint
  alias CrowdControl.ReqAdapter
  alias CrowdControl.Store

  @default_agent_port 8080
  @default_capture "/var/log/cc/out.jsonl"
  @default_ready_timeout 30_000
  @default_health_timeout 60_000
  @default_sandbox_service "sandbox"
  @default_forwarder_service "forwarder"
  @default_proxy_port 8080

  # Pinned, and only the *command* is load-bearing: any image with socat on
  # PATH works, which is what :forwarder_image is for on an air-gapped
  # registry.
  @default_forwarder_image "alpine/socat:1.8.1.3"

  @health_poll_interval 250

  # A network DELETE answers 403 while a container is still attached, and a
  # container that has not finished going away is exactly what produces it.
  # Retrying the whole sequence is cheaper than modelling the daemon's
  # intermediate states.
  @teardown_attempts 3
  @teardown_backoff 100

  # `docker compose ls` reads a project's identity off `project`, and
  # `compose ps` needs `service`/`container-number`/`oneoff` to render a row.
  # `config-hash` and `version` are deliberately absent: emitting them tells the
  # compose CLI it owns the stack, and a `docker compose up` in the same project
  # would then decide the config had drifted and recreate every container
  # underneath a live session (docker/compose v5 `pkg/api/labels.go`).
  @project_label "com.docker.compose.project"
  @service_label "com.docker.compose.service"

  defstruct [
    :project,
    :session_key,
    :owner,
    :created_at,
    :sandbox_network,
    :publish_network,
    :egress_network,
    :sandbox_service,
    :forwarder_service,
    agent_port: @default_agent_port,
    capture_path: @default_capture,
    containers: [],
    volumes: [],
    config: []
  ]

  @type t :: %__MODULE__{
          project: String.t() | nil,
          session_key: String.t() | nil,
          owner: String.t() | nil,
          created_at: integer() | nil,
          sandbox_network: String.t() | nil,
          publish_network: String.t() | nil,
          egress_network: String.t() | nil,
          sandbox_service: String.t() | nil,
          forwarder_service: String.t() | nil,
          agent_port: pos_integer(),
          capture_path: String.t(),
          containers: [{String.t(), String.t()}],
          volumes: [String.t()],
          config: keyword()
        }

  # --- acquire ---

  @impl true
  def acquire(opts) do
    # Every gate runs before a single byte reaches the daemon, k8s-style. A
    # stack is N resources, and discovering an invalid service spec after four
    # of them exist means rolling back four resources to report a typo.
    with :ok <- ensure_req!(),
         {:ok, session_key} <- fetch_session_key(opts),
         {:ok, project} <- fetch_project(opts, session_key),
         {:ok, network} <- fetch_network(opts),
         {:ok, volumes} <- fetch_volumes(opts, project),
         {:ok, services} <- build_services(opts),
         :ok <- validate_mounts(services, volumes),
         :ok <- validate_ready(opts, services),
         :ok <- validate_proxy(opts, services),
         {:ok, ordered} <- order_services(services) do
      handle = %__MODULE__{
        project: project,
        session_key: session_key,
        owner: opts[:owner] || Store.owner_id(),
        created_at: System.system_time(:millisecond),
        sandbox_network: project <> "-sbx",
        publish_network: project <> "-pub",
        egress_network: project <> "-egress",
        sandbox_service: sandbox_name(opts),
        forwarder_service: forwarder_name(opts),
        agent_port: opts[:agent_port] || @default_agent_port,
        capture_path: opts[:capture_path] || @default_capture,
        volumes: Enum.map(volumes, & &1.full_name),
        config: opts
      }

      start_stack(handle, ordered, network, volumes, credentials(opts, services))
    end
  end

  # Every resource name is derived from the project *before* any HTTP happens,
  # so `handle` is already complete when the first call is made and rollback can
  # never be looking at a half-populated struct. Only container ids accumulate,
  # and `launch/3` is shaped around that.
  defp start_stack(handle, services, network, volumes, creds) do
    with {:ok, _} <- create_sandbox_network(handle, network),
         {:ok, _} <- create_publish_network(handle),
         :ok <- create_egress_network(handle, services),
         :ok <- create_volumes(handle, volumes) do
      launch(handle, services, creds)
    else
      # An `else` is safe here only because nothing above it rebinds `handle` —
      # see the comment on `bring_up/3`.
      {:error, reason} -> rollback(handle, reason)
    end
  end

  defp launch(handle, services, creds) do
    case Enum.reduce_while(services, {:ok, handle}, &launch_one(&1, &2, creds)) do
      {:ok, handle} -> finish(handle)
      {:error, handle, reason} -> rollback(handle, reason)
    end
  end

  defp launch_one(service, {:ok, handle}, creds) do
    case create_container(handle, service, creds) do
      {:ok, id} -> bring_up(add_container(handle, service.name, id), service, id)
      {:error, reason} -> {:halt, {:error, handle, reason}}
    end
  end

  # `handle` arrives as an argument rather than being rebound inside the `with`,
  # because an `else` branch cannot see rebindings made in the body: written the
  # obvious way, the rollback below would run against a handle that still had
  # `containers: []` and would delete the networks while leaking every
  # container — silently, since `release/1` returns `:ok` either way.
  defp bring_up(handle, service, id) do
    with :ok <- connect_networks(handle, service, id),
         :ok <- start_container(handle, id),
         :ok <- await_healthy(handle, service, id) do
      {:cont, {:ok, handle}}
    else
      {:error, reason} -> {:halt, {:error, handle, reason}}
    end
  end

  defp finish(handle) do
    case await_endpoint(handle) do
      {:ok, endpoint} -> {:ok, handle, endpoint}
      {:error, reason} -> rollback(handle, reason)
    end
  end

  # Unconditional, not best-effort-on-some-paths. A leaked stack is N resources
  # rather than one, and a leaked network is worse than untidy: its name is
  # derived from the session key, so the next acquire for that session inherits
  # it.
  defp rollback(handle, reason) do
    _ = release(handle)
    {:error, reason}
  end

  # --- networks ---

  defp create_sandbox_network(handle, network) do
    body =
      %{
        "Name" => handle.sandbox_network,
        "Driver" => network.driver,
        "Internal" => network.internal,
        "Labels" => network_labels(handle, "sbx")
      }
      |> maybe_put("Options", presence(network.options))

    create_network(handle, body)
  end

  # `enable_ip_masquerade=false` is not configurable: it is the only reason the
  # forwarder — the one container the host can reach — has no internet of its
  # own. Non-internal it must be, or `PortBindings` are silently discarded.
  defp create_publish_network(handle) do
    create_network(handle, %{
      "Name" => handle.publish_network,
      "Driver" => "bridge",
      "Options" => %{"com.docker.network.bridge.enable_ip_masquerade" => "false"},
      "Labels" => network_labels(handle, "pub")
    })
  end

  defp create_egress_network(handle, services) do
    if Enum.any?(services, &(&1.egress == :allow)) do
      body = %{
        "Name" => handle.egress_network,
        "Driver" => "bridge",
        "Labels" => network_labels(handle, "egress")
      }

      case create_network(handle, body) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp create_network(handle, body) do
    case API.request(handle.config, :post, "/networks/create", json: body) do
      {:ok, response} ->
        {:ok, response}

      # A network left behind by a crashed run is reusable: the name is derived
      # from the session key, the labels and posture are identical, and
      # release/1 removes it either way.
      {:error, {:docker, {:http_status, 409, _}}} ->
        {:ok, :exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Second and subsequent endpoints, after create. Create-time dual attach is
  # HTTP 400 below API 1.44 and daemons still report MinAPIVersion 1.40; the
  # connect path is verified equivalent. Done before `start`, so the container
  # never runs with an endpoint missing.
  defp connect_networks(handle, service, id) do
    Enum.reduce_while(secondary_networks(handle, service), :ok, fn network, :ok ->
      body = %{"Container" => id, "EndpointConfig" => %{"Aliases" => [service.name]}}

      case API.request(handle.config, :post, "/networks/#{network}/connect", json: body) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp primary_network(handle, %{role: :forwarder}), do: handle.publish_network
  defp primary_network(handle, _service), do: handle.sandbox_network

  defp secondary_networks(handle, %{role: :forwarder}), do: [handle.sandbox_network]
  defp secondary_networks(handle, %{egress: :allow}), do: [handle.egress_network]
  defp secondary_networks(_handle, _service), do: []

  # --- volumes ---

  defp create_volumes(handle, volumes) do
    each_ok(volumes, fn volume ->
      body =
        %{"Name" => volume.full_name, "Labels" => volume_labels(handle, volume.name)}
        |> maybe_put("Driver", volume.driver)

      case API.request(handle.config, :post, "/volumes/create", json: body) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # --- containers ---

  defp create_container(handle, service, creds) do
    name = container_name(handle, service)

    case API.request(handle.config, :post, "/containers/create",
           params: [name: name],
           json: container_body(handle, service, creds)
         ) do
      {:ok, %{"Id" => id}} ->
        {:ok, id}

      # Not adopted. A container of that name holds an environment this run did
      # not write — including, possibly, a token derived from a since-rotated
      # secret. `list_live/1` finds and destroys it; guessing that it is safe to
      # reuse does not.
      {:error, {:docker, {:http_status, 409, _}}} ->
        {:error, {:compose, {:name_conflict, name}}}

      {:ok, other} ->
        {:error, {:compose, {:unexpected_create_response, other}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp container_body(handle, service, creds) do
    %{
      "Image" => service.image,
      "Labels" => container_labels(handle, service),
      "Env" => env(handle, service, creds),
      "HostConfig" => host_config(handle, service),
      "NetworkingConfig" => %{
        "EndpointsConfig" => %{
          primary_network(handle, service) => %{"Aliases" => [service.name]}
        }
      }
    }
    |> maybe_put("Entrypoint", service.entrypoint)
    |> maybe_put("Cmd", service.command)
    |> maybe_put("User", service.user)
    |> maybe_put("ExposedPorts", exposed_ports(handle, service))
    |> maybe_put("Healthcheck", healthcheck(handle, service))
  end

  # Only the forwarder exposes and publishes. On the sandbox these fields would
  # not merely be useless but actively misleading: the daemon accepts them with
  # `"Warnings": []`, echoes them back in `HostConfig.PortBindings`, and binds
  # nothing, because the network is internal.
  defp exposed_ports(handle, %{role: :forwarder}), do: %{port_key(handle) => %{}}
  defp exposed_ports(_handle, _service), do: nil

  # HostIp is mandatory, not cosmetic: omitting it yields TWO bindings (IPv4 and
  # IPv6) on every interface, which publishes the agent to the network rather
  # than to the host.
  defp port_bindings(handle, %{role: :forwarder}) do
    %{port_key(handle) => [%{"HostIp" => "127.0.0.1", "HostPort" => "0"}]}
  end

  defp port_bindings(_handle, _service), do: nil

  defp host_config(handle, service) do
    handle.config
    |> HostConfig.build(network_mode: primary_network(handle, service))
    |> maybe_put("Binds", presence(binds(handle, service)))
    |> maybe_put("PortBindings", port_bindings(handle, service))
  end

  defp binds(handle, service) do
    Enum.map(service.mounts, fn mount ->
      suffix = if mount.read_only, do: ":ro", else: ""

      # A named volume is namespaced by the project, because the stack created
      # it and destroys it. A host path is the host's, and prefixing it would
      # name a directory that does not exist.
      source = mount.host_path || "#{handle.project}-#{mount.name}"

      "#{source}:#{mount.target}#{suffix}"
    end)
  end

  defp start_container(handle, id) do
    case API.request(handle.config, :post, "/containers/#{id}/start") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Compose's own shape, so `docker compose ps` renders these rows. One
  # container per service, so the replica number is always 1.
  defp container_name(handle, service), do: "#{handle.project}-#{service.name}-1"

  defp add_container(handle, name, id) do
    %{handle | containers: handle.containers ++ [{name, id}]}
  end

  defp container_id(handle, service_name) do
    case List.keyfind(handle.containers, service_name, 0) do
      {^service_name, id} -> {:ok, id}
      nil -> {:error, {:compose, {:no_container, service_name}}}
    end
  end

  # --- environment ---

  defp env(handle, %{role: :sandbox} = service, creds) do
    # The agent contract is merged *last* and unconditionally: a service spec
    # cannot redefine the port the provider then publishes, the bind address the
    # forwarder depends on, or the token the endpoint is derived from.
    #
    # CC_SANDBOXD_BIND must be 0.0.0.0. The forwarder reaches the agent across
    # the internal network, so an agent on the container's own loopback would
    # never be reached; non-routability is the internal network's job.
    service.env
    |> put_api_key(handle.config[:api_key])
    |> Credentials.apply_credentials(creds)
    |> Map.merge(%{
      "CC_SANDBOXD_TOKEN" => Provider.token(handle.session_key),
      "CC_SANDBOXD_PORT" => to_string(handle.agent_port),
      "CC_SANDBOXD_BIND" => "0.0.0.0",
      "CC_SANDBOXD_CAPTURE" => handle.capture_path
    })
    |> encode_env()
  end

  defp env(handle, service, creds) do
    if service.name == handle.config[:proxy_service] do
      # The proxy's half of the SECURITY.md contract: the token it must accept
      # from the sandbox, and the real key it substitutes upstream.
      service.env
      |> Map.put("CC_SESSION_TOKEN", creds[:session_token])
      |> put_api_key(handle.config[:api_key])
      |> encode_env()
    else
      encode_env(service.env)
    end
  end

  defp put_api_key(env, key) when is_binary(key), do: Map.put(env, "ANTHROPIC_API_KEY", key)
  defp put_api_key(env, _key), do: env

  # Sorted so a request body is a function of its inputs alone, which is what
  # lets the hermetic tests assert on whole bodies rather than on sets.
  defp encode_env(env), do: env |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.sort()

  # Empty unless a proxy service is named, which is exactly the condition
  # `apply_credentials/2` keys off: with no `:proxy_url` it returns the
  # environment untouched, real key included.
  defp credentials(opts, services) do
    case opts[:proxy_service] do
      nil ->
        []

      name ->
        [
          proxy_url: opts[:proxy_url] || "http://#{name}:#{proxy_port(services, name)}",
          session_token: opts[:session_token] || mint_session_token()
        ]
    end
  end

  defp proxy_port(services, name) do
    case Enum.find(services, &(&1.name == name)) do
      %{proxy_port: port} when is_integer(port) -> port
      _ -> @default_proxy_port
    end
  end

  # Never persisted: `CrowdControl.Store.secret_keys/0` lists `:session_token`,
  # so it is stripped from `config` on the way to disk, and it is not a struct
  # field. The sandbox and the proxy both hold it; nothing else needs to
  # remember it.
  defp mint_session_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # --- labels ---

  defp base_labels(handle) do
    %{
      "crowd_control.session" => to_string(handle.session_key),
      "crowd_control.owner" => handle.owner,
      "crowd_control.created_at" => to_string(handle.created_at),
      "crowd_control.agent" => "sandboxd",
      @project_label => handle.project
    }
  end

  defp container_labels(handle, service) do
    Map.merge(base_labels(handle), %{
      @service_label => service.name,
      "com.docker.compose.container-number" => "1",
      "com.docker.compose.oneoff" => "False"
    })
  end

  defp network_labels(handle, name) do
    Map.put(base_labels(handle), "com.docker.compose.network", name)
  end

  defp volume_labels(handle, name) do
    Map.put(base_labels(handle), "com.docker.compose.volume", name)
  end

  # --- healthchecks ---

  # Engine API durations are nanoseconds. The container config field is
  # `Healthcheck`; `HealthConfig` is the name of its type, not of the field.
  defp healthcheck(handle, service) do
    case ready_spec(handle.config, service.name) do
      nil ->
        nil

      spec ->
        %{
          "Test" => spec.test,
          "Interval" => ms_to_ns(spec.interval_ms),
          "Timeout" => ms_to_ns(spec.timeout_ms),
          "Retries" => spec.retries,
          "StartPeriod" => ms_to_ns(spec.start_period_ms)
        }
    end
  end

  defp await_healthy(handle, service, id) do
    case ready_spec(handle.config, service.name) do
      nil -> :ok
      _spec -> poll_health(handle, service.name, id, health_deadline(handle))
    end
  end

  defp poll_health(handle, name, id, deadline) do
    case container_health(handle, id) do
      "healthy" ->
        :ok

      # Terminal, not slow: a sandbox wired to a broken proxy fails later, in a
      # way that looks like the model's fault. The caller's `acquire/1` rolls the
      # whole stack back.
      "unhealthy" ->
        {:error, {:compose, {:unhealthy, name}}}

      # "starting", or no `State.Health` yet — the daemon populates it a beat
      # after `start` returns.
      _pending ->
        if System.monotonic_time(:millisecond) + @health_poll_interval < deadline do
          Process.sleep(@health_poll_interval)
          poll_health(handle, name, id, deadline)
        else
          {:error, {:compose, {:unhealthy, name}}}
        end
    end
  end

  defp container_health(handle, id) do
    case API.request(handle.config, :get, "/containers/#{id}/json") do
      {:ok, json} -> get_in(json, ["State", "Health", "Status"])
      {:error, _reason} -> nil
    end
  end

  defp health_deadline(handle) do
    System.monotonic_time(:millisecond) +
      (handle.config[:health_timeout] || @default_health_timeout)
  end

  defp ms_to_ns(ms), do: ms * 1_000_000

  # --- reconnect ---

  @impl true
  def reconnect(%__MODULE__{containers: []}), do: {:error, {:compose, :not_provisioned}}

  def reconnect(%__MODULE__{} = handle) do
    with {:ok, endpoint} <- await_endpoint(handle) do
      {:ok, handle, endpoint}
    end
  end

  defp await_endpoint(handle) do
    with {:ok, id} <- container_id(handle, handle.forwarder_service),
         {:ok, host_port} <- read_host_port(handle, id),
         endpoint = endpoint(handle, host_port),
         :ok <- AgentAPI.await_health(endpoint, ready_timeout(handle)) do
      {:ok, endpoint}
    end
  end

  # `CrowdControl.Provider.Docker.host_port_from_inspect/2` already implements
  # every one of the four observed "no usable port" shapes — a present key with
  # a null value, an empty-string HostPort, an empty Ports map, an absent key. A
  # second copy would be a second place for one of them to be forgotten.
  defp read_host_port(handle, id) do
    case API.request(handle.config, :get, "/containers/#{id}/json") do
      {:ok, json} -> Docker.host_port_from_inspect(json, handle.agent_port)
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoint(handle, host_port) do
    %Endpoint{
      base_url: "http://127.0.0.1:#{host_port}",
      token: Provider.token(handle.session_key),
      req_options: ReqAdapter.req_options(handle.config[:req_adapter])
    }
  end

  defp ready_timeout(handle), do: handle.config[:ready_timeout] || @default_ready_timeout

  # --- release ---

  @impl true
  def release(%__MODULE__{} = handle) do
    teardown(handle, @teardown_attempts)
    :ok
  end

  # The order is forced, not stylistic:
  #
  #   1. containers — a network DELETE answers 403 while one is attached;
  #   2. networks;
  #   3. named volumes, explicitly — `DELETE /containers/{id}?v=true` removes
  #      *anonymous* volumes only, so a named one outlives the whole stack.
  #
  # Anything that fails for a reason other than "already gone" is retried
  # rather than abandoned, because the common failure is a container that has
  # not finished going away yet.
  defp teardown(handle, attempts_left) do
    failures = Enum.flat_map(teardown_targets(handle), &delete(handle, &1))

    cond do
      failures == [] ->
        :ok

      attempts_left > 1 ->
        Process.sleep(@teardown_backoff)
        teardown(handle, attempts_left - 1)

      true ->
        Logger.warning("compose teardown incomplete for #{handle.project}: #{inspect(failures)}")
        :ok
    end
  end

  defp teardown_targets(handle) do
    Enum.map(container_ids(handle), &{"/containers/#{&1}", [params: [force: true, v: true]]}) ++
      Enum.map(networks(handle), &{"/networks/#{&1}", []}) ++
      Enum.map(volumes(handle), &{"/volumes/#{&1}", []})
  end

  defp delete(handle, {path, opts}) do
    case API.request(handle.config, :delete, path, opts) do
      {:ok, _} -> []
      # Already gone is the desired end state, which is what makes release/1
      # idempotent across the several teardown paths Session calls it from.
      {:error, {:docker, {:not_found, _}}} -> []
      {:error, reason} -> [{path, reason}]
    end
  end

  defp container_ids(handle), do: Enum.map(handle.containers, &elem(&1, 1))

  # All three names, unconditionally. A stack whose sidecars never asked for
  # egress has no `-egress` network and the DELETE 404s, which is success — and
  # a handle `list_live/1` rebuilt from container labels cannot know either way,
  # so guessing "it probably doesn't exist" is how one gets leaked.
  defp networks(%__MODULE__{project: nil}), do: []

  defp networks(handle) do
    [handle.sandbox_network, handle.publish_network, handle.egress_network]
  end

  # Two sources, for two different handles. The persisted list is what an
  # acquire-path or rolled-back handle knows; the label query is the only thing
  # that works for a handle `list_live/1` rebuilt from container labels, which
  # would otherwise leak every named volume the reaper reaps.
  defp volumes(handle), do: Enum.uniq(handle.volumes ++ discovered_volumes(handle))

  defp discovered_volumes(%__MODULE__{session_key: nil}), do: []

  defp discovered_volumes(handle) do
    filters = JSON.encode!(%{"label" => ["crowd_control.session=#{handle.session_key}"]})

    case API.request(handle.config, :get, "/volumes", params: [filters: filters]) do
      {:ok, %{"Volumes" => volumes}} when is_list(volumes) -> Enum.map(volumes, & &1["Name"])
      _ -> []
    end
  end

  # --- list_live / age_ms / scrub ---

  @impl true
  def list_live(opts) do
    owner = opts[:owner] || Store.owner_id()

    # Owner- and agent-scoped for the same reason `Provider.Docker` is:
    # unscoped, one node's reaper destroys another node's sandboxes, and
    # without the agent label it also picks up `Backend.Docker`'s FIFO
    # containers. `oneoff=False` additionally excludes `Provider.Docker`'s
    # single containers, which carry no compose labels at all.
    filters =
      JSON.encode!(%{
        "label" => [
          "crowd_control.owner=#{owner}",
          "crowd_control.agent=sandboxd",
          "com.docker.compose.oneoff=False"
        ]
      })

    case API.request(opts, :get, "/containers/json", params: [filters: filters, all: false]) do
      {:ok, containers} when is_list(containers) ->
        {:ok, group_into_stacks(containers, opts, owner)}

      {:ok, other} ->
        {:error, {:compose, {:unexpected_list_response, other}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One handle per *stack*, so `CrowdControl.Reaper` reaps stacks rather than
  # picking containers off one at a time and leaving a half-torn-down stack
  # behind. Grouped by session, not by compose project: the session key is what
  # a Store record is keyed on and what finds the stack's named volumes.
  defp group_into_stacks(containers, opts, owner) do
    containers
    |> Enum.group_by(&labels(&1)["crowd_control.session"])
    |> Enum.reject(fn {session, _group} -> is_nil(session) end)
    |> Enum.map(fn {session, group} -> handle_from_stack(session, group, opts, owner) end)
  end

  defp handle_from_stack(session, containers, opts, owner) do
    first = labels(hd(containers))
    project = first[@project_label] || project_name(session)

    %__MODULE__{
      project: project,
      session_key: session,
      owner: first["crowd_control.owner"] || owner,
      created_at: parse_int(first["crowd_control.created_at"]),
      sandbox_network: project <> "-sbx",
      publish_network: project <> "-pub",
      egress_network: project <> "-egress",
      sandbox_service: sandbox_name(opts),
      forwarder_service: forwarder_name(opts),
      agent_port: opts[:agent_port] || @default_agent_port,
      capture_path: opts[:capture_path] || @default_capture,
      containers: Enum.map(containers, &{labels(&1)[@service_label], &1["Id"]}),
      config: opts
    }
  end

  defp labels(container), do: Map.get(container, "Labels") || %{}

  @impl true
  def age_ms(%__MODULE__{} = handle) do
    with {:ok, id} <- container_id(handle, handle.sandbox_service),
         {:ok, %{"Config" => %{"Labels" => %{"crowd_control.created_at" => created}}}} <-
           API.request(handle.config, :get, "/containers/#{id}/json"),
         ms when is_integer(ms) <- parse_int(created) do
      max(System.system_time(:millisecond) - ms, 0)
    else
      _ -> nil
    end
  end

  @impl true
  def scrub(%__MODULE__{} = handle) do
    # `Store.scrub_opts/1` drops the top-level credential keys. It cannot see
    # into `:services`, and a service spec's `:env` is exactly where a proxy's
    # upstream key or a database password lives — so the specs are stripped too.
    # Store records are written to disk and outlive the VM, and reconnecting
    # needs none of it: every container already holds the environment it was
    # started with.
    %{handle | config: handle.config |> Store.scrub_opts() |> scrub_services()}
  end

  defp scrub_services(config) do
    case config[:services] do
      specs when is_list(specs) -> Keyword.put(config, :services, Enum.map(specs, &drop_env/1))
      _ -> config
    end
  end

  defp drop_env(spec) when is_map(spec), do: Map.drop(spec, [:env])
  defp drop_env(spec), do: spec

  # --- validation gates ---

  defp fetch_session_key(opts) do
    case opts[:session_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:compose, :session_key_required}}
    end
  end

  # The project name is also a network name, a volume name and a container name
  # component, and the compose CLI lowercases project names. Rejecting an
  # invalid one here beats a 500 from the daemon four calls later.
  defp fetch_project(opts, session_key) do
    name = opts[:project_name] || project_name(session_key)

    if is_binary(name) and name =~ ~r/^[a-z0-9][a-z0-9_-]*$/ do
      {:ok, name}
    else
      {:error, {:compose, {:bad_project_name, name}}}
    end
  end

  defp project_name(session_key), do: "cc-" <> String.downcase(to_string(session_key))

  defp fetch_network(opts) do
    network = opts[:network] || []

    with true <- Keyword.keyword?(network),
         internal = Keyword.get(network, :internal, true),
         true <- is_boolean(internal),
         driver = Keyword.get(network, :driver, "bridge"),
         true <- is_binary(driver),
         options = Keyword.get(network, :options, %{}),
         true <- is_map(options) do
      {:ok, %{internal: internal, driver: driver, options: options}}
    else
      _ -> {:error, {:compose, {:bad_network, network}}}
    end
  end

  defp fetch_volumes(opts, project) do
    with {:ok, specs} <- fetch_list(opts, :volumes) do
      collect(specs, &normalize_volume(&1, project))
    end
  end

  defp normalize_volume(spec, project) do
    with true <- is_map(spec),
         name when is_binary(name) <- Map.get(spec, :name),
         true <- name =~ ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ do
      {:ok, %{name: name, full_name: "#{project}-#{name}", driver: Map.get(spec, :driver)}}
    else
      _ -> {:error, {:compose, {:bad_volume, spec}}}
    end
  end

  # Enumerating a non-list here would raise a Protocol.UndefinedError out of a
  # validation gate, which is the one place in this module that must always
  # answer with a tagged tuple.
  defp fetch_list(opts, key) do
    case Keyword.get(opts, key, []) do
      list when is_list(list) -> {:ok, list}
      other -> {:error, {:compose, {:bad_option, {key, other}}}}
    end
  end

  # --- service specs ---

  defp sandbox_name(opts), do: opts[:sandbox_service] || @default_sandbox_service
  defp forwarder_name(opts), do: opts[:forwarder_service] || @default_forwarder_service

  defp build_services(opts) do
    sandbox = sandbox_name(opts)
    forwarder = forwarder_name(opts)

    with {:ok, specs} <- fetch_list(opts, :services),
         :ok <- validate_names(specs, sandbox, forwarder),
         {:ok, declared} <- normalize_specs(specs, sandbox),
         {:ok, sandbox_spec} <- build_sandbox(opts, declared, sandbox) do
      sidecars = Enum.reject(declared, &(&1.name == sandbox))
      {:ok, [sandbox_spec | sidecars] ++ [build_forwarder(opts, sandbox, forwarder)]}
    end
  end

  defp validate_names(specs, sandbox, forwarder) do
    names = Enum.map(specs, &spec_name/1)

    cond do
      sandbox == forwarder ->
        {:error, {:compose, {:duplicate_service, sandbox}}}

      # The forwarder is always synthesised, so a declared service of that name
      # is a collision rather than an override — see `build_forwarder/3`.
      forwarder in names ->
        {:error, {:compose, {:duplicate_service, forwarder}}}

      length(Enum.uniq(names)) != length(names) ->
        {:error, {:compose, {:duplicate_service, first_duplicate(names)}}}

      true ->
        :ok
    end
  end

  defp spec_name(spec) when is_map(spec), do: Map.get(spec, :name)
  defp spec_name(_spec), do: nil

  defp first_duplicate(names) do
    Enum.reduce_while(names, [], fn name, seen ->
      if name in seen, do: {:halt, name}, else: {:cont, [name | seen]}
    end)
  end

  defp normalize_specs(specs, sandbox) do
    collect(specs, fn spec ->
      normalize_spec(spec, if(spec_name(spec) == sandbox, do: :sandbox, else: :sidecar))
    end)
  end

  defp normalize_spec(spec, role) when is_map(spec) do
    with {:ok, name} <- spec_name!(spec),
         {:ok, image} <- spec_image(spec, role),
         {:ok, egress} <- spec_egress(spec, name, role),
         {:ok, entrypoint} <- spec_strings(spec, :entrypoint, name),
         {:ok, command} <- spec_strings(spec, :command, name),
         {:ok, depends_on} <- spec_strings(spec, :depends_on, name),
         {:ok, env} <- spec_env(spec, name),
         {:ok, mounts} <- spec_mounts(spec, name) do
      {:ok,
       %{
         name: name,
         image: image,
         role: role,
         egress: egress,
         entrypoint: entrypoint,
         command: command,
         env: env,
         mounts: mounts,
         depends_on: depends_on || [],
         user: Map.get(spec, :user),
         proxy_port: Map.get(spec, :port)
       }}
    end
  end

  # Maps only, and deliberately so: `scrub/1` has to strip `:env` out of the
  # persisted specs without a second normalisation pass over a shape it can only
  # guess at.
  defp normalize_spec(spec, _role), do: {:error, {:compose, {:bad_service, spec}}}

  # A service name is a DNS alias on the sandbox network, which is how every
  # other service in the stack addresses it.
  defp spec_name!(spec) do
    case Map.get(spec, :name) do
      name when is_binary(name) ->
        if name =~ ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/ and byte_size(name) <= 63 do
          {:ok, name}
        else
          {:error, {:compose, {:bad_service_name, name}}}
        end

      other ->
        {:error, {:compose, {:bad_service_name, other}}}
    end
  end

  # The sandbox may inherit the top-level `:image`, which is the option
  # `Provider.Docker` uses for exactly the same thing; a sidecar has no such
  # fallback. `build_sandbox/3` fills the `nil` in.
  defp spec_image(spec, :sandbox) do
    case Map.get(spec, :image) do
      image when is_binary(image) and image != "" -> {:ok, image}
      _ -> {:ok, nil}
    end
  end

  defp spec_image(spec, _role) do
    case Map.get(spec, :image) do
      image when is_binary(image) and image != "" -> {:ok, image}
      _ -> {:error, {:compose, {:image_required, Map.get(spec, :name)}}}
    end
  end

  # Never inferred. A sidecar on both networks can relay the internet into the
  # sandbox, which is the entire purpose of an egress proxy and exactly why it
  # has to be written down.
  defp spec_egress(spec, _name, :sandbox) do
    case Map.get(spec, :egress, :none) do
      :none -> {:ok, :none}
      _ -> {:error, {:compose, :sandbox_egress_forbidden}}
    end
  end

  defp spec_egress(spec, name, _role) do
    case Map.get(spec, :egress) do
      egress when egress in [:none, :allow] -> {:ok, egress}
      nil -> {:error, {:compose, {:egress_required, name}}}
      other -> {:error, {:compose, {:bad_egress, {name, other}}}}
    end
  end

  defp spec_strings(spec, key, name) do
    case Map.get(spec, key) do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: bad(name, key)

      _ ->
        bad(name, key)
    end
  end

  defp spec_env(spec, name) do
    case Map.get(spec, :env, %{}) do
      env when is_map(env) ->
        if Enum.all?(env, &binary_pair?/1), do: {:ok, env}, else: bad(name, :env)

      _ ->
        bad(name, :env)
    end
  end

  defp binary_pair?({key, value}), do: is_binary(key) and is_binary(value)

  # The shape rules live in `CrowdControl.Volume` so Compose, Docker and
  # Kubernetes cannot drift on what a mount is. What stays here is Compose's
  # own vocabulary for a bad one, and the fact that a `:name` must be a volume
  # this stack declared — see `validate_mounts/2`, which a host path skips
  # because there is nothing to declare.
  defp spec_mounts(spec, name) do
    collect(Map.get(spec, :volumes, []), fn mount ->
      case CrowdControl.Volume.normalize([volumes: [mount]], []) do
        {:ok, [%{kind: :volume, source: volume, target: target, read_only: read_only}]} ->
          {:ok, %{name: volume, host_path: nil, target: target, read_only: read_only}}

        {:ok, [%{kind: :host_path, source: path, target: target, read_only: read_only}]} ->
          {:ok, %{name: nil, host_path: path, target: target, read_only: read_only}}

        {:error, _reason} ->
          {:error, {:compose, {:bad_mount, {name, mount}}}}
      end
    end)
  end

  defp bad(name, key), do: {:error, {:compose, {:bad_service, {name, key}}}}

  defp build_sandbox(opts, declared, sandbox) do
    case Enum.find(declared, &(&1.name == sandbox)) do
      nil ->
        with {:ok, image} <- fetch_image(opts) do
          {:ok, synthesized_sandbox(opts, sandbox, image)}
        end

      %{image: nil} = spec ->
        with {:ok, image} <- fetch_image(opts), do: {:ok, %{spec | image: image}}

      spec ->
        {:ok, spec}
    end
  end

  defp synthesized_sandbox(opts, name, image) do
    %{
      name: name,
      image: image,
      role: :sandbox,
      egress: :none,
      entrypoint: nil,
      command: nil,
      env: %{},
      mounts: [],
      depends_on: [],
      user: opts[:user],
      proxy_port: nil
    }
  end

  defp fetch_image(opts) do
    case opts[:image] do
      image when is_binary(image) and image != "" -> {:ok, image}
      _ -> {:error, {:compose, :image_required}}
    end
  end

  # Always synthesised, image aside. A caller-supplied forwarder command is
  # precisely how a single-slot proxy gets back in: `busybox nc -e` serves one
  # connection at a time and dropped two of three concurrent requests in
  # testing, while `Backend.Sandboxd` holds a chunked stream open for the whole
  # session. `fork` is the property that matters; `reuseaddr` keeps a restart
  # from tripping over its own TIME_WAIT.
  #
  # The sandbox is addressed by alias, never by IP: IPs are reassigned on every
  # start, and the alias is what Docker's embedded DNS resolves on the internal
  # network.
  defp build_forwarder(opts, sandbox, forwarder) do
    port = opts[:agent_port] || @default_agent_port

    %{
      name: forwarder,
      image: opts[:forwarder_image] || @default_forwarder_image,
      role: :forwarder,
      egress: :none,
      entrypoint: ["socat"],
      command: ["TCP-LISTEN:#{port},fork,reuseaddr", "TCP:#{sandbox}:#{port}"],
      env: %{},
      mounts: [],
      depends_on: [sandbox],
      user: nil,
      proxy_port: nil
    }
  end

  # --- cross-service validation ---

  defp validate_mounts(services, volumes) do
    declared = MapSet.new(volumes, & &1.name)

    each_ok(services, fn service ->
      # A host path has nothing to declare; only a named volume must exist in
      # the stack, because the stack is what creates and destroys it.
      undeclared =
        Enum.find(service.mounts, fn mount ->
          mount.name != nil and not MapSet.member?(declared, mount.name)
        end)

      case undeclared do
        nil -> :ok
        mount -> {:error, {:compose, {:unknown_volume, mount.name}}}
      end
    end)
  end

  defp validate_ready(opts, services) do
    names = MapSet.new(services, & &1.name)

    case Keyword.get(opts, :ready, %{}) do
      ready when is_map(ready) ->
        each_ok(ready, &validate_ready_entry(names, &1))

      other ->
        {:error, {:compose, {:bad_ready, other}}}
    end
  end

  defp validate_ready_entry(names, {name, spec}) do
    cond do
      not MapSet.member?(names, name) -> {:error, {:compose, {:unknown_service, name}}}
      not valid_ready?(spec) -> {:error, {:compose, {:bad_ready, name}}}
      true -> :ok
    end
  end

  # Docker only accepts a `Test` whose first element names the mode. `"NONE"` is
  # rejected: it disables the healthcheck, so the poll below could never finish
  # and the caller asked for readiness gating by writing this option at all.
  defp valid_ready?(spec) when is_map(spec) do
    case Map.get(spec, :test) do
      [kind | rest] when kind in ["CMD", "CMD-SHELL"] ->
        rest != [] and Enum.all?(rest, &is_binary/1)

      _ ->
        false
    end
  end

  defp valid_ready?(_spec), do: false

  # Normalized in one place so `healthcheck/2` is a pure translation.
  defp ready_spec(config, name) do
    case config |> Keyword.get(:ready, %{}) |> Map.get(name) do
      nil ->
        nil

      spec ->
        %{
          test: Map.fetch!(spec, :test),
          interval_ms: Map.get(spec, :interval_ms, 1_000),
          timeout_ms: Map.get(spec, :timeout_ms, 3_000),
          retries: Map.get(spec, :retries, 10),
          start_period_ms: Map.get(spec, :start_period_ms, 0)
        }
    end
  end

  defp validate_proxy(opts, services) do
    case opts[:proxy_service] do
      nil ->
        :ok

      name ->
        case Enum.find(services, &(&1.name == name)) do
          nil -> {:error, {:compose, {:unknown_service, name}}}
          %{egress: :allow} -> :ok
          # A proxy on the internal network only cannot reach the upstream API,
          # and that failure surfaces inside the sandbox as if the model's own
          # request were at fault.
          _ -> {:error, {:compose, {:proxy_needs_egress, name}}}
        end
    end
  end

  # --- dependency ordering ---

  defp order_services(services) do
    names = MapSet.new(services, & &1.name)

    with :ok <- validate_dependencies(services, names) do
      topo_sort(services, [], [])
    end
  end

  defp validate_dependencies(services, names) do
    each_ok(services, fn service ->
      case Enum.find(service.depends_on, &(not MapSet.member?(names, &1))) do
        nil -> :ok
        missing -> {:error, {:compose, {:unknown_dependency, {service.name, missing}}}}
      end
    end)
  end

  # Kahn, level by level, preserving declaration order within a level so the
  # request sequence is reproducible. O(n^2) on a list that is never longer than
  # a handful of services.
  defp topo_sort([], _started, acc), do: {:ok, Enum.reverse(acc)}

  defp topo_sort(pending, started, acc) do
    {ready, blocked} =
      Enum.split_with(pending, fn service -> Enum.all?(service.depends_on, &(&1 in started)) end)

    case ready do
      [] -> {:error, {:compose, {:dependency_cycle, Enum.map(pending, & &1.name)}}}
      _ -> topo_sort(blocked, started ++ Enum.map(ready, & &1.name), Enum.reverse(ready) ++ acc)
    end
  end

  # --- private ---

  # `{:ok, value}` per item into `{:ok, list}`, first error wins. The two shapes
  # below are the only control flow this module needs and having them named
  # keeps the gates above readable as a list of rules.
  defp collect(enumerable, fun) do
    Enum.reduce_while(enumerable, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp each_ok(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp port_key(handle), do: "#{handle.agent_port}/tcp"

  defp presence(value) when value == %{} or value == [], do: nil
  defp presence(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_req! do
    if Code.ensure_loaded?(Req) do
      :ok
    else
      raise """
      CrowdControl.Provider.Compose requires the optional :req dependency.

      Add it to your deps:

          {:req, "~> 0.5"}
      """
    end
  end
end
