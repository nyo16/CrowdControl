defmodule CrowdControl.Backend.Docker.HostConfig do
  @moduledoc """
  The one place Docker container hardening defaults are defined.

  Both `CrowdControl.Backend.Docker` (which runs the CLI directly, over a FIFO
  and a `tee` file) and `CrowdControl.Provider.Docker` (which runs `sandboxd`
  and talks HTTP to it) create containers, and both must create them equally
  hardened. Two copies of these defaults would drift, and the failure mode is
  silent: a sandbox that quietly lost `CapDrop: ALL` looks and behaves exactly
  like one that did not.

  It lives in the `Backend.Docker.*` namespace rather than under `Provider`
  because it is Docker Engine API vocabulary, and because that is already where
  `CrowdControl.Backend.Docker.API` lives — which every Docker-shaped provider
  also calls. One namespace for "things that speak to the Engine API".

  ## What is a default and what is opt-in

  On by default, because the code running in a sandbox is model-driven and
  untrusted and none of these breaks an ordinary CLI:

    * `CapDrop: ["ALL"]` — a CLI needs no Linux capabilities.
    * `SecurityOpt: ["no-new-privileges:true"]` — it never needs to gain any.
    * `PidsLimit: 512` — `Memory` and `NanoCpus` do **not** bound PIDs, so the
      fork-bomb ceiling has to be set separately.
    * `RestartPolicy: "no"` — non-negotiable. A restarted container truncates
      the capture/tee file and invalidates every persisted `byte_offset`.
      Making restart impossible is cheaper and safer than detecting it.

  Opt-in, because both genuinely break images that expect otherwise:

    * `:readonly_rootfs` — breaks any CLI that writes outside the tmpfs mounts
      (npm caches, `~/.claude`, and so on).
    * `:user` — breaks images that expect root. Applied by the caller, since it
      is a container-level rather than a host-config field.
  """

  @default_pids_limit 512

  # One tmpfs map for both call sites, deliberately the union of what each
  # needs: `/var/run` for the Docker backend's FIFO, `/var/log` for the capture
  # or tee file, `/tmp` by convention. Splitting it per call site would
  # reintroduce exactly the drift this module exists to prevent, and an unused
  # 8 MiB tmpfs mount costs nothing. `noexec,nosuid` so none of them becomes a
  # way to stage and run a binary.
  @default_tmpfs %{
    "/tmp" => "rw,noexec,nosuid,size=64m",
    "/var/run" => "rw,noexec,nosuid,size=8m",
    "/var/log" => "rw,noexec,nosuid,size=64m"
  }

  @doc """
  Build a Docker `HostConfig` object from caller options.

  `:network_mode` is required and has no default here on purpose: the two call
  sites want genuinely different networks (`"none"` for the Docker backend, a
  per-sandbox bridge for the Docker provider, which needs a publishable port),
  and a default would let one of them inherit the other's posture silently.

  Recognised keys in `config`: `:cap_drop`, `:security_opt`, `:pids_limit`,
  `:cpus`, `:memory`, `:readonly_rootfs`, `:tmpfs`.

  Mounts arrive through `opts` as `:volumes`, already normalized by
  `CrowdControl.Volume.normalize/2` — deliberately not read out of `config`.
  `CrowdControl.Provider.Compose` passes its own `config` here and its
  top-level `:volumes` means something else entirely (stack-level volume
  *declarations*, which it creates and mounts itself), so scraping the key
  would silently reinterpret one caller's option as another's.
  """
  @spec build(keyword(), keyword()) :: map()
  def build(config, opts) do
    %{
      "RestartPolicy" => %{"Name" => "no"},
      "NetworkMode" => Keyword.fetch!(opts, :network_mode),
      "AutoRemove" => false,
      "CapDrop" => config[:cap_drop] || ["ALL"],
      "SecurityOpt" => config[:security_opt] || ["no-new-privileges:true"],
      "PidsLimit" => Keyword.get(config, :pids_limit, @default_pids_limit)
    }
    |> maybe_put("NanoCpus", config[:cpus] && trunc(config[:cpus] * 1_000_000_000))
    |> maybe_put("Memory", config[:memory])
    |> put_readonly_rootfs(config)
    |> put_binds(Keyword.get(opts, :volumes, []))
  end

  # `Binds` rather than `Mounts`: both reach the same place, and the string form
  # is what `docker inspect` shows, so a mount asserted in a test reads the same
  # as one a human looks up. A named volume and a bind differ only in whether
  # the source is a path, which is exactly how the Engine tells them apart too.
  defp put_binds(host_config, []), do: host_config

  defp put_binds(host_config, mounts) do
    binds =
      Enum.map(mounts, fn mount ->
        "#{mount.source}:#{mount.target}:#{if mount.read_only, do: "ro", else: "rw"}"
      end)

    Map.put(host_config, "Binds", binds)
  end

  @doc """
  The hardening defaults, as a map, with no network or resource limits.

  Exists so a test can assert that every call site produces the same hardening
  without having to know either call site's network posture.
  """
  @spec hardening_defaults() :: map()
  def hardening_defaults do
    %{
      "RestartPolicy" => %{"Name" => "no"},
      "AutoRemove" => false,
      "CapDrop" => ["ALL"],
      "SecurityOpt" => ["no-new-privileges:true"],
      "PidsLimit" => @default_pids_limit
    }
  end

  @doc "The tmpfs mounts used when `:readonly_rootfs` is enabled."
  @spec default_tmpfs() :: map()
  def default_tmpfs, do: @default_tmpfs

  defp put_readonly_rootfs(host_config, config) do
    if config[:readonly_rootfs] do
      host_config
      |> Map.put("ReadonlyRootfs", true)
      |> Map.put("Tmpfs", config[:tmpfs] || @default_tmpfs)
    else
      host_config
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
