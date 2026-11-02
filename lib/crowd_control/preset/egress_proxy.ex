defmodule CrowdControl.Preset.EgressProxy do
  @moduledoc """
  A [Smokescreen](https://github.com/stripe/smokescreen) hostname-allowlist
  forward proxy: the only service in the browser layout with `egress: :allow`.

  This is a different thing from Compose's `:proxy_service`, the sidecar that
  holds the Anthropic credential for the CLI. This one carries the *browser's*
  traffic, and nothing else should reach it: it sits on its own internal
  network (`"brw"` by default), which the browser joins and the sandbox does
  not.

      CrowdControl.Preset.EgressProxy.spec(
        image: "crowd_control/smokescreen:dev",
        allow_domains: ["example.com", "*.github.com"],
        nc: true
      )

  Smokescreen was chosen because it denies loopback, link-local, RFC 1918, ULA,
  CGNAT and IPv6-embedded destinations *after* resolving a name and dials the
  address it checked, so an allowlisted name that resolves somewhere private is
  still refused. A denied `CONNECT` is a 407, which Chromium reports as
  `net::ERR_PROXY_AUTH_UNSUPPORTED`: that error means "not on the allowlist".

  ## Options

    * `:image` — required. No official image is pullable;
      `examples/images/smokescreen` builds one. The image needs `sh` for the
      decision-log redirect below, and `nc` for `nc: true`.
    * `:allow_domains` — required, non-empty. Hostnames, or `*.`-prefixed
      globs, matched as written in the request (no TLS interception).
      Smokescreen refuses globs over public suffixes.
    * `:extra_deny_ranges` — CIDRs passed as `--deny-range`, for a cluster Pod
      or Service range that is not already private (a public-range overlay).
    * `:name` — default `"egress-proxy"`; peers reach it as
      `http://<name>:<port>`. Not `"proxy"`, which Compose's
      `:proxy_service` examples use for the API proxy.
    * `:port` — default `4750`.
    * `:network` — the internal network shared with the browser, default
      `"brw"`. Declare it in Compose's `:networks`; on Kubernetes it is only an
      edge (see `CrowdControl.Backend.Kubernetes.Services`).
    * `:decision_log` — `:file` (default) redirects Smokescreen's stderr, one
      JSON `CANONICAL-PROXY-DECISION` line per request, to
      `/var/log/proxy/decisions.jsonl` through `sh -c` (Smokescreen has no log
      file flag). `:stderr` leaves it on the container's stderr.
    * `:log_volume` — Compose only: a declared volume mounted at
      `/var/log/proxy`, so `CrowdControl.Preset.LogShipper`'s
      `:proxy_log_volume` can ship the decisions. Without it the directory is
      an in-memory tmpfs (Compose) or `emptyDir` (Kubernetes).
    * `:nc` — `true` adds a Compose healthcheck
      `nc -z 127.0.0.1 <port>`. Kubernetes always uses a `tcpSocket` probe,
      which needs nothing in the image.
    * `:user` — default `"65532:65532"`, upstream's non-root uid.
    * `:placement` — Kubernetes only; `browser_stack/1` sets `:separate`.

  The configuration is two files under `/etc/smokescreen` delivered through
  `:files` — `allow_missing_role: true` is YAML-only — so on Compose the
  proxy's rootfs must be writable, as `:files` requires.
  """

  alias CrowdControl.Backend.Shell
  alias CrowdControl.Preset.YAML

  @default_name "egress-proxy"
  @default_port 4750
  @default_network "brw"
  @default_user "65532:65532"
  @config_dir "/etc/smokescreen"
  @log_dir "/var/log/proxy"

  @domain ~r/\A(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  @doc """
  The service spec. Raises `ArgumentError` on a missing or malformed option.
  """
  @spec spec(keyword()) :: map()
  def spec(opts) do
    image = CrowdControl.Preset.required_string!(opts, :image, __MODULE__)
    domains = allow_domains!(opts)
    deny_ranges = deny_ranges!(opts)
    name = Keyword.get(opts, :name, @default_name)
    port = port!(opts)
    placement = Keyword.get(opts, :placement)
    log_volume = log_volume!(opts, placement)

    args =
      ["--config-file", "#{@config_dir}/config.yaml", "--listen-ip", "0.0.0.0"] ++
        ["--listen-port", Integer.to_string(port)] ++
        Enum.flat_map(deny_ranges, &["--deny-range", &1])

    %{
      name: name,
      image: image,
      egress: :allow,
      networks: [Keyword.get(opts, :network, @default_network)],
      files: [
        %{path: "#{@config_dir}/config.yaml", content: config_yaml(), mode: 0o444},
        %{path: "#{@config_dir}/acl.yaml", content: acl_yaml(domains), mode: 0o444}
      ],
      ports: [port],
      ready: ready(port, Keyword.get(opts, :nc, false)),
      user: Keyword.get(opts, :user, @default_user)
    }
    |> put_launch(decision_log!(opts), args)
    |> put_log_dir(log_volume)
    |> CrowdControl.Preset.put_placement(placement)
    |> CrowdControl.Preset.validate!(__MODULE__)
  end

  @doc """
  The URL a client configures as its proxy: `http://<name>:<port>`.

      iex> spec = CrowdControl.Preset.EgressProxy.spec(image: "s", allow_domains: ["example.com"])
      iex> CrowdControl.Preset.EgressProxy.url(spec)
      "http://egress-proxy:4750"
  """
  @spec url(map()) :: String.t()
  def url(%{name: name, ports: [port | _]}), do: "http://#{name}:#{port}"

  @doc """
  The main config file. `allow_missing_role` because no client presents an
  mTLS identity, so every request falls to the ACL's default rule.
  """
  @spec config_yaml() :: String.t()
  def config_yaml do
    "# Rendered by CrowdControl.Preset.EgressProxy.\n" <>
      YAML.encode([
        {"allow_missing_role", true},
        {"acl_file", "#{@config_dir}/acl.yaml"}
      ])
  end

  @doc """
  The ACL: one enforcing default rule allowing exactly `domains`.

      iex> CrowdControl.Preset.EgressProxy.acl_yaml(["example.com"]) =~ ~s(- "example.com")
      true
  """
  @spec acl_yaml([String.t()]) :: String.t()
  def acl_yaml(domains) do
    "# Rendered by CrowdControl.Preset.EgressProxy.\n" <>
      YAML.encode([
        {"version", "v1"},
        {"services", []},
        {"default",
         [
           {"name", "default"},
           {"project", "crowd_control"},
           {"action", "enforce"},
           {"allowed_domains", domains}
         ]}
      ])
  end

  # Smokescreen logs every decision to stderr and has no file option, so the
  # file needs a shell redirect: `exec` replaces the shell, so Smokescreen
  # itself receives the stop signal, and `2>>` appends rather than truncates.
  defp put_launch(spec, :file, args) do
    script =
      "exec smokescreen " <>
        Enum.map_join(args, " ", &Shell.escape/1) <> " 2>>#{@log_dir}/decisions.jsonl"

    Map.put(spec, :entrypoint, ["/bin/sh", "-c", script])
  end

  defp put_launch(spec, :stderr, args), do: Map.put(spec, :command, args)

  defp put_log_dir(spec, nil) do
    Map.put(spec, :host_config, %{tmpfs: %{@log_dir => "rw,noexec,nosuid,size=16m"}})
  end

  defp put_log_dir(spec, volume) do
    Map.put(spec, :volumes, [%{name: volume, target: @log_dir}])
  end

  defp ready(port, true),
    do: %{tcp_port: port, test: ["CMD", "nc", "-z", "127.0.0.1", Integer.to_string(port)]}

  defp ready(port, false), do: %{tcp_port: port}

  defp allow_domains!(opts) do
    case Keyword.get(opts, :allow_domains) do
      [_ | _] = domains ->
        if Enum.all?(domains, &(is_binary(&1) and Regex.match?(@domain, &1))),
          do: Enum.uniq(domains),
          else:
            raise(ArgumentError, "#{inspect(__MODULE__)}: bad :allow_domains #{inspect(domains)}")

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: :allow_domains is required and must be a non-empty " <>
                "list of hostnames, got: #{inspect(other)}"
    end
  end

  defp deny_ranges!(opts) do
    ranges = Keyword.get(opts, :extra_deny_ranges, [])

    if is_list(ranges) and Enum.all?(ranges, &CrowdControl.Preset.cidr?/1),
      do: ranges,
      else:
        raise(ArgumentError, "#{inspect(__MODULE__)}: bad :extra_deny_ranges #{inspect(ranges)}")
  end

  defp port!(opts) do
    case Keyword.get(opts, :port, @default_port) do
      port when is_integer(port) and port in 1..65_535 -> port
      other -> raise ArgumentError, "#{inspect(__MODULE__)}: bad :port #{inspect(other)}"
    end
  end

  defp decision_log!(opts) do
    case Keyword.get(opts, :decision_log, :file) do
      mode when mode in [:file, :stderr] -> mode
      other -> raise ArgumentError, "#{inspect(__MODULE__)}: bad :decision_log #{inspect(other)}"
    end
  end

  # A named volume is a PersistentVolumeClaim on Kubernetes, and a decision
  # log on one would outlive the session; the proxy Pod's emptyDir is the
  # Kubernetes answer.
  defp log_volume!(opts, placement) do
    case {Keyword.get(opts, :log_volume), placement} do
      {nil, _placement} ->
        nil

      {volume, nil} when is_binary(volume) and volume != "" ->
        volume

      {volume, nil} ->
        raise ArgumentError, "#{inspect(__MODULE__)}: bad :log_volume #{inspect(volume)}"

      {_volume, _placement} ->
        raise ArgumentError, "#{inspect(__MODULE__)}: :log_volume is Compose-only"
    end
  end
end
