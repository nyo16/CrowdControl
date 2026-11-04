defmodule CrowdControl.Service do
  @moduledoc """
  One validated service spec — a sidecar, or the sandbox itself — shared by
  every substrate that runs more than one container per session.

  `CrowdControl.Provider.Compose` and `CrowdControl.Backend.Kubernetes` both
  accept the same plain map, so a service written for one substrate reads the
  same on the other:

      %{
        name: "proxy",                      # required, unique, DNS-safe
        image: "cc/egress-proxy:1.2.3",     # required (the sandbox may inherit :image)
        egress: :allow,                     # required for sidecars, see below
        entrypoint: ["/proxy"],
        command: ["--listen", ":8080"],
        env: %{"LOG_LEVEL" => "info"},
        volumes: [%{name: "cache", target: "/cache"}],   # see `CrowdControl.Volume`
        files: [%{path: "/cfg/acl.yaml", content: "...", mode: 0o444}],
        depends_on: ["db"],
        user: "1000:1000",
        ports: [8080],
        ready: %{test: ["CMD", "nc", "-z", "127.0.0.1", "8080"], tcp_port: 8080},
        host_config: %{shm_size: 1_073_741_824, init: true},
        weaken: [],
        networks: ["sbx", "brw"],
        placement: :separate,               # Kubernetes only; see below
        drain: 3_000,                       # ms; log shippers only
        shutdown_limit: 20                  # s; with :drain
      }

  `normalize/2` is pure and returns either a `%CrowdControl.Service{}` or a bare
  reason. Each substrate wraps the reason in its own tag (`{:compose, reason}`,
  `{:k8s, reason}`), so `{:egress_required, name}` and
  `:sandbox_egress_forbidden` read the same everywhere.

  `:placement` is read by `CrowdControl.Backend.Kubernetes` only: `:pod` (a
  native sidecar in the sandbox Pod), `:separate` (its own Pod, Service and
  NetworkPolicy) or `{:external, target}` (something outside the session the
  session may reach; it runs nothing, so it needs no `:image`).

  ## Posture is never inferred

    * `:egress` is required on every sidecar, with no default. The sandbox can
      never carry `:allow`.
    * Keys that *weaken* the hardened defaults must each be named in `:weaken`,
      or the spec is refused with `{:weakening_not_declared, {name, key}}`:
        * `:cap_add` — a non-empty `host_config.cap_add`;
        * `:no_new_privileges` — `host_config.no_new_privileges: false`;
        * `:readonly_rootfs` — `host_config.readonly_rootfs: false`;
        * `:user` — a root `:user` (see `root_user?/1`);
        * `:host_path` — a `kind: :host_path` mount on a sidecar, read-only or
          not: it hands the container part of the host filesystem;
        * `:tmpfs_exec` — a `host_config.tmpfs` entry whose options leave out
          `noexec` or `nosuid` (or name `exec`/`suid`).
      Resource keys (`:shm_size`, `:init`, `:pids_limit`, `:memory`, `:cpus`,
      `:tmpfs` with `noexec,nosuid`) need no declaration.
    * `privileged` is refused outright, declared or not.

  ## `:files` is for configuration, never credentials

  Files are staged into the container before it starts (a tar upload on
  Compose, a per-session ConfigMap on Kubernetes). A ConfigMap is readable by
  anyone with `get` on the namespace, so credentials go through `:env` on
  both substrates: set on the container on Compose, and on Kubernetes kept in
  a per-session Secret the container reads by `secretKeyRef`
  (`CrowdControl.Backend.Kubernetes.Secrets`). Nothing scans the content:
  pattern matching would give false confidence, so the rule is documented
  rather than enforced.

  Each file is `%{path: abs_path, content: binary}` plus optional `:mode`
  (`0..0o777`, default `0o644`; no setuid, setgid or sticky bits), `:uid` and
  `:gid` (default `0`). Paths are absolute, carry no `.`/`..` segments, are
  unique, and all content together is at most 1 MiB.
  Kubernetes cannot set per-file ownership; `:uid`/`:gid` are Compose-only.
  """

  alias CrowdControl.Volume

  @max_files_bytes 1_048_576
  # Upstream's NameTotalLengthMax: the domain and path, tag and digest excluded.
  @max_image_name 255
  @default_file_mode 0o644
  @default_shutdown_limit 20

  # Seconds of headroom past the shipper's own graceful-shutdown limit, so it
  # exits on its own terms before SIGKILL. Shared by the Compose stop timeout
  # and the Kubernetes grace period so the two substrates drain alike.
  @drain_margin 5

  @resource_keys [:shm_size, :init, :pids_limit, :memory, :cpus, :tmpfs]
  @weakening_keys [
    :cap_add,
    :no_new_privileges,
    :readonly_rootfs,
    :user,
    :host_path,
    :tmpfs_exec
  ]

  defstruct [
    :name,
    :image,
    :role,
    egress: :none,
    entrypoint: nil,
    command: nil,
    env: %{},
    volumes: [],
    files: [],
    depends_on: [],
    user: nil,
    ports: [],
    ready: nil,
    host_config: %{},
    weaken: [],
    networks: nil,
    placement: nil,
    drain: nil,
    shutdown_limit: nil
  ]

  @type role :: :sandbox | :sidecar | :forwarder
  @type placement :: :pod | :separate | {:external, term()} | nil

  @type file :: %{
          path: String.t(),
          content: binary(),
          mode: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          image: String.t() | nil,
          role: role(),
          egress: :none | :allow,
          entrypoint: [String.t()] | nil,
          command: [String.t()] | nil,
          env: %{String.t() => String.t()},
          volumes: [Volume.normalized()],
          files: [file()],
          depends_on: [String.t()],
          user: String.t() | nil,
          ports: [pos_integer()],
          ready: map() | nil,
          host_config: map(),
          weaken: [atom()],
          networks: [String.t()] | nil,
          placement: placement(),
          drain: non_neg_integer() | nil,
          shutdown_limit: pos_integer() | nil
        }

  @doc """
  Validate a raw spec map into a `%CrowdControl.Service{}`.

  `role` is `:sandbox` for the spec that *is* the sandbox (its `:image` may be
  `nil`, for the caller to fill from a top-level option, and it may never have
  egress) and `:sidecar` for everything else.

      iex> {:ok, svc} = CrowdControl.Service.normalize(%{name: "db", image: "pg:16", egress: :none}, :sidecar)
      iex> {svc.name, svc.egress, svc.networks}
      {"db", :none, nil}

      iex> CrowdControl.Service.normalize(%{name: "db", image: "pg:16"}, :sidecar)
      {:error, {:egress_required, "db"}}
  """
  @spec normalize(term(), :sandbox | :sidecar) :: {:ok, t()} | {:error, term()}
  def normalize(spec, role) when is_map(spec) and role in [:sandbox, :sidecar] do
    with {:ok, name} <- fetch_name(spec),
         {:ok, image} <- fetch_image(spec, name, role),
         {:ok, egress} <- fetch_egress(spec, name, role),
         {:ok, entrypoint} <- strings(spec, :entrypoint, name),
         {:ok, command} <- strings(spec, :command, name),
         {:ok, depends_on} <- strings(spec, :depends_on, name),
         {:ok, env} <- fetch_env(spec, name),
         {:ok, volumes} <- fetch_volumes(spec, name),
         {:ok, files} <- validate_files(Map.get(spec, :files, []), name),
         {:ok, user} <- fetch_user(spec, name),
         {:ok, ports} <- fetch_ports(spec, name),
         {:ok, ready} <- fetch_ready(spec, name),
         {:ok, weaken} <- fetch_weaken(spec, name),
         {:ok, host_config} <- fetch_host_config(spec, name),
         :ok <- check_weakenings(name, weakenings(host_config, user, volumes, role), weaken),
         {:ok, networks} <- fetch_networks(spec, name),
         {:ok, placement} <- fetch_placement(spec, name),
         {:ok, drain, shutdown_limit} <- fetch_drain(spec, name) do
      {:ok,
       %__MODULE__{
         name: name,
         image: image,
         role: role,
         egress: egress,
         entrypoint: entrypoint,
         command: command,
         env: env,
         volumes: volumes,
         files: files,
         depends_on: depends_on || [],
         user: user,
         ports: ports,
         ready: ready,
         host_config: host_config,
         weaken: weaken,
         networks: networks,
         placement: placement,
         drain: drain,
         shutdown_limit: shutdown_limit
       }}
    end
  end

  # Maps only, deliberately: `CrowdControl.Store.scrub_services/1` strips `:env`
  # and `:files` out of the persisted specs without a second normalisation pass
  # over a shape it can only guess at.
  def normalize(spec, _role), do: {:error, {:bad_service, spec}}

  @doc """
  Validate a `:files` list on its own: absolute, `..`-free, unique paths and at
  most 1 MiB of content in total. Returns the files with defaults filled in.

      iex> CrowdControl.Service.validate_files([%{path: "/cfg/a.yaml", content: "x: 1"}], "svc")
      {:ok, [%{path: "/cfg/a.yaml", content: "x: 1", mode: 0o644, uid: 0, gid: 0}]}

      iex> CrowdControl.Service.validate_files([%{path: "cfg/a.yaml", content: ""}], "svc")
      {:error, {:bad_file, {"svc", "cfg/a.yaml"}}}
  """
  @spec validate_files(term(), String.t()) :: {:ok, [file()]} | {:error, term()}
  def validate_files(files, name) when is_list(files) do
    with {:ok, normalized} <- collect(files, &normalize_file(&1, name)),
         :ok <- unique_paths(normalized, name),
         :ok <- files_size(normalized, name) do
      {:ok, normalized}
    end
  end

  def validate_files(_files, name), do: bad(name, :files)

  @doc "Every membership name, defaulting to `[\"sbx\"]` when none was declared."
  @spec networks(t()) :: [String.t()]
  def networks(%__MODULE__{networks: nil}), do: ["sbx"]
  def networks(%__MODULE__{networks: networks}), do: networks

  @doc "True when the service asked to be drained before teardown."
  @spec drained?(t()) :: boolean()
  def drained?(%__MODULE__{drain: drain}), do: is_integer(drain)

  @doc """
  Seconds a drained service is given between SIGTERM and SIGKILL: its own
  graceful-shutdown limit plus a fixed margin, so it exits on its own terms.

      iex> CrowdControl.Service.stop_timeout(%CrowdControl.Service{drain: 3_000, shutdown_limit: 20})
      25
  """
  @spec stop_timeout(t()) :: pos_integer()
  def stop_timeout(%__MODULE__{shutdown_limit: limit}) when is_integer(limit),
    do: limit + @drain_margin

  def stop_timeout(%__MODULE__{}), do: @default_shutdown_limit + @drain_margin

  @doc "The drain wait in whole seconds, rounded up (Kubernetes `preStop.sleep` granularity)."
  @spec drain_seconds(t()) :: non_neg_integer()
  def drain_seconds(%__MODULE__{drain: ms}) when is_integer(ms), do: div(ms + 999, 1000)
  def drain_seconds(%__MODULE__{}), do: 0

  @doc "The HostConfig keys that never need a `:weaken` declaration."
  @spec resource_keys() :: [atom()]
  def resource_keys, do: @resource_keys

  @doc "The keys that weaken the hardened defaults and must be declared in `:weaken`."
  @spec weakening_keys() :: [atom()]
  def weakening_keys, do: @weakening_keys

  @doc """
  Whether a validated `user:` runs as root: a uid that is numerically 0
  (`"0"`, `"00"`, `"000:1000"`) or the name `"root"`, either with any group.

      iex> CrowdControl.Service.root_user?("000:1000")
      true

      iex> CrowdControl.Service.root_user?("1000")
      false
  """
  @spec root_user?(String.t() | nil) :: boolean()
  def root_user?(nil), do: false

  def root_user?(user) when is_binary(user) do
    case user |> String.split(":") |> hd() do
      "root" -> true
      uid -> String.match?(uid, ~r/\A\d+\z/) and String.to_integer(uid) == 0
    end
  end

  @doc "The total `:files` content budget, in bytes."
  @spec max_files_bytes() :: pos_integer()
  def max_files_bytes, do: @max_files_bytes

  @doc false
  # Public so Compose holds its top-level `:image` and `:forwarder_image` to the
  # same rule as a service's `image:`.
  #
  # The distribution/reference grammar, transcribed from upstream's regexp.go
  # (https://github.com/distribution/reference/blob/main/regexp.go):
  # `[domain[:port]/]path(/path)*[:tag][@digest]`, lowercase path components, a
  # name of at most 255 characters. A bare image ID (`sha256:<64 hex>`), which
  # the Engine also accepts, needs no case of its own: the grammar reads it as
  # the name `sha256` with a 64-character tag. Anything else is refused before
  # it reaches a request path, so no `?`, `#` or whitespace, and no `..` path
  # segment, can change which endpoint is asked. A tag such as `1..2` is valid.
  @spec image_reference?(term()) :: boolean()
  def image_reference?(image) when is_binary(image) do
    case Regex.run(image_reference_regex(), image, capture: ["name"]) do
      [name] -> byte_size(name) <= @max_image_name
      nil -> false
    end
  end

  def image_reference?(_image), do: false

  # `x` mode: whitespace is layout only. Each line is one production of the
  # upstream grammar, in its order: domain and port, path components, tag,
  # digest.
  defp image_reference_regex do
    ~r/
      \A
      (?<name>
        (?:
          (?:
            (?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])
            (?:\.(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]))*
            | \[[a-fA-F0-9:]+\]
          )
          (?::[0-9]+)?
          \/
        )?
        [a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*
        (?:\/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*
      )
      (?::[\w][\w.-]{0,127})?
      (?:@[A-Za-z][A-Za-z0-9]*(?:[-_+.][A-Za-z][A-Za-z0-9]*)*:[0-9a-fA-F]{32,})?
      \z
    /x
  end

  # --- fields ---

  # A service name is a DNS alias on the sandbox network (Compose) and part of
  # a DNS-1123 object name (Kubernetes), which is how every other service
  # addresses it.
  defp fetch_name(spec) do
    case Map.get(spec, :name) do
      name when is_binary(name) ->
        if name =~ ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/ and byte_size(name) <= 63 do
          {:ok, name}
        else
          {:error, {:bad_service_name, name}}
        end

      other ->
        {:error, {:bad_service_name, other}}
    end
  end

  # The sandbox may inherit a top-level `:image`; a sidecar has no fallback. An
  # `{:external, _}` placement names something the session only *reaches*, so
  # there is nothing to run and no image to name.
  defp fetch_image(spec, name, role) do
    case {Map.get(spec, :image), role} do
      {image, _role} when is_binary(image) and image != "" ->
        if image_reference?(image), do: {:ok, image}, else: bad(name, :image)

      {_missing, :sandbox} ->
        {:ok, nil}

      {nil, _role} ->
        if external?(spec), do: {:ok, nil}, else: {:error, {:image_required, name}}

      {_missing, _role} ->
        {:error, {:image_required, name}}
    end
  end

  defp external?(spec), do: match?({:external, _}, Map.get(spec, :placement))

  # Never inferred. A sidecar with egress can relay the internet to whatever it
  # shares a network with, which is exactly why it has to be written down.
  defp fetch_egress(spec, _name, :sandbox) do
    case Map.get(spec, :egress, :none) do
      :none -> {:ok, :none}
      _ -> {:error, :sandbox_egress_forbidden}
    end
  end

  defp fetch_egress(spec, name, _role) do
    case Map.get(spec, :egress) do
      egress when egress in [:none, :allow] -> {:ok, egress}
      nil -> {:error, {:egress_required, name}}
      other -> {:error, {:bad_egress, {name, other}}}
    end
  end

  defp strings(spec, key, name) do
    case Map.get(spec, key) do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: bad(name, key)

      _ ->
        bad(name, key)
    end
  end

  # A key becomes a shell variable name in the container and a `KEY=value`
  # entry in the Engine's `Env`, where an `=` in the key would move the split.
  defp fetch_env(spec, name) do
    with env when is_map(env) <- Map.get(spec, :env, %{}),
         true <- Enum.all?(env, &env_pair?/1) do
      {:ok, env}
    else
      _ -> bad(name, :env)
    end
  end

  defp env_pair?({key, value}),
    do: is_binary(key) and is_binary(value) and key =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  # The shape rules live in `CrowdControl.Volume` so no substrate can drift on
  # what a mount is. Whether a `:name` refers to something that exists is the
  # substrate's question, not this module's.
  defp fetch_volumes(spec, name) do
    case Map.get(spec, :volumes, []) do
      mounts when is_list(mounts) -> collect(mounts, &normalize_mount(&1, name))
      _ -> bad(name, :volumes)
    end
  end

  defp normalize_mount(mount, name) do
    case Volume.normalize([volumes: [mount]], []) do
      {:ok, [normalized]} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:bad_mount, {name, mount}}}
    end
  end

  # A uid or a name, optionally `:gid` or `:group`. Strict, so `root_user?/1`
  # can't be dodged by a spelling the runtime still reads as uid 0 ("+0",
  # " 0"). `\A…\z`, not `^…$`: `$` would let a trailing newline through.
  defp fetch_user(spec, name) do
    case Map.get(spec, :user) do
      nil ->
        {:ok, nil}

      user when is_binary(user) ->
        if Regex.match?(~r/\A(\d+|[a-z_][a-z0-9_-]*)(:(\d+|[a-z_][a-z0-9_-]*))?\z/, user),
          do: {:ok, user},
          else: bad(name, :user)

      _ ->
        bad(name, :user)
    end
  end

  # `:port` is the single-port spelling `:proxy_service` has always read; it
  # becomes the head of `:ports` so the proxy port stays the first one.
  defp fetch_ports(spec, name) do
    legacy = if Map.has_key?(spec, :port), do: [Map.get(spec, :port)], else: []

    case Map.get(spec, :ports, []) do
      ports when is_list(ports) ->
        all = legacy ++ ports
        if Enum.all?(all, &port?/1), do: {:ok, Enum.uniq(all)}, else: bad(name, :ports)

      _ ->
        bad(name, :ports)
    end
  end

  defp port?(port), do: is_integer(port) and port in 1..65_535

  defp fetch_ready(spec, name) do
    case Map.get(spec, :ready) do
      nil -> {:ok, nil}
      ready when is_map(ready) -> if valid_ready?(ready), do: {:ok, ready}, else: bad_ready(name)
      _ -> bad_ready(name)
    end
  end

  # Docker accepts only a `Test` whose first element names the mode, and
  # `"NONE"` disables the check — the poll could then never finish. Kubernetes
  # readiness is a `tcpSocket` probe on `:tcp_port`. At least one must be given.
  defp valid_ready?(ready) do
    test = Map.get(ready, :test)
    tcp = Map.get(ready, :tcp_port)

    (test != nil or tcp != nil) and (test == nil or valid_test?(test)) and
      (tcp == nil or port?(tcp))
  end

  defp valid_test?([kind | rest]) when kind in ["CMD", "CMD-SHELL"],
    do: rest != [] and Enum.all?(rest, &is_binary/1)

  defp valid_test?(_test), do: false

  defp bad_ready(name), do: {:error, {:bad_ready, name}}

  defp fetch_weaken(spec, name) do
    case Map.get(spec, :weaken, []) do
      list when is_list(list) ->
        cond do
          :privileged in list -> {:error, {:privileged_refused, name}}
          Enum.all?(list, &(&1 in @weakening_keys)) -> {:ok, Enum.uniq(list)}
          true -> bad(name, :weaken)
        end

      _ ->
        bad(name, :weaken)
    end
  end

  defp fetch_host_config(spec, name) do
    case Map.get(spec, :host_config, %{}) do
      config when is_map(config) ->
        collect(config, &host_config_entry(&1, name))
        |> case do
          {:ok, entries} -> {:ok, Map.new(entries)}
          error -> error
        end

      _ ->
        bad(name, :host_config)
    end
  end

  # Privileged first: no declaration buys it.
  defp host_config_entry({:privileged, true}, name), do: {:error, {:privileged_refused, name}}
  defp host_config_entry({:privileged, false}, _name), do: {:ok, {:privileged, false}}

  defp host_config_entry({key, value} = entry, name) do
    if valid_host_value?(key, value),
      do: {:ok, entry},
      else: {:error, {:bad_host_config, {name, key}}}
  end

  defp valid_host_value?(:shm_size, v), do: is_integer(v) and v > 0
  defp valid_host_value?(:init, v), do: is_boolean(v)
  defp valid_host_value?(:pids_limit, v), do: is_integer(v) and v > 0
  defp valid_host_value?(:memory, v), do: is_integer(v) and v > 0
  defp valid_host_value?(:cpus, v), do: is_number(v) and v > 0

  defp valid_host_value?(:tmpfs, v),
    do: is_map(v) and Enum.all?(v, fn {k, o} -> is_binary(k) and is_binary(o) end)

  defp valid_host_value?(:cap_add, v), do: is_list(v) and Enum.all?(v, &is_binary/1)
  defp valid_host_value?(:no_new_privileges, v), do: is_boolean(v)
  defp valid_host_value?(:readonly_rootfs, v), do: is_boolean(v)
  defp valid_host_value?(_key, _v), do: false

  defp check_weakenings(name, weakenings, weaken) do
    case Enum.find(weakenings, &(&1 not in weaken)) do
      nil -> :ok
      key -> {:error, {:weakening_not_declared, {name, key}}}
    end
  end

  # In a fixed order, so the error names the same key on every run. A host path
  # on the sandbox is the caller's own workspace mount, passed at top level on
  # every substrate; on a sidecar it is posture and has to be written down.
  defp weakenings(host_config, user, volumes, role) do
    [
      {:cap_add, Map.get(host_config, :cap_add, []) != []},
      {:no_new_privileges, Map.get(host_config, :no_new_privileges) == false},
      {:readonly_rootfs, Map.get(host_config, :readonly_rootfs) == false},
      {:user, root_user?(user)},
      {:host_path, role == :sidecar and Enum.any?(volumes, &(&1.kind == :host_path))},
      {:tmpfs_exec, Enum.any?(Map.get(host_config, :tmpfs, %{}), &tmpfs_exec?/1)}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # Docker reads mount options left to right, so a later `exec` undoes an
  # earlier `noexec`; any spelling of either is treated as the weaker one.
  defp tmpfs_exec?({_path, options}) do
    flags = String.split(options, ",", trim: true)

    "noexec" not in flags or "nosuid" not in flags or "exec" in flags or "suid" in flags
  end

  # Membership names are validated against the stack's declarations by the
  # substrate; here only the shape: a non-empty list of unique DNS-safe names.
  defp fetch_networks(spec, name) do
    case Map.get(spec, :networks) do
      nil ->
        {:ok, nil}

      [_ | _] = list ->
        if Enum.all?(list, &network_name?/1) and Enum.uniq(list) == list,
          do: {:ok, list},
          else: bad(name, :networks)

      _ ->
        bad(name, :networks)
    end
  end

  defp network_name?(n), do: is_binary(n) and n =~ ~r/^[a-z0-9][a-z0-9_-]*$/

  defp fetch_placement(spec, name) do
    case Map.get(spec, :placement) do
      placement when placement in [nil, :pod, :separate] -> {:ok, placement}
      {:external, _target} = external -> {:ok, external}
      _ -> bad(name, :placement)
    end
  end

  defp fetch_drain(spec, name) do
    case {Map.get(spec, :drain), Map.get(spec, :shutdown_limit)} do
      {nil, nil} -> {:ok, nil, nil}
      {nil, _limit} -> bad(name, :shutdown_limit)
      {drain, limit} when is_integer(drain) and drain >= 0 -> drain_limit(drain, limit, name)
      _ -> bad(name, :drain)
    end
  end

  defp drain_limit(drain, nil, _name), do: {:ok, drain, @default_shutdown_limit}

  defp drain_limit(drain, limit, _name) when is_integer(limit) and limit > 0,
    do: {:ok, drain, limit}

  defp drain_limit(_drain, _limit, name), do: bad(name, :shutdown_limit)

  # --- files ---

  defp normalize_file(file, name) when is_map(file) do
    path = Map.get(file, :path)
    content = Map.get(file, :content)
    mode = Map.get(file, :mode, @default_file_mode)
    uid = Map.get(file, :uid, 0)
    gid = Map.get(file, :gid, 0)

    cond do
      not valid_path?(path) -> {:error, {:bad_file, {name, path}}}
      not is_binary(content) -> {:error, {:bad_file, {name, path}}}
      not (is_integer(mode) and mode in 0..0o777) -> {:error, {:bad_file, {name, path}}}
      not (id?(uid) and id?(gid)) -> {:error, {:bad_file, {name, path}}}
      true -> {:ok, %{path: path, content: content, mode: mode, uid: uid, gid: gid}}
    end
  end

  defp normalize_file(file, name), do: {:error, {:bad_file, {name, file}}}

  defp id?(id), do: is_integer(id) and id >= 0

  # Absolute, no empty/`.`/`..` segments, not a directory, no NUL. A `..` is
  # the one that matters — a tar entry that climbs out of its root — and the
  # others are refused because each has a second spelling that does.
  defp valid_path?("/" <> rest = path) do
    segments = String.split(rest, "/")

    rest != "" and not String.contains?(path, <<0>>) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp valid_path?(_path), do: false

  defp unique_paths(files, name) do
    paths = Enum.map(files, & &1.path)

    case paths -- Enum.uniq(paths) do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_file, {name, dup}}}
    end
  end

  defp files_size(files, name) do
    total = files |> Enum.map(&byte_size(&1.content)) |> Enum.sum()

    if total <= @max_files_bytes,
      do: :ok,
      else: {:error, {:files_too_large, {name, total}}}
  end

  # --- private ---

  defp bad(name, key), do: {:error, {:bad_service, {name, key}}}

  defp collect(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
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
end
