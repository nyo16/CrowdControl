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
    * `:networks` — extra **internal** networks, `[%{name: "brw"}]`. Created
      as `<project>-<name>` with `Internal: true` and destroyed with the stack.
      A service joins one by naming it in its own `networks:`; see "Per-service
      networks" below. `sbx`, `pub` and `egress` are reserved.
    * `:volumes` — named volume *declarations*, `[%{name: "workspace"}]`.
      Created as `<project>-<name>` and destroyed with the stack. Note this is
      a declaration list, not a mount list: a service mounts one by naming it
      in its own `:volumes`, and only Compose creates the storage it mounts —
      Docker and Kubernetes expect it to exist already.
    * `:ready` — per-service healthchecks, `%{"db" => %{test: [...]}}`. A
      service's own `ready: %{test: [...]}` is used when this has no entry.
    * `:project_name` — default `"cc-<session_key>"`.
    * `:proxy_service` — the sidecar fronting the egress proxy. See below.
    * `:health_timeout` — deadline for the healthcheck poll, default `60_000`.

  Agent, exactly as `CrowdControl.Provider.Docker` takes them: `:image`,
  `:agent_port`, `:capture_path`, `:ready_timeout`, `:req_adapter`,
  `:docker_host`, `:timeout`.

  Hardening (`:cpus`, `:memory`, `:cap_drop`, `:security_opt`, `:pids_limit`,
  `:user`, `:readonly_rootfs`, `:tmpfs`, `:shm_size`, `:init`) comes from
  these top-level options and is the **default for every container** in the
  stack, through `CrowdControl.Backend.Docker.HostConfig`.

  ### Hardened by default, per-service overrides, weakening explicit

  A service may override the stack's HostConfig with `host_config:`. Resource
  keys (`:shm_size`, `:init`, `:pids_limit`, `:memory`, `:cpus`, `:tmpfs`)
  need no declaration — a browser needs a large `/dev/shm` and an init, and
  neither weakens anything. A key that *weakens* the hardened default —
  `:cap_add`, `no_new_privileges: false`, `readonly_rootfs: false`, a root
  `user:`, a `host_path` mount on a sidecar (`:host_path`), or a `tmpfs`
  without `noexec,nosuid` (`:tmpfs_exec`) — must also be named in the
  service's `weaken: [...]` list (see `CrowdControl.Service`), or
  `acquire/1` refuses with
  `{:error, {:compose, {:weakening_not_declared, {service, key}}}}`. `privileged`
  is refused outright (`{:privileged_refused, service}`), declared or not.

  This replaces the earlier "one posture per stack" rule, and the risk it
  accepts is specific: in the two-tier browser layout the browser shares a
  network with the sandbox *and* has a path to the egress proxy, so a weakened
  browser (root, added capabilities, no `no-new-privileges`) is the most
  valuable target a compromised sandbox can reach. Hence per key, written
  down, never inferred.

  ### The capture file is the sandbox's alone

  A sidecar that reads the transcript (a log shipper) mounts the volume the
  sandbox mounts at `Path.dirname(:capture_path)`. It must mount it
  `read_only: true`: a writable mount of the same source (named volume or host
  path) could append to, truncate or rotate the capture and break every
  persisted byte offset. Nor may any service stage `:files` into it, since a
  pre-seeded capture is a forged transcript. Either is refused with
  `{:error, {:compose, {:capture_mount_writable, service}}}`.

  ### Service spec

  Validated by `CrowdControl.Service`, the shape Kubernetes shares:

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
        files: [%{path: "/cfg/acl.yaml", content: "...", mode: 0o444}],
        depends_on: ["db"],                 # optional, topologically ordered
        user: "1000:1000",                  # optional
        port: 8080,                         # only read for :proxy_service
        networks: ["brw"],                  # default ["sbx"]
        host_config: %{shm_size: 1_073_741_824, init: true},
        weaken: [:host_path],               # for the host_path mount; see above
        drain: 3_000,                       # ms; log shippers, see "Teardown"
        shutdown_limit: 20                  # s; with :drain
      }

  `placement:` is Kubernetes-only and ignored here with a warning.

  Every service gets its `name` as an alias on each network it joins, so
  services address each other by name and nothing has to learn an IP.

  ### `:files`

  Staged between `POST /containers/create` and `start` with
  `PUT /containers/{id}/archive`, as an in-memory tar carrying each file's
  `mode`, `uid` and `gid`. The daemon refuses an archive into a read-only
  rootfs unless the destination is inside a volume, so a file must sit under a
  writable mount of that service or on a writable rootfs, and not under a
  tmpfs (which would hide it at start); anything else is
  `{:error, {:compose, {:files_not_writable, {service, path}}}}` before any
  request. Paths are absolute and `..`-free, at most 1 MiB in total.
  **`:files` is for configuration, never credentials** — those go through
  `env:`.

  ### Per-service networks

  A service's first membership is its create-time endpoint; the rest are
  connected after create. `egress: :allow` still adds the NAT bridge, so
  posture comes from `egress`, never from a membership list. The sandbox must
  stay on `sbx`, which the forwarder reaches it across.

  Once a stack uses per-service networks (a `:networks` declaration or any
  `networks:` membership), the sandbox may share **no** network with an
  `egress: :allow` service other than the `:proxy_service`, which is exempt
  because the sandbox reaches the Anthropic API only through it:
  `{:error, {:compose, {:sandbox_shares_network_with_egress, {service, network}}}}`.
  A stack using neither keeps the single-network `sbx` model this module has
  always built, where an `egress: :allow` sidecar on `sbx` is the declared
  relay: with one network there is nowhere else to put it. Declaring
  `:networks` opts into the strict model. Its two-tier browser layout is the
  sandbox on `sbx`, the browser on `sbx` and `brw`, and the forward proxy on
  `brw` with `egress: :allow`.

  ### Minimum Docker version

  Per-service networks and any `egress: :allow` sidecar need Docker Engine
  25.0.5 or 26.0.0+: before that, the embedded DNS on an internal network
  forwarded queries upstream (CVE-2024-29018), an exfiltration path out of a
  network with no route. `GET /version` is asked once per `:docker_host`, only
  when one of those is in use, and an older daemon is
  `{:error, {:version, :docker, have, {25, 0, 5}}}` before anything is created.

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
  survives `scrub/1` into a Store record. A caller-supplied `:session_token`
  must start with `ccst_`, the prefix `CrowdControl.Preset.LogShipper` redacts,
  or `acquire/1` refuses with `{:error, {:compose, {:bad_session_token, :prefix}}}`.

  Unlike `CrowdControl.Backend.Docker`, this provider needs no explicit
  `:network_mode` to make the proxy enforcing. There is no `bridge` to
  accidentally choose: the sandbox network is created by this module, is
  internal by default, and lives and dies with the session.

  ## Teardown

  `release/1` force-removes every container, then the networks, then the
  named volumes. A service with `drain:` set (a log shipper) is first given a
  graceful stop, because a force-remove SIGKILLs it mid-flush and loses the
  transcript's tail: wait the longest `drain` (ms) once, so its file source
  reaches EOF, then `POST /containers/{id}/stop?t=<shutdown_limit + 5>`. The
  drain budget is also a container label, so a stack rebuilt by `list_live/1`
  drains the same way. A failed stop is logged and never blocks the
  force-remove; a rolled-back `acquire/1` does not drain at all.

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
  alias CrowdControl.Service
  alias CrowdControl.Store
  alias CrowdControl.VersionGate

  @default_agent_port 8080
  @default_capture "/var/log/cc/out.jsonl"
  @session_token_prefix "ccst_"
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

  # The drain budget of a `drain:` service, on its container, so a handle
  # `list_live/1` rebuilt from labels still drains it. Not compose's own
  # vocabulary, so no `com.docker.compose.` prefix.
  @drain_label "crowd_control.drain_ms"
  @stop_timeout_label "crowd_control.stop_timeout_s"

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
    networks: [],
    drained: [],
    config: []
  ]

  @typedoc "A drained service as teardown needs it: `{service, drain_ms, stop_timeout_s}`."
  @type drained :: {String.t(), non_neg_integer(), pos_integer()}

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
          networks: [String.t()],
          drained: [drained()],
          config: keyword()
        }

  # --- acquire ---

  @impl true
  def acquire(opts) do
    # Every gate runs before a single byte reaches the daemon, k8s-style. A
    # stack is N resources, and discovering an invalid service spec after four
    # of them exist means rolling back four resources to report a typo. The
    # version gate is last: it is the one gate that may make a request, and it
    # only does when a gated feature is in use.
    with :ok <- ensure_req!(),
         :ok <- validate_session_token(opts),
         {:ok, session_key} <- fetch_session_key(opts),
         {:ok, project} <- fetch_project(opts, session_key),
         {:ok, network} <- fetch_network(opts),
         {:ok, volumes} <- fetch_volumes(opts, project),
         {:ok, networks} <- fetch_networks(opts, project),
         {:ok, services} <- build_services(opts),
         :ok <- validate_mounts(services, volumes),
         :ok <- validate_memberships(opts, services, networks),
         :ok <- validate_files(opts, services),
         :ok <- validate_capture(opts, services),
         :ok <- validate_ready(opts, services),
         :ok <- validate_proxy(opts, services),
         {:ok, ordered} <- order_services(services),
         :ok <- ensure_versions(opts, services, networks) do
      warn_placement(services)

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
        networks: Enum.map(networks, & &1.full_name),
        drained: drained_specs(services),
        config: opts
      }

      start_stack(handle, ordered, network, volumes, networks, credentials(opts, services))
    end
  end

  # Every resource name is derived from the project *before* any HTTP happens,
  # so `handle` is already complete when the first call is made and rollback can
  # never be looking at a half-populated struct. Only container ids accumulate,
  # and `launch/3` is shaped around that.
  defp start_stack(handle, services, network, volumes, networks, creds) do
    with {:ok, _} <- create_sandbox_network(handle, network),
         {:ok, _} <- create_publish_network(handle),
         :ok <- create_egress_network(handle, services),
         :ok <- create_service_networks(handle, networks),
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
  #
  # Files are staged after every endpoint is attached and before `start`, so the
  # process never runs without its configuration.
  defp bring_up(handle, service, id) do
    with :ok <- connect_networks(handle, service, id),
         :ok <- stage_files(handle, service, id),
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
  # it. No drain here: a stack that never finished coming up has shipped
  # nothing worth waiting for.
  defp rollback(handle, reason) do
    _ = teardown(handle, @teardown_attempts)
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

  # Extra stack networks are always internal: they exist to connect services
  # to each other (a browser to its proxy) without a route anywhere. The only
  # way out of a stack stays the `-egress` bridge, reached by `egress: :allow`.
  defp create_service_networks(handle, networks) do
    each_ok(networks, fn network ->
      body = %{
        "Name" => network.full_name,
        "Driver" => "bridge",
        "Internal" => true,
        "Labels" => network_labels(handle, network.name)
      }

      case create_network(handle, body) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
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

  # A service's first membership is its create-time endpoint, the rest are
  # connected after create, and `egress: :allow` always adds the NAT bridge
  # last — posture comes from `egress`, never from a membership list.
  defp primary_network(handle, %{role: :forwarder}), do: handle.publish_network
  defp primary_network(handle, service), do: hd(memberships(handle, service))

  defp secondary_networks(handle, %{role: :forwarder}), do: [handle.sandbox_network]

  defp secondary_networks(handle, service) do
    tl(memberships(handle, service)) ++
      if service.egress == :allow, do: [handle.egress_network], else: []
  end

  defp memberships(handle, service) do
    Enum.map(Service.networks(service), &network_full_name(handle, &1))
  end

  defp network_full_name(handle, "sbx"), do: handle.sandbox_network
  defp network_full_name(handle, name), do: "#{handle.project}-#{name}"

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
    |> HostConfig.build(
      network_mode: primary_network(handle, service),
      overrides: service.host_config
    )
    |> maybe_put("Binds", presence(binds(handle, service)))
    |> maybe_put("PortBindings", port_bindings(handle, service))
  end

  defp binds(handle, service) do
    Enum.map(service.volumes, fn mount ->
      suffix = if mount.read_only, do: ":ro", else: ""
      "#{bind_source(handle.project, mount)}:#{mount.target}#{suffix}"
    end)
  end

  # A named volume is namespaced by the project, because the stack created it
  # and destroys it. A host path is the host's, and prefixing it would name a
  # directory that does not exist.
  defp bind_source(project, %{kind: :volume, source: name}), do: "#{project}-#{name}"
  defp bind_source(_project, %{kind: :host_path, source: path}), do: path

  defp start_container(handle, id) do
    case API.request(handle.config, :post, "/containers/#{id}/start") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- files ---

  # One `PUT /containers/{id}/archive` per destination root, between create and
  # start. The root is the writable mount a file lives under, else `/`: the
  # daemon refuses an archive into a read-only rootfs with 403 *unless* the
  # destination is inside a volume, and it must already exist — a mount target
  # does, an arbitrary directory may not. Intermediate directories inside the
  # root are created by the daemon from the tar entries.
  defp stage_files(_handle, %{files: []}, _id), do: :ok

  defp stage_files(handle, service, id) do
    service
    |> file_groups()
    |> each_ok(fn {root, files} ->
      case API.request(handle.config, :put, "/containers/#{id}/archive",
             params: [path: root],
             headers: [{"content-type", "application/x-tar"}],
             body: archive(root, files)
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp file_groups(service) do
    service.files
    |> Enum.group_by(&file_root(service, &1.path))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp file_root(service, path) do
    case covering_mount(service, path) do
      nil -> "/"
      mount -> mount.target
    end
  end

  # The deepest mount whose target contains `path`, so a file under a nested
  # mount lands in the inner one, which is where the container will see it.
  defp covering_mount(service, path) do
    service.volumes
    |> Enum.filter(&under?(path, &1.target))
    |> Enum.max_by(&byte_size(&1.target), fn -> nil end)
  end

  defp under?(path, dir), do: String.starts_with?(path, String.trim_trailing(dir, "/") <> "/")

  @doc false
  # An uncompressed tar of `files`, entry names relative to `root`, built in
  # memory by `:erl_tar` with each file's mode and owner. Public so the bytes
  # can be round-tripped in a test without a daemon.
  @spec archive(String.t(), [Service.file()]) :: binary()
  def archive(root, files) do
    {:ok, fd} = :file.open(<<>>, [:ram, :read, :write, :binary])

    try do
      {:ok, tar} = :erl_tar.init(fd, :write, &tar_io/2)

      Enum.each(files, fn file ->
        name = file.path |> Path.relative_to(root) |> String.to_charlist()
        opts = [mode: file.mode, uid: file.uid, gid: file.gid, mtime: 0]
        :ok = :erl_tar.add(tar, {name, file.content}, opts)
      end)

      :ok = :erl_tar.close(tar)
      {:ok, size} = :file.position(fd, :eof)
      # A RAM file opened `:binary` reads back a binary, never a charlist.
      case :file.pread(fd, 0, size) do
        {:ok, bytes} when is_binary(bytes) -> bytes
      end
    after
      :file.close(fd)
    end
  end

  # `:erl_tar.init/3`'s IO callback over a RAM file. `close` is a no-op because
  # the bytes are read back after the archive is closed; `archive/2` closes the
  # file itself.
  defp tar_io(:write, {fd, data}), do: :file.write(fd, data)
  defp tar_io(:position, {fd, position}), do: :file.position(fd, position)
  defp tar_io(:read2, {fd, size}), do: :file.read(fd, size)
  defp tar_io(:close, _fd), do: :ok

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

  # The first declared port; `port:` is its single-port spelling.
  defp proxy_port(services, name) do
    case Enum.find(services, &(&1.name == name)) do
      %{ports: [port | _]} -> port
      _ -> @default_proxy_port
    end
  end

  # Never persisted: `CrowdControl.Store.secret_keys/0` lists `:session_token`,
  # so it is stripped from `config` on the way to disk, and it is not a struct
  # field. The sandbox and the proxy both hold it; nothing else needs to
  # remember it.
  #
  # The `ccst_` prefix is what lets a log shipper find it: 32 random bytes have
  # no shape a redaction regex can match, and the sandbox prints its environment
  # into the transcript as readily as anything else.
  # `CrowdControl.Preset.LogShipper` redacts `ccst_` by default, which is why a
  # caller-supplied token must carry the prefix too (`validate_session_token/1`).
  defp mint_session_token do
    @session_token_prefix <>
      (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp validate_session_token(opts) do
    case opts[:session_token] do
      nil -> :ok
      @session_token_prefix <> _rest -> :ok
      _other -> {:error, {:compose, {:bad_session_token, :prefix}}}
    end
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

  # A drained service also carries its drain budget, so a handle `list_live/1`
  # rebuilt from labels alone still drains it before the force-remove.
  defp container_labels(handle, service) do
    base_labels(handle)
    |> Map.merge(%{
      @service_label => service.name,
      "com.docker.compose.container-number" => "1",
      "com.docker.compose.oneoff" => "False"
    })
    |> Map.merge(drain_labels(service))
  end

  defp drain_labels(%Service{drain: drain} = service) when is_integer(drain) do
    %{
      @drain_label => to_string(drain),
      @stop_timeout_label => to_string(Service.stop_timeout(service))
    }
  end

  defp drain_labels(_service), do: %{}

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
    case ready_spec(handle.config, service) do
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
    case ready_spec(handle.config, service) do
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
    drain(handle)
    teardown(handle, @teardown_attempts)
    :ok
  end

  # Services marked `drain:` (log shippers) get a graceful stop before the
  # force-remove, which would otherwise SIGKILL them mid-flush and lose the
  # transcript's tail. Wait the longest drain once — the shipper's file source
  # needs time to reach EOF after the session's last byte — then
  # `POST /stop?t=` each, giving it its graceful-shutdown limit plus a margin
  # before the daemon's SIGKILL. The sandbox and forwarder are not drained.
  #
  # Best effort by design: a stop that fails is logged and the force-remove
  # below still runs, because teardown must never leak a stack to save a log.
  defp drain(handle) do
    targets =
      for {service, drain_ms, timeout} <- Map.get(handle, :drained, []),
          {:ok, id} <- [container_id(handle, service)],
          do: {service, id, drain_ms, timeout}

    if targets != [] do
      targets |> Enum.map(&elem(&1, 2)) |> Enum.max() |> Process.sleep()
      Enum.each(targets, &stop_drained(handle, &1))
    end
  end

  # The request blocks until the container exits, up to `t`, so its receive
  # timeout must outlast `t` or a slow flush would read as a transport error.
  defp stop_drained(handle, {service, id, _drain_ms, timeout}) do
    case API.request(handle.config, :post, "/containers/#{id}/stop",
           params: [t: timeout],
           receive_timeout: (timeout + 10) * 1000
         ) do
      {:ok, _} -> :ok
      # 304: already stopped; 404: already gone. Both are the desired state.
      {:error, {:docker, {:http_status, 304, _}}} -> :ok
      {:error, {:docker, {:not_found, _}}} -> :ok
      {:error, reason} -> Logger.warning("compose drain of #{service} failed: #{inspect(reason)}")
    end
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

  # The three fixed names, unconditionally. A stack whose sidecars never asked
  # for egress has no `-egress` network and the DELETE 404s, which is success —
  # and a handle `list_live/1` rebuilt from container labels cannot know either
  # way, so guessing "it probably doesn't exist" is how one gets leaked. Extra
  # `:networks` come from the same two sources as volumes, below.
  defp networks(%__MODULE__{project: nil}), do: []

  defp networks(handle) do
    Enum.uniq(
      [handle.sandbox_network, handle.publish_network, handle.egress_network] ++
        Map.get(handle, :networks, []) ++ discovered(handle, "/networks")
    )
  end

  # Two sources, for two different handles. The persisted list is what an
  # acquire-path or rolled-back handle knows; the label query is the only thing
  # that works for a handle `list_live/1` rebuilt from container labels, which
  # would otherwise leak every named volume the reaper reaps.
  defp volumes(handle), do: Enum.uniq(handle.volumes ++ discovered(handle, "/volumes"))

  defp discovered(%__MODULE__{session_key: nil}, _path), do: []

  defp discovered(handle, path) do
    filters = JSON.encode!(%{"label" => ["crowd_control.session=#{handle.session_key}"]})

    case API.request(handle.config, :get, path, params: [filters: filters]) do
      # `GET /volumes` wraps its list; `GET /networks` is a bare array.
      {:ok, %{"Volumes" => items}} when is_list(items) -> Enum.map(items, & &1["Name"])
      {:ok, items} when is_list(items) -> Enum.map(items, & &1["Name"])
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
      drained: Enum.flat_map(containers, &drained_from_labels(labels(&1))),
      config: opts
    }
  end

  defp drained_from_labels(labels) do
    with service when is_binary(service) <- labels[@service_label],
         drain when is_integer(drain) <- parse_int(labels[@drain_label]),
         timeout when is_integer(timeout) <- parse_int(labels[@stop_timeout_label]) do
      [{service, drain, timeout}]
    else
      _ -> []
    end
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
    # `Store.scrub_opts/1` drops the top-level credential keys and strips `:env`
    # and `:files` from the `:services` specs: a service spec's `:env` is
    # exactly where a proxy's upstream key or a database password lives. Store
    # records are written to disk and outlive the VM, and reconnecting needs
    # none of it: every container already holds the environment it was started
    # with.
    %{handle | config: Store.scrub_opts(handle.config)}
  end

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

  # The fixed networks' compose-relative names. Declaring one again would alias
  # two memberships onto one network and, for `egress`, turn a membership list
  # into a posture.
  @reserved_networks ["sbx", "pub", "egress"]

  defp fetch_networks(opts, project) do
    with {:ok, specs} <- fetch_list(opts, :networks),
         {:ok, networks} <- collect(specs, &normalize_stack_network(&1, project)) do
      names = Enum.map(networks, & &1.name)

      case names -- Enum.uniq(names) do
        [] -> {:ok, networks}
        [dup | _] -> {:error, {:compose, {:bad_stack_network, %{name: dup}}}}
      end
    end
  end

  defp normalize_stack_network(spec, project) do
    with true <- is_map(spec),
         name when is_binary(name) <- Map.get(spec, :name),
         true <- name =~ ~r/^[a-z0-9][a-z0-9_-]*$/,
         false <- name in @reserved_networks do
      {:ok, %{name: name, full_name: "#{project}-#{name}"}}
    else
      _ -> {:error, {:compose, {:bad_stack_network, spec}}}
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

  # The shape rules live in `CrowdControl.Service`, shared with Kubernetes, so
  # the two substrates cannot drift on what a service is. Its bare reasons get
  # Compose's tag here, which keeps every error shape this module has always
  # returned.
  defp normalize_specs(specs, sandbox) do
    collect(specs, fn spec ->
      role = if spec_name(spec) == sandbox, do: :sandbox, else: :sidecar

      case Service.normalize(spec, role) do
        # An `{:external, _}` placement needs no image on Kubernetes, where it
        # creates nothing. Here every service is a container, and placement is
        # ignored, so an image-less one is the same mistake it always was.
        {:ok, %Service{image: nil, role: :sidecar, name: name}} ->
          {:error, {:compose, {:image_required, name}}}

        {:ok, service} ->
          {:ok, service}

        {:error, reason} ->
          {:error, {:compose, reason}}
      end
    end)
  end

  defp build_sandbox(opts, declared, sandbox) do
    case Enum.find(declared, &(&1.name == sandbox)) do
      nil ->
        with {:ok, image} <- fetch_image(opts) do
          {:ok, %Service{name: sandbox, image: image, role: :sandbox, user: opts[:user]}}
        end

      %{image: nil} = spec ->
        with {:ok, image} <- fetch_image(opts), do: {:ok, %{spec | image: image}}

      spec ->
        {:ok, spec}
    end
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

    %Service{
      name: forwarder,
      image: opts[:forwarder_image] || @default_forwarder_image,
      role: :forwarder,
      entrypoint: ["socat"],
      command: ["TCP-LISTEN:#{port},fork,reuseaddr", "TCP:#{sandbox}:#{port}"],
      depends_on: [sandbox]
    }
  end

  # --- cross-service validation ---

  defp validate_mounts(services, volumes) do
    declared = MapSet.new(volumes, & &1.name)

    each_ok(services, fn service ->
      # A host path has nothing to declare; only a named volume must exist in
      # the stack, because the stack is what creates and destroys it.
      undeclared =
        Enum.find(service.volumes, fn mount ->
          mount.kind == :volume and not MapSet.member?(declared, mount.source)
        end)

      case undeclared do
        nil -> :ok
        mount -> {:error, {:compose, {:unknown_volume, mount.source}}}
      end
    end)
  end

  # Membership names must be `sbx` or a declared `:networks` entry, and the
  # sandbox must stay on `sbx`, the network the forwarder reaches it across.
  defp validate_memberships(opts, services, networks) do
    declared = ["sbx" | Enum.map(networks, & &1.name)]
    members = Enum.reject(services, &(&1.role == :forwarder))

    with :ok <- each_ok(members, &known_networks(&1, declared)),
         :ok <- sandbox_on_sbx(members) do
      sandbox_isolated(opts, members, networks)
    end
  end

  defp known_networks(service, declared) do
    case Enum.find(Service.networks(service), &(&1 not in declared)) do
      nil -> :ok
      network -> {:error, {:compose, {:unknown_network, {service.name, network}}}}
    end
  end

  defp sandbox_on_sbx(services) do
    sandbox = Enum.find(services, &(&1.role == :sandbox))

    if "sbx" in Service.networks(sandbox),
      do: :ok,
      else: {:error, {:compose, {:sandbox_needs_network, "sbx"}}}
  end

  # Invariant 1: the sandbox never gets egress, so it may share no network with
  # an `egress: :allow` service — anything on both could relay the internet in.
  # The one sanctioned relay is `:proxy_service`, whose SECURITY.md contract
  # (credential substitution, upstream API only) is the reason it exists.
  #
  # Enforced once a stack opts into per-service networks (a `:networks`
  # declaration or any `networks:` membership). A stack using neither keeps
  # the single-network shape this module has always built, where an `:allow`
  # sidecar on `sbx` is the documented, typed-out relay.
  defp sandbox_isolated(opts, services, networks) do
    if per_service_networks?(services, networks) do
      sandbox = Enum.find(services, &(&1.role == :sandbox))

      relays =
        Enum.filter(services, &(&1.egress == :allow and &1.name != opts[:proxy_service]))

      shared =
        for network <- Service.networks(sandbox),
            relay <- relays,
            network in Service.networks(relay),
            do: {network, relay.name}

      case shared do
        [] ->
          :ok

        [{network, service} | _] ->
          {:error, {:compose, {:sandbox_shares_network_with_egress, {service, network}}}}
      end
    else
      :ok
    end
  end

  defp per_service_networks?(services, networks) do
    networks != [] or Enum.any?(services, &(&1.networks != nil))
  end

  # Decided against the HostConfig the container will actually get, so the
  # rule cannot drift from the rendering: the daemon answers 403 for an archive
  # into a read-only rootfs unless the destination is inside a volume, a file
  # under a read-only mount cannot be written at all, and one under a tmpfs is
  # written to the layer *beneath* the tmpfs and is invisible once it mounts.
  defp validate_files(opts, services) do
    each_ok(services, fn service ->
      host = HostConfig.build(opts, network_mode: "none", overrides: service.host_config)
      readonly? = host["ReadonlyRootfs"] == true
      tmpfs = Map.keys(host["Tmpfs"] || %{})

      case Enum.find(service.files, &(not writable?(service, &1.path, readonly?, tmpfs))) do
        nil -> :ok
        file -> {:error, {:compose, {:files_not_writable, {service.name, file.path}}}}
      end
    end)
  end

  defp writable?(service, path, readonly?, tmpfs) do
    not Enum.any?(tmpfs, &under?(path, &1)) and
      case covering_mount(service, path) do
        nil -> not readonly?
        mount -> not mount.read_only
      end
  end

  # Invariant 6: the capture file is never written by a sidecar. The capture
  # source is whatever the sandbox mounts over the capture file (a named
  # volume or a host path); every other mount of that source must be
  # read-only, and no service may stage files into it. With no such mount the
  # capture lives in the sandbox's own filesystem, out of every sidecar's
  # reach, and only the sandbox's own `:files` could pre-seed it.
  defp validate_capture(opts, services) do
    capture_path = opts[:capture_path] || @default_capture
    sandbox = Enum.find(services, &(&1.role == :sandbox))

    case covering_mount(sandbox, capture_path) do
      nil ->
        capture_dir = Path.dirname(capture_path)

        if Enum.any?(sandbox.files, &under?(&1.path, capture_dir)),
          do: {:error, {:compose, {:capture_mount_writable, sandbox.name}}},
          else: :ok

      capture ->
        each_ok(services, &capture_untouched(&1, sandbox, capture))
    end
  end

  defp capture_untouched(service, sandbox, capture) do
    writable_mount? =
      service.name != sandbox.name and
        Enum.any?(service.volumes, &(same_source?(&1, capture) and not &1.read_only))

    staged? =
      Enum.any?(service.files, fn file ->
        case covering_mount(service, file.path) do
          nil -> false
          mount -> same_source?(mount, capture)
        end
      end)

    if writable_mount? or staged?,
      do: {:error, {:compose, {:capture_mount_writable, service.name}}},
      else: :ok
  end

  defp same_source?(mount, capture),
    do: {mount.kind, mount.source} == {capture.kind, capture.source}

  # Docker's embedded DNS on internal networks forwarded queries upstream —
  # an exfiltration path out of a network with no route — until 25.0.5 /
  # 26.0.0 (CVE-2024-29018). Only the stacks that lean on internal networks
  # for isolation alongside a NAT bridge pay the `/version` round trip.
  defp ensure_versions(opts, services, networks) do
    features =
      if(per_service_networks?(services, networks), do: [:service_networks], else: []) ++
        if Enum.any?(services, &(&1.egress == :allow)), do: [:egress_sidecars], else: []

    case VersionGate.components(features) do
      [] ->
        :ok

      _components ->
        with {:ok, version} <- API.server_version(opts) do
          VersionGate.check(features, %{docker: version})
        end
    end
  end

  defp warn_placement(services) do
    for %{placement: placement, name: name} <- services, placement != nil do
      Logger.warning(
        "compose: service #{name} sets placement: #{inspect(placement)}, " <>
          "which is Kubernetes-only and ignored here"
      )
    end

    :ok
  end

  defp drained_specs(services) do
    for service <- services, Service.drained?(service) do
      {service.name, service.drain, Service.stop_timeout(service)}
    end
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

  # Normalized in one place so `healthcheck/2` is a pure translation. The
  # stack-level `:ready` entry wins; a service's own `ready:` is used when it
  # carries a Docker `:test` (a `:tcp_port`-only spec is Kubernetes readiness,
  # which Compose cannot express without a probe binary in the image).
  defp ready_spec(config, service) do
    case config |> Keyword.get(:ready, %{}) |> Map.get(service.name) || service_ready(service) do
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

  defp service_ready(%{ready: %{test: _} = ready}), do: ready
  defp service_ready(_service), do: nil

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
