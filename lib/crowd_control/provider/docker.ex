defmodule CrowdControl.Provider.Docker do
  @moduledoc """
  One container per sandbox, running `sandboxd`, reached on a loopback-published
  port.

  Requires the optional `:req` dependency and an image containing the `sandboxd`
  release. Unlike `CrowdControl.Backend.Docker`, which works with any image that
  has `sh` and `tail`, this provider needs our agent inside the container.

  ## Network posture, and why it is not isolation

  **This provider does not block egress, and it must not be described as
  though it does.** That is a measured constraint of the Docker bridge driver,
  not an oversight:

  > On one container, `Internal: true` and a published port are mutually
  > exclusive. Publishing requires at least one *non-internal* endpoint, and
  > attaching one restores full internet egress.

  Confirmed six independent ways (internal-only; `NetworkMode: "none"`; two
  internal networks; `Internal` combined with each of the four
  `gateway_mode_ipv4` values; publish-then-disconnect). Worse, the failure is
  silent: `POST /containers/create` answers `201` with `"Warnings": []` and
  `HostConfig.PortBindings` echoes the request verbatim, while
  `NetworkSettings.Ports` quietly reads `{"8080/tcp": null}`.

  So `:egress` is **required** and has no default, exactly as
  `CrowdControl.Backend.Docker` requires an explicit `:network_mode`. A silent
  default here would hand model-driven code general outbound access in the one
  scenario `SECURITY.md` warns about:

    * `egress: :allow` — a private per-sandbox bridge. Full outbound access.
      Correct when the sandbox is *supposed* to reach an API, and honest about it.
    * `egress: :no_nat` — the same bridge with
      `com.docker.network.bridge.enable_ip_masquerade=false`. The internet
      becomes unreachable because return traffic has no SNAT, but **the Docker
      host, every container on every other Docker network, and Docker's
      embedded DNS all stay reachable**. It is "no NAT", not "dropped". On a
      network whose router knows a path back to the container subnet, egress is
      not guaranteed to fail at all.

  For a strong, structural egress block *and* a reachable agent, use
  `CrowdControl.Provider.Compose`: an internal-only sandbox plus a dual-homed
  forwarder is the only shape that delivers both, and it needs a second
  container to do it.

  ## Options

    * `:image` — image containing the `sandboxd` release (required)
    * `:egress` — `:allow` or `:no_nat` (required; see above)
    * `:agent_port` — the port `sandboxd` listens on inside the container,
      default `8080`
    * `:capture_path` — default `/var/log/cc/out.jsonl`
    * `:ready_timeout` — how long `acquire/1` waits for `GET /v1/health`,
      default `30_000`
    * `:docker_host`, `:timeout` — as `CrowdControl.Backend.Docker.API`
    * `:cpus`, `:memory`, `:cap_drop`, `:security_opt`, `:pids_limit`, `:user`,
      `:readonly_rootfs`, `:tmpfs` — hardening, shared verbatim with
      `CrowdControl.Backend.Docker` through
      `CrowdControl.Backend.Docker.HostConfig`
    * `:agent_env` — extra environment for the *agent process itself*, not the
      CLI. The CLI's env goes through `c:CrowdControl.Backend.exec/4`, in a
      request body.
    * `:req_adapter` — test seam, threaded into the endpoint's `Req` options

  ## The published port is never persisted

  Every `stop`/`start`/`restart` allocates a **new** ephemeral host port, and
  while a container is stopped `NetworkSettings.Ports` is `{}` rather than
  reporting the old one. `reconnect/1` therefore always re-reads it. This is
  measured behaviour, not caution.
  """

  @behaviour CrowdControl.Provider

  @compile {:no_warn_undefined, Req}

  require Logger

  alias CrowdControl.Backend.Docker.API
  alias CrowdControl.Backend.Docker.HostConfig
  alias CrowdControl.Backend.Sandboxd.API, as: AgentAPI
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Endpoint
  alias CrowdControl.Store

  @default_agent_port 8080
  @default_capture "/var/log/cc/out.jsonl"
  @default_ready_timeout 30_000

  defstruct [
    :container_id,
    :network_name,
    :image,
    :session_key,
    :owner,
    agent_port: @default_agent_port,
    capture_path: @default_capture,
    config: []
  ]

  @type t :: %__MODULE__{
          container_id: String.t() | nil,
          network_name: String.t() | nil,
          image: String.t() | nil,
          session_key: String.t() | nil,
          owner: String.t() | nil,
          agent_port: pos_integer(),
          capture_path: String.t(),
          config: keyword()
        }

  # --- acquire ---

  @impl true
  def acquire(opts) do
    with :ok <- ensure_req!(),
         {:ok, image} <- fetch_image(opts),
         {:ok, egress} <- fetch_egress(opts),
         {:ok, session_key} <- fetch_session_key(opts) do
      handle = %__MODULE__{
        image: image,
        session_key: session_key,
        owner: opts[:owner] || Store.owner_id(),
        agent_port: opts[:agent_port] || @default_agent_port,
        capture_path: opts[:capture_path] || @default_capture,
        network_name: network_name(session_key),
        config: opts
      }

      start(handle, egress)
    end
  end

  # Deliberately not one `with` chain with an `else`. An `else` branch cannot
  # see rebindings made in the body, so `handle` there would still carry
  # `container_id: nil` and the rollback would delete the network while leaking
  # the container — silently, since release/1 returns :ok either way. Each step
  # therefore hands the *updated* handle to the next, and rollback is called
  # from the scope that knows what exists.
  defp start(handle, egress) do
    case create_network(handle, egress) do
      {:ok, _} -> create_and_start(handle)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_and_start(handle) do
    case create_container(handle) do
      {:ok, id} -> start_and_verify(%{handle | container_id: id})
      {:error, reason} -> rollback(handle, reason)
    end
  end

  defp start_and_verify(handle) do
    case start_container(handle) do
      :ok -> verify_health(handle)
      {:error, reason} -> rollback(handle, reason)
    end
  end

  defp verify_health(handle) do
    case await_endpoint(handle) do
      {:ok, endpoint} -> {:ok, handle, endpoint}
      {:error, reason} -> rollback(handle, reason)
    end
  end

  # Unconditional, not best-effort-on-some-paths: a leaked container is untidy
  # here and expensive on a billed substrate, and the same shape is what keeps
  # Provider.Gce from leaking a spot VM.
  defp rollback(handle, reason) do
    _ = release(handle)
    {:error, reason}
  end

  defp create_network(handle, egress) do
    body =
      %{
        "Name" => handle.network_name,
        "Driver" => "bridge",
        "Labels" => labels(handle)
      }
      |> put_egress_options(egress)

    case API.request(handle.config, :post, "/networks/create", json: body) do
      {:ok, response} -> {:ok, response}
      # A network left behind by a crashed run is reusable: same name, same
      # labels, same posture, and release/1 removes it either way.
      {:error, {:docker, {:http_status, 409, _}}} -> {:ok, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  # enable_ip_masquerade=false is the entire :no_nat mechanism, and its limits
  # are documented in the moduledoc rather than implied by the option name.
  defp put_egress_options(body, :allow), do: body

  defp put_egress_options(body, :no_nat) do
    Map.put(body, "Options", %{"com.docker.network.bridge.enable_ip_masquerade" => "false"})
  end

  defp create_container(handle) do
    port_key = "#{handle.agent_port}/tcp"

    body =
      %{
        "Image" => handle.image,
        "ExposedPorts" => %{port_key => %{}},
        "Env" => agent_env(handle),
        "Labels" => labels(handle),
        "HostConfig" =>
          handle.config
          |> HostConfig.build(network_mode: handle.network_name)
          |> Map.put("PortBindings", %{
            # HostIp is mandatory, not cosmetic: omitting it yields TWO
            # bindings (IPv4 + IPv6) bound to every interface, which publishes
            # the agent port to the network rather than to the host.
            port_key => [%{"HostIp" => "127.0.0.1", "HostPort" => "0"}]
          }),
        "NetworkingConfig" => %{"EndpointsConfig" => %{handle.network_name => %{}}}
      }
      |> maybe_put("User", handle.config[:user])

    case API.request(handle.config, :post, "/containers/create",
           params: [name: handle.network_name],
           json: body
         ) do
      {:ok, %{"Id" => id}} -> {:ok, id}
      {:ok, other} -> {:error, {:docker, {:unexpected_create_response, other}}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The agent's own configuration, through the create API's first-class Env
  # array. The token is a credential and never enters argv, a label, or a log
  # line. CC_SANDBOXD_BIND must be 0.0.0.0 here: a published port is forwarded
  # from *outside* the container, so an agent bound to the container's own
  # loopback would never receive it. Non-routability is the network's job, and
  # the binding is loopback-only on the host side.
  defp agent_env(handle) do
    base = [
      {"CC_SANDBOXD_TOKEN", Provider.token(handle.session_key)},
      {"CC_SANDBOXD_PORT", to_string(handle.agent_port)},
      {"CC_SANDBOXD_BIND", "0.0.0.0"},
      {"CC_SANDBOXD_CAPTURE", handle.capture_path}
    ]

    extra = handle.config[:agent_env] || %{}

    (base ++ Enum.map(extra, fn {k, v} -> {to_string(k), to_string(v)} end))
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
  end

  defp labels(handle) do
    %{
      "crowd_control.session" => to_string(handle.session_key),
      "crowd_control.owner" => handle.owner,
      "crowd_control.created_at" => to_string(System.system_time(:millisecond)),
      "crowd_control.agent" => "sandboxd",
      # A positive discriminator, because Docker label filters cannot express
      # label *absence*. Provider.Compose also labels its containers
      # `crowd_control.agent=sandboxd`, so a deployment configuring both
      # providers against one daemon would otherwise have this provider's
      # list_live/1 return compose stack containers — and the reaper would
      # destroy a stack one container at a time, leaving its networks and
      # volumes behind.
      "crowd_control.stack" => "single"
    }
  end

  defp start_container(handle) do
    case API.request(handle.config, :post, "/containers/#{handle.container_id}/start") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- reconnect ---

  @impl true
  def reconnect(%__MODULE__{container_id: nil}), do: {:error, {:docker, :not_provisioned}}

  def reconnect(%__MODULE__{} = handle) do
    with {:ok, endpoint} <- await_endpoint(handle) do
      {:ok, handle, endpoint}
    end
  end

  defp await_endpoint(handle) do
    with {:ok, host_port} <- read_host_port(handle),
         endpoint = endpoint(handle, host_port),
         :ok <- AgentAPI.await_health(endpoint, ready_timeout(handle)) do
      {:ok, endpoint}
    end
  end

  defp endpoint(handle, host_port) do
    %Endpoint{
      base_url: "http://127.0.0.1:#{host_port}",
      token: Provider.token(handle.session_key),
      req_options: req_options(handle)
    }
  end

  defp req_options(handle) do
    case handle.config[:req_adapter] do
      nil -> []
      adapter -> [adapter: adapter]
    end
  end

  @doc """
  Read the host port Docker assigned to the agent port.

  `NetworkSettings.Ports` is the **only** source of truth. Four failure shapes
  were all observed against a live daemon and all of them mean "there is no
  usable port", so each is an error rather than something to work around:

    * the key is present with a `null` value — the binding was discarded
      because the network is internal;
    * `HostPort` is `""` — `gateway_mode_ipv4: "routed"` reports a binding it
      did not make;
    * `Ports` is `{}` — the container is not running;
    * the key is absent — `ExposedPorts` was never set.

  Public and `@doc false`-adjacent so the parsing is testable without a daemon.
  """
  @spec host_port_from_inspect(map(), pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def host_port_from_inspect(container_json, agent_port) do
    ports = get_in(container_json, ["NetworkSettings", "Ports"]) || %{}

    case Map.get(ports, "#{agent_port}/tcp") do
      [%{"HostPort" => port} | _] when is_binary(port) and port != "" ->
        case Integer.parse(port) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, {:docker, {:bad_host_port, port}}}
        end

      _ ->
        {:error, {:docker, :agent_port_not_published}}
    end
  end

  defp read_host_port(handle) do
    case API.request(handle.config, :get, "/containers/#{handle.container_id}/json") do
      {:ok, json} -> host_port_from_inspect(json, handle.agent_port)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ready_timeout(handle), do: handle.config[:ready_timeout] || @default_ready_timeout

  # --- release ---

  @impl true
  def release(%__MODULE__{} = handle) do
    # Container first: a network DELETE fails with 403 while a container is
    # still attached to it.
    delete_container(handle)
    delete_network(handle)
    :ok
  end

  defp delete_container(%__MODULE__{container_id: nil}), do: :ok

  defp delete_container(%__MODULE__{container_id: id} = handle) do
    case API.request(handle.config, :delete, "/containers/#{id}", params: [force: true, v: true]) do
      {:ok, _} ->
        :ok

      # Already gone is the desired end state, which is what makes release/1
      # idempotent across the several teardown paths Session calls it from.
      {:error, {:docker, {:not_found, _}}} ->
        :ok

      {:error, reason} ->
        Logger.warning("sandboxd container destroy failed for #{short(id)}: #{inspect(reason)}")
        :ok
    end
  end

  defp delete_network(%__MODULE__{network_name: nil}), do: :ok

  defp delete_network(%__MODULE__{network_name: name} = handle) do
    case API.request(handle.config, :delete, "/networks/#{name}") do
      {:ok, _} -> :ok
      {:error, {:docker, {:not_found, _}}} -> :ok
      {:error, reason} -> Logger.warning("sandboxd network destroy failed: #{inspect(reason)}")
    end

    :ok
  end

  # --- list_live / age_ms / scrub ---

  @impl true
  def list_live(opts) do
    owner = opts[:owner] || Store.owner_id()

    # Three scopes, each preventing a distinct way of destroying the wrong thing:
    # owner, or one node's reaper reaps another node's sandboxes; agent, or it
    # also picks up Backend.Docker's FIFO containers, which this provider cannot
    # drive; stack, or it picks up Provider.Compose's containers and tears a
    # stack apart one container at a time, orphaning its networks and volumes.
    filters =
      JSON.encode!(%{
        "label" => [
          "crowd_control.owner=#{owner}",
          "crowd_control.agent=sandboxd",
          "crowd_control.stack=single"
        ]
      })

    case API.request(opts, :get, "/containers/json", params: [filters: filters, all: false]) do
      {:ok, containers} when is_list(containers) ->
        {:ok, Enum.map(containers, &handle_from_container(&1, opts, owner))}

      {:ok, other} ->
        {:error, {:docker, {:unexpected_list_response, other}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_from_container(container, opts, owner) do
    labels = Map.get(container, "Labels") || %{}
    session_key = labels["crowd_control.session"]

    %__MODULE__{
      container_id: container["Id"],
      network_name: session_key && network_name(session_key),
      image: container["Image"],
      session_key: session_key,
      owner: labels["crowd_control.owner"] || owner,
      agent_port: opts[:agent_port] || @default_agent_port,
      capture_path: opts[:capture_path] || @default_capture,
      config: opts
    }
  end

  @impl true
  def age_ms(%__MODULE__{container_id: nil}), do: nil

  def age_ms(%__MODULE__{} = handle) do
    case API.request(handle.config, :get, "/containers/#{handle.container_id}/json") do
      {:ok, %{"Config" => %{"Labels" => %{"crowd_control.created_at" => created}}}} ->
        case Integer.parse(created) do
          {ms, ""} -> max(System.system_time(:millisecond) - ms, 0)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def scrub(%__MODULE__{} = handle) do
    # The handle carries the opts it was acquired with, which can include
    # :api_key, :session_token and :env. Store records are written to disk and
    # outlive the VM, and reconnecting needs none of it — the container already
    # holds the environment it was started with.
    %{handle | config: Store.scrub_opts(handle.config)}
  end

  # --- Private ---

  # Deterministic from the session key, so a crashed run's network is found and
  # cleaned rather than orphaned under a random name. Store.new_key/0 is 32 hex
  # characters, which is label- and DNS-safe.
  defp network_name(session_key), do: "cc-sbx-#{session_key}"

  defp fetch_image(opts) do
    case opts[:image] do
      image when is_binary(image) and image != "" -> {:ok, image}
      _ -> {:error, {:docker, :image_required}}
    end
  end

  defp fetch_session_key(opts) do
    case opts[:session_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:docker, :session_key_required}}
    end
  end

  # Never inferred. See the moduledoc: this provider cannot block egress and
  # publish the agent port at the same time, so the caller states which
  # trade-off they are taking rather than discovering it from a packet capture.
  defp fetch_egress(opts) do
    case opts[:egress] do
      egress when egress in [:allow, :no_nat] -> {:ok, egress}
      nil -> {:error, {:docker, :egress_required}}
      other -> {:error, {:docker, {:bad_egress, other}}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp short(id), do: String.slice(id, 0, 12)

  defp ensure_req! do
    if Code.ensure_loaded?(Req) do
      :ok
    else
      raise """
      CrowdControl.Provider.Docker requires the optional :req dependency.

      Add it to your deps:

          {:req, "~> 0.5"}
      """
    end
  end
end
