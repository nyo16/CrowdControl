defmodule CrowdControl.Backend.Kubernetes.Services do
  @moduledoc """
  The `:services` option of `CrowdControl.Backend.Kubernetes`: validation, the
  topology a set of services implies, and every object it derives. Pure — the
  backend does the HTTP, in the order its moduledoc gives.

  Each service is a `CrowdControl.Service` spec, the map Compose takes too,
  plus a `placement` that is required here (a Pod boundary is posture, and
  posture is never inferred):

    * `:pod` — a native sidecar (`restartPolicy: Always`) appended to the
      sandbox Pod's `initContainers` after `cc-init`, with its own hardened
      `securityContext`, user, resources and mounts. It shares the sandbox's
      network namespace, so it can never have egress of its own:
      `egress: :allow` is `{:k8s, {:pod_sidecar_egress_forbidden, name}}`. A
      volume whose `target` is the capture directory (`/var/log/cc` by
      default) is the sandbox's own capture `emptyDir`, and it must be
      `read_only: true` — that is how a log shipper reads the transcript.
    * `:separate` — its own Pod `cc-<key>-<name>` (label
      `crowd_control.role=service`, `crowd_control.service=<name>`), a
      ClusterIP Service of the same name when it declares `ports`, and a
      NetworkPolicy of the same name built from its edges. A `:separate`
      service cannot see the sandbox's capture directory.
    * `{:external, target}` — something outside the session it may reach; no
      object is created. `target` is a selector or a CIDR, because a
      NetworkPolicy cannot name an FQDN:

          %{namespace_selector: %{"kubernetes.io/metadata.name" => "logging"},
            pod_selector: %{"app" => "vector-aggregator"},
            host: "vector-aggregator.logging.svc", ip: "10.96.12.7"}

          %{ip_block: "10.20.0.0/16", except: ["10.20.1.0/24"]}

      `ports` are required. `host` and `ip` (both or neither) become a
      `hostAliases` entry, since nothing here can resolve a name.

  ## Edges come from network membership

  The `networks:` list that decides who shares a Compose network decides the
  NetworkPolicy edges here, so one spec means the same thing on both
  substrates. The sandbox is on `sbx`, and a service with no `networks:` is
  on `sbx` too. Two parties sharing a network may reach each other's declared
  `ports` (the sandbox's are the backend's `:sandbox_ports`); nothing else is
  allowed in or out. An `egress: :allow` `:separate` service is the
  exception in both directions: it only answers peers — no in-session edge
  starts from it, so a compromised proxy cannot turn around into the browser —
  and its own egress is kube-dns plus TCP 443 to `0.0.0.0/0` and `::/0` minus
  RFC 1918, link-local, CGNAT and ULA. It may share no network with the
  sandbox (`{:k8s, {:sandbox_shares_network_with_egress, "sbx", name}}`),
  which is the Kubernetes form of invariant 1.

  An external is in no network of its own, so its `sbx` membership means the
  sandbox Pod alone (a `:pod` log shipper's aggregator is not handed to the
  browser that shares `sbx`); a `:separate` service reaches an external only
  through another network they both name.

  ## No DNS

  No policy built here allows kube-dns to the sandbox or to an `egress: :none`
  service: a resolver that recurses for anyone is an exfiltration channel.
  Instead every Pod gets `hostAliases` mapping each peer's name to its
  Service ClusterIP — read off the created Service — so `browser:8931` and
  `ws://browser:3000/…` resolve exactly as they do on Compose, and a peer that
  shares `sbx` with a sandbox declaring `:sandbox_ports` reaches it as
  `sandbox`.
  """

  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.Drain
  alias CrowdControl.Backend.Kubernetes.Files
  alias CrowdControl.Service

  @sandbox_network "sbx"
  @sandbox_alias "sandbox"

  # `cc`/`cc-init` are the sandbox Pod's own containers, `deny-all` would make
  # a service's policy collide with the sandbox's managed one, and `sandbox`
  # is the alias peers reach the sandbox by.
  @reserved ["cc", "cc-init", "deny-all", @sandbox_alias]

  # `cc-` + 32 hex + `-` + 27 = 63, the DNS-1123 label limit a Pod and a
  # Service name must meet.
  @max_name 27

  @private_v4 [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "100.64.0.0/10"
  ]
  @private_v6 ["fc00::/7", "fe80::/10"]
  @internet_ports [443]

  @probe_period_seconds 2
  @probe_failure_threshold 60
  @default_tmpfs_size "64Mi"

  @dns_label ~r/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/

  @typedoc """
  What `destroy/1` needs to know about one service, persisted on the sandbox
  Pod as the `crowd_control.services` annotation: enough to derive every
  object name and the delete grace, and nothing else (no env, no files).
  """
  @type ref :: %{name: String.t(), placement: :pod | :separate, grace: non_neg_integer()}

  @typedoc """
  What the manifests need from the backend: `Kubernetes.service_context/1`.
  """
  @type ctx :: %{
          session_key: String.t(),
          owner: String.t() | nil,
          namespace: String.t(),
          config: keyword(),
          capture_dir: String.t(),
          capture_volume: String.t()
        }

  # --- validation ---

  @doc """
  Normalize and validate `config[:services]` for the session `ctx` describes.

  Everything is checked here, before the backend makes its first request:
  each spec through `CrowdControl.Service.normalize/2`, then the
  Kubernetes-only rules in the moduledoc.
  """
  @spec normalize(keyword(), ctx()) :: {:ok, [Service.t()]} | {:error, {:k8s, term()}}
  def normalize(config, ctx) do
    case Keyword.get(config, :services, []) do
      specs when is_list(specs) ->
        with {:ok, services} <- collect(specs, &normalize_spec/1),
             :ok <- unique_names(services),
             :ok <- each(services, &check(&1, ctx)) do
          {:ok, services}
        end

      other ->
        {:error, {:k8s, {:bad_services, other}}}
    end
  end

  @doc """
  Validate `:sandbox_ports`, the sandbox's own app ports that peers on `sbx`
  may reach (a dev server under test, from the browser).
  """
  @spec sandbox_ports(keyword()) :: {:ok, [pos_integer()]} | {:error, {:k8s, term()}}
  def sandbox_ports(config) do
    case Keyword.get(config, :sandbox_ports, []) do
      ports when is_list(ports) ->
        if Enum.all?(ports, &port?/1),
          do: {:ok, Enum.uniq(ports)},
          else: {:error, {:k8s, {:bad_sandbox_ports, ports}}}

      other ->
        {:error, {:k8s, {:bad_sandbox_ports, other}}}
    end
  end

  defp normalize_spec(spec) do
    case Service.normalize(spec, :sidecar) do
      {:ok, service} -> {:ok, service}
      {:error, reason} -> {:error, {:k8s, reason}}
    end
  end

  defp unique_names(services) do
    names = Enum.map(services, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, {:k8s, {:duplicate_service, dup}}}
    end
  end

  defp check(%Service{} = service, ctx) do
    with :ok <- check_name(service, ctx),
         :ok <- check_placement(service),
         :ok <- check_user(service),
         :ok <- check_mounts(service, ctx),
         :ok <- check_tmpfs(service) do
      check_external(service)
    end
  end

  defp check_name(%Service{name: name}, ctx) do
    cond do
      name in @reserved ->
        {:error, {:k8s, {:reserved_service_name, name}}}

      byte_size(name) > @max_name or byte_size(object_name(ctx.session_key, name)) > 63 ->
        {:error, {:k8s, {:service_name_too_long, name}}}

      true ->
        :ok
    end
  end

  defp check_placement(%Service{placement: placement, egress: egress, name: name} = service) do
    case {placement, egress} do
      {nil, _egress} ->
        {:error, {:k8s, {:placement_required, name}}}

      # The Pod is one network namespace: a sidecar's egress *is* the
      # sandbox's egress.
      {:pod, :allow} ->
        {:error, {:k8s, {:pod_sidecar_egress_forbidden, name}}}

      {:separate, :allow} ->
        if on_sandbox_network?(service),
          do: {:error, {:k8s, {:sandbox_shares_network_with_egress, @sandbox_network, name}}},
          else: :ok

      _ ->
        :ok
    end
  end

  defp check_user(service) do
    case run_as(service) do
      {:ok, _ids} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_mounts(%Service{volumes: volumes, placement: placement, name: name}, ctx) do
    Enum.reduce_while(volumes, :ok, fn mount, :ok ->
      cond do
        mount.target != ctx.capture_dir -> {:cont, :ok}
        placement != :pod -> {:halt, {:error, {:k8s, {:capture_not_shared, name}}}}
        not mount.read_only -> {:halt, {:error, {:k8s, {:capture_mount_writable, name}}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp check_tmpfs(%Service{host_config: host_config, name: name}) do
    host_config
    |> Map.get(:tmpfs, %{})
    |> Enum.reduce_while(:ok, fn {_path, options}, :ok ->
      case tmpfs_size(options) do
        {:ok, _size} -> {:cont, :ok}
        :error -> {:halt, {:error, {:k8s, {:bad_host_config, {name, :tmpfs}}}}}
      end
    end)
  end

  defp check_external(%Service{placement: {:external, target}, name: name, ports: ports}) do
    if ports != [] and valid_target?(target),
      do: :ok,
      else: {:error, {:k8s, {:bad_external, name}}}
  end

  defp check_external(_service), do: :ok

  defp valid_target?(%{ip_block: cidr} = target) do
    cidr?(cidr) and Enum.all?(Map.get(target, :except, []), &cidr?/1) and
      not Map.has_key?(target, :namespace_selector) and
      not Map.has_key?(target, :pod_selector) and valid_alias?(target)
  end

  defp valid_target?(%{} = target) do
    selectors = Enum.reject([target[:namespace_selector], target[:pod_selector]], &is_nil/1)

    selectors != [] and Enum.all?(selectors, &string_map?/1) and valid_alias?(target)
  end

  defp valid_target?(_target), do: false

  defp valid_alias?(target) do
    case {Map.get(target, :host), Map.get(target, :ip)} do
      {nil, nil} -> true
      {host, ip} when is_binary(host) and is_binary(ip) -> host != "" and ip?(ip)
      _ -> false
    end
  end

  defp string_map?(map),
    do:
      is_map(map) and map != %{} and
        Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end)

  defp cidr?(cidr) when is_binary(cidr) do
    case String.split(cidr, "/") do
      [ip, bits] -> ip?(ip) and match?({_n, ""}, Integer.parse(bits))
      _ -> false
    end
  end

  defp cidr?(_cidr), do: false

  defp ip?(ip), do: match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(ip)))

  @doc """
  The `{uid, gid}` a service's `user:` asks for — `nil` when it names none.
  Kubernetes takes only numeric ids, so `"crowdctl"` is refused here rather
  than by the API server after other objects exist.
  """
  @spec run_as(Service.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer() | nil} | nil} | {:error, {:k8s, term()}}
  def run_as(%Service{user: nil}), do: {:ok, nil}

  def run_as(%Service{user: user, name: name}) do
    case user |> String.split(":") |> Enum.map(&Integer.parse/1) do
      [{uid, ""}] when uid >= 0 -> {:ok, {uid, nil}}
      [{uid, ""}, {gid, ""}] when uid >= 0 and gid >= 0 -> {:ok, {uid, gid}}
      _ -> {:error, {:k8s, {:bad_user, {name, user}}}}
    end
  end

  # --- names and refs ---

  @doc """
  The Pod, Service and NetworkPolicy name of service `name`.

      iex> CrowdControl.Backend.Kubernetes.Services.object_name("0123abcd", "browser")
      "cc-0123abcd-browser"
  """
  @spec object_name(String.t(), String.t()) :: String.t()
  def object_name(session_key, name), do: "cc-#{session_key}-#{name}"

  @doc "The services that create objects, as the refs `destroy/1` works from."
  @spec refs([Service.t()]) :: [ref()]
  def refs(services) do
    for %Service{placement: placement} = service <- services, placement in [:pod, :separate] do
      %{name: service.name, placement: placement, grace: Drain.grace_seconds([service])}
    end
  end

  @doc "The `crowd_control.services` annotation value, or `nil` for none."
  @spec encode_refs([ref()]) :: String.t() | nil
  def encode_refs([]), do: nil

  def encode_refs(refs) do
    refs
    |> Enum.map(fn ref ->
      %{"name" => ref.name, "placement" => Atom.to_string(ref.placement), "grace" => ref.grace}
    end)
    |> JSON.encode!()
  end

  @doc """
  Parse a `crowd_control.services` annotation back into refs. Lenient: an
  unreadable annotation is `[]` (the orphan sweep is the backstop), an entry
  with an illegal name is dropped rather than turned into a DELETE path, and
  placements map through a closed set — never `String.to_atom/1`.

      iex> alias CrowdControl.Backend.Kubernetes.Services
      iex> Services.decode_refs(~s([{"name":"browser","placement":"separate","grace":0}]))
      [%{name: "browser", placement: :separate, grace: 0}]
      iex> Services.decode_refs("not json")
      []
  """
  @spec decode_refs(String.t() | nil) :: [ref()]
  def decode_refs(annotation) when is_binary(annotation) do
    case JSON.decode(annotation) do
      {:ok, list} when is_list(list) -> Enum.flat_map(list, &decode_ref/1)
      _ -> []
    end
  end

  def decode_refs(_annotation), do: []

  defp decode_ref(%{"name" => name, "placement" => placement} = ref) when is_binary(name) do
    grace = Map.get(ref, "grace", 0)

    with true <- Regex.match?(@dns_label, name),
         {:ok, placement} <- decode_placement(placement),
         true <- is_integer(grace) and grace >= 0 do
      [%{name: name, placement: placement, grace: grace}]
    else
      _ -> []
    end
  end

  defp decode_ref(_ref), do: []

  defp decode_placement("pod"), do: {:ok, :pod}
  defp decode_placement("separate"), do: {:ok, :separate}
  defp decode_placement(_other), do: :error

  @doc "The sandbox Pod's delete grace: the largest of its `:pod` sidecars'."
  @spec sandbox_grace([ref()]) :: non_neg_integer()
  def sandbox_grace(refs) do
    refs
    |> Enum.filter(&(&1.placement == :pod))
    |> Enum.map(& &1.grace)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Every object a session's services derive, for `destroy/1`: the `:separate`
  Pods (with their own grace), Services and NetworkPolicies, every service's
  `:files` ConfigMap, and the sandbox's own Service when it declared
  `:sandbox_ports`. Deleted unconditionally, each 404 being success.
  """
  @spec derived_objects(String.t(), [ref()], boolean()) :: [
          {:pod, String.t(), non_neg_integer()}
          | {:service | :network_policy | :config_map, String.t()}
        ]
  def derived_objects(session_key, refs, sandbox_service?) do
    separate = Enum.filter(refs, &(&1.placement == :separate))

    Enum.map(separate, &{:pod, object_name(session_key, &1.name), &1.grace}) ++
      Enum.map(separate, &{:service, object_name(session_key, &1.name)}) ++
      if(sandbox_service?, do: [{:service, object_name(session_key, @sandbox_alias)}], else: []) ++
      Enum.map(separate, &{:network_policy, object_name(session_key, &1.name)}) ++
      Enum.map(refs, &{:config_map, Files.config_map_name(session_key, &1.name)})
  end

  @doc """
  The `CrowdControl.VersionGate` features `services` need: native sidecars
  for any `:pod` placement, and the `preStop` sleep for any drained service.
  """
  @spec version_features([Service.t()]) :: [CrowdControl.VersionGate.feature()]
  def version_features(services) do
    running = Enum.filter(services, &(&1.placement in [:pod, :separate]))
    sidecars = if Enum.any?(running, &(&1.placement == :pod)), do: [:pod_sidecars], else: []

    sidecars ++ Drain.version_features(running)
  end

  @doc "The services that run in their own Pod."
  @spec separate([Service.t()]) :: [Service.t()]
  def separate(services), do: Enum.filter(services, &(&1.placement == :separate))

  @doc "The services that run in the sandbox Pod, in declaration order."
  @spec in_pod([Service.t()]) :: [Service.t()]
  def in_pod(services), do: Enum.filter(services, &(&1.placement == :pod))

  # --- topology ---

  defp on_sandbox_network?(service), do: @sandbox_network in Service.networks(service)

  defp reachable?(%Service{placement: :separate}), do: true
  defp reachable?(%Service{placement: {:external, _}}), do: true
  defp reachable?(_service), do: false

  defp shares_network?(a, b, except) do
    theirs = Service.networks(b) -- except
    Enum.any?(Service.networks(a), &(&1 in theirs))
  end

  defp sandbox_peers(services) do
    Enum.filter(services, &(reachable?(&1) and on_sandbox_network?(&1)))
  end

  defp peers(service, services) do
    Enum.filter(services, fn other ->
      other.name != service.name and reachable?(other) and peer_shares?(service, other)
    end)
  end

  # An external is outside every network; for it `sbx` means the sandbox Pod
  # alone, so a log aggregator a `:pod` shipper needs is not also handed to
  # every service that shares `sbx` with the sandbox (the browser's only way
  # out stays the proxy). A service reaches an external through any other
  # shared network.
  defp peer_shares?(service, %Service{placement: {:external, _}} = external),
    do: shares_network?(service, external, [@sandbox_network])

  defp peer_shares?(service, other), do: shares_network?(service, other, [])

  # --- policies ---

  @doc """
  The sandbox's managed policy rules: egress to every reachable peer on `sbx`
  on its ports, and ingress from every `:separate` peer on `sbx` to
  `sandbox_ports`. Empty lists are omitted, so with no services the policy
  stays the canonical deny-all.
  """
  @spec sandbox_rules(ctx(), [Service.t()], [pos_integer()]) :: map()
  def sandbox_rules(ctx, services, sandbox_ports) do
    peers = sandbox_peers(services)

    egress = for peer <- peers, peer.ports != [], do: rule("to", [peer(ctx, peer)], peer.ports)

    from = for %Service{placement: :separate} = peer <- peers, do: peer(ctx, peer)

    ingress =
      if sandbox_ports != [] and from != [],
        do: [rule("from", from, sandbox_ports)],
        else: []

    %{}
    |> put_rules("ingress", ingress)
    |> put_rules("egress", egress)
  end

  @doc """
  The NetworkPolicy of a `:separate` service: its edges and nothing else.

  An `egress: :allow` service only answers. It initiates nothing inside the
  session — its egress is kube-dns and the public internet — and no peer
  admits it, so a compromised proxy cannot turn around into the browser.
  """
  @spec policy_manifest(ctx(), Service.t(), [Service.t()], [pos_integer()]) :: map()
  def policy_manifest(ctx, %Service{} = service, services, sandbox_ports) do
    peers = peers(service, services)

    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => metadata(ctx, object_name(ctx.session_key, service.name), service.name),
      "spec" =>
        %{
          "podSelector" => %{"matchLabels" => service_pod_selector(ctx, service.name)},
          "policyTypes" => ["Ingress", "Egress"]
        }
        |> put_rules("ingress", service_ingress(ctx, service, peers))
        |> put_rules("egress", service_egress(ctx, service, peers, sandbox_ports))
    }
  end

  # From every `egress: :none` separate peer and, on `sbx`, the sandbox.
  defp service_ingress(_ctx, %Service{ports: []}, _peers), do: []

  defp service_ingress(ctx, service, peers) do
    from =
      for(%Service{placement: :separate, egress: :none} = peer <- peers, do: peer(ctx, peer)) ++
        if(on_sandbox_network?(service), do: [sandbox_peer(ctx)], else: [])

    if from == [], do: [], else: [rule("from", from, service.ports)]
  end

  defp service_egress(_ctx, %Service{egress: :allow}, _peers, _sandbox_ports),
    do: [dns_rule(), internet_rule()]

  defp service_egress(ctx, service, peers, sandbox_ports) do
    to_peers = for peer <- peers, peer.ports != [], do: rule("to", [peer(ctx, peer)], peer.ports)

    if on_sandbox_network?(service) and sandbox_ports != [],
      do: to_peers ++ [rule("to", [sandbox_peer(ctx)], sandbox_ports)],
      else: to_peers
  end

  defp sandbox_peer(ctx), do: %{"podSelector" => %{"matchLabels" => sandbox_selector(ctx)}}

  defp rule(direction, peers, ports), do: %{direction => peers, "ports" => tcp(ports)}

  defp put_rules(map, _key, []), do: map
  defp put_rules(map, key, rules), do: Map.put(map, key, rules)

  defp tcp(ports), do: Enum.map(ports, &%{"protocol" => "TCP", "port" => &1})

  defp peer(ctx, %Service{placement: :separate, name: name}),
    do: %{"podSelector" => %{"matchLabels" => service_pod_selector(ctx, name)}}

  defp peer(_ctx, %Service{placement: {:external, %{ip_block: cidr} = target}}) do
    %{"ipBlock" => maybe_put(%{"cidr" => cidr}, "except", presence(Map.get(target, :except, [])))}
  end

  defp peer(_ctx, %Service{placement: {:external, target}}) do
    %{}
    |> maybe_put("namespaceSelector", match_labels(target[:namespace_selector]))
    |> maybe_put("podSelector", match_labels(target[:pod_selector]))
  end

  defp match_labels(nil), do: nil
  defp match_labels(labels), do: %{"matchLabels" => labels}

  # An `egress: :allow` service resolves the names it was asked for, so it is
  # the one place kube-dns is reachable from. It already has the internet, so
  # DNS adds no channel it lacked.
  defp dns_rule do
    %{
      "to" => [
        %{
          "namespaceSelector" => %{
            "matchLabels" => %{"kubernetes.io/metadata.name" => "kube-system"}
          },
          "podSelector" => %{"matchLabels" => %{"k8s-app" => "kube-dns"}}
        }
      ],
      "ports" => [%{"protocol" => "UDP", "port" => 53}, %{"protocol" => "TCP", "port" => 53}]
    }
  end

  # The L3 copy of the proxy's own SSRF check: the cluster, the node's
  # metadata endpoint and every private range stay unreachable even if the
  # proxy's allowlist is wrong.
  defp internet_rule do
    %{
      "to" => [
        %{"ipBlock" => %{"cidr" => "0.0.0.0/0", "except" => @private_v4}},
        %{"ipBlock" => %{"cidr" => "::/0", "except" => @private_v6}}
      ],
      "ports" => tcp(@internet_ports)
    }
  end

  # --- host aliases ---

  @doc """
  The `hostAliases` for the sandbox Pod (`:sandbox`) or a `:separate`
  service's Pod: every reachable peer's name mapped to the ClusterIP in `ips`
  (`%{name => ip}`, `"sandbox"` for the sandbox's own Service), plus each
  external's `host`/`ip`. Grouped per IP and sorted, so a manifest is a
  function of its inputs.
  """
  @spec host_aliases(:sandbox | Service.t(), [Service.t()], %{String.t() => String.t()}) ::
          [map()]
  def host_aliases(:sandbox, services, ips) do
    services |> sandbox_peers() |> Enum.flat_map(&alias_entries(&1, ips)) |> group_aliases()
  end

  # It may reach no peer, so it needs no name for one.
  def host_aliases(%Service{egress: :allow}, _services, _ips), do: []

  def host_aliases(%Service{} = service, services, ips) do
    sandbox =
      case {on_sandbox_network?(service), Map.get(ips, @sandbox_alias)} do
        {true, ip} when is_binary(ip) -> [{ip, @sandbox_alias}]
        _ -> []
      end

    service
    |> peers(services)
    |> Enum.flat_map(&alias_entries(&1, ips))
    |> Kernel.++(sandbox)
    |> group_aliases()
  end

  defp alias_entries(%Service{placement: :separate, name: name}, ips) do
    case Map.get(ips, name) do
      ip when is_binary(ip) -> [{ip, name}]
      nil -> []
    end
  end

  defp alias_entries(%Service{placement: {:external, target}, name: name}, _ips) do
    case {Map.get(target, :host), Map.get(target, :ip)} do
      {host, ip} when is_binary(host) and is_binary(ip) -> [{ip, name}, {ip, host}]
      _ -> []
    end
  end

  defp group_aliases(entries) do
    entries
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(fn {ip, names} -> %{"ip" => ip, "hostnames" => Enum.uniq(names)} end)
  end

  # --- Services ---

  @doc "The ClusterIP Service fronting a `:separate` service's declared ports."
  @spec service_manifest(ctx(), Service.t()) :: map()
  def service_manifest(ctx, %Service{name: name, ports: ports}) do
    cluster_ip_service(
      ctx,
      object_name(ctx.session_key, name),
      name,
      service_pod_selector(ctx, name),
      ports
    )
  end

  @doc """
  The ClusterIP Service fronting the sandbox's `:sandbox_ports`, named like a
  service called `sandbox` (a reserved name), so the orphan sweep finds it by
  the same labels.
  """
  @spec sandbox_service_manifest(ctx(), [pos_integer()]) :: map()
  def sandbox_service_manifest(ctx, ports) do
    cluster_ip_service(
      ctx,
      object_name(ctx.session_key, @sandbox_alias),
      @sandbox_alias,
      sandbox_selector(ctx),
      ports
    )
  end

  defp cluster_ip_service(ctx, name, service, selector, ports) do
    %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => metadata(ctx, name, service),
      "spec" => %{
        "type" => "ClusterIP",
        "selector" => selector,
        "ports" =>
          Enum.map(ports, fn port ->
            %{"name" => "tcp-#{port}", "protocol" => "TCP", "port" => port, "targetPort" => port}
          end)
      }
    }
  end

  # --- Pods ---

  @doc "The Pod of a `:separate` service, with `aliases` from `host_aliases/3`."
  @spec pod_manifest(ctx(), Service.t(), [map()]) :: map()
  def pod_manifest(ctx, %Service{} = service, aliases) do
    container =
      ctx
      |> container(service)
      |> maybe_put("readinessProbe", probe(service.ready))

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => metadata(ctx, object_name(ctx.session_key, service.name), service.name),
      "spec" =>
        %{
          # Like Compose's `RestartPolicy: no`: a service that dies stays dead,
          # and its peers see a refused connection rather than a different
          # process behind the same name.
          "restartPolicy" => "Never",
          "automountServiceAccountToken" => false,
          "enableServiceLinks" => false,
          "containers" => [container]
        }
        |> maybe_put("volumes", presence(volumes(ctx, service)))
        |> maybe_put("hostAliases", presence(aliases))
        |> maybe_put("terminationGracePeriodSeconds", Drain.termination_grace_period([service]))
        |> maybe_put("securityContext", pod_security_context(service))
        |> put_scheduling(ctx.config)
    }
  end

  @doc """
  The `:pod` services as native sidecars, in declaration order. Kubernetes
  stops sidecars in reverse order, so a log shipper declared first outlives
  every other sidecar.
  """
  @spec sidecars(ctx(), [Service.t()]) :: [map()]
  def sidecars(ctx, services) do
    for service <- in_pod(services) do
      ctx
      |> container(service)
      |> Map.put("restartPolicy", "Always")
      |> maybe_put("startupProbe", probe(service.ready))
    end
  end

  @doc "The sandbox Pod volumes the `:pod` services add."
  @spec sidecar_volumes(ctx(), [Service.t()]) :: [map()]
  def sidecar_volumes(ctx, services), do: Enum.flat_map(in_pod(services), &volumes(ctx, &1))

  defp container(ctx, %Service{} = service) do
    %{
      "name" => service.name,
      "image" => service.image,
      "securityContext" => security_context(ctx.config, service)
    }
    |> maybe_put("command", service.entrypoint)
    |> maybe_put("args", service.command)
    |> maybe_put("env", env(service.env))
    |> maybe_put("resources", resources(service.host_config))
    |> maybe_put("lifecycle", Drain.lifecycle(service))
    |> maybe_put("volumeMounts", presence(mounts(ctx, service)))
  end

  # The stack's hardening is every service's default, exactly as on Compose;
  # each weaker value was declared in `:weaken` or `Service.normalize/2` would
  # have refused it.
  defp security_context(config, %Service{host_config: host_config} = service) do
    capabilities =
      maybe_put(
        %{"drop" => config[:cap_drop] || ["ALL"]},
        "add",
        presence(Map.get(host_config, :cap_add, []))
      )

    escalation =
      if Map.get(host_config, :no_new_privileges) == false,
        do: true,
        else: Keyword.get(config, :allow_privilege_escalation, false)

    readonly = Map.get(host_config, :readonly_rootfs, config[:readonly_rootfs] == true)

    %{
      "allowPrivilegeEscalation" => escalation,
      "capabilities" => capabilities,
      "seccompProfile" => %{"type" => "RuntimeDefault"}
    }
    |> maybe_put("readOnlyRootFilesystem", readonly || nil)
    |> put_run_as(service)
  end

  defp put_run_as(security_context, service) do
    case run_as(service) do
      {:ok, {uid, gid}} ->
        security_context
        |> Map.put("runAsUser", uid)
        |> maybe_put("runAsGroup", gid)
        |> Map.put("runAsNonRoot", uid != 0)

      _ ->
        security_context
    end
  end

  # Group-owns the Pod's emptyDirs, as the sandbox's `fsGroup` does.
  defp pod_security_context(service) do
    case run_as(service) do
      {:ok, {uid, gid}} -> %{"fsGroup" => gid || uid}
      _ -> nil
    end
  end

  defp put_scheduling(spec, config) do
    spec
    |> maybe_put("runtimeClassName", config[:runtime_class])
    |> maybe_put("nodeSelector", config[:node_selector])
    |> maybe_put("tolerations", config[:tolerations])
  end

  defp env(env) when map_size(env) == 0, do: nil

  defp env(env) do
    env |> Enum.sort() |> Enum.map(fn {name, value} -> %{"name" => name, "value" => value} end)
  end

  defp resources(host_config) do
    limits =
      %{}
      |> maybe_put("memory", host_config[:memory] && to_string(host_config[:memory]))
      |> maybe_put("cpu", host_config[:cpus] && "#{trunc(host_config[:cpus] * 1000)}m")

    if map_size(limits) == 0, do: nil, else: %{"limits" => limits}
  end

  # Readiness is TCP when a port is named — no binary needed in the image —
  # else the same `test` Compose runs, as an exec probe.
  defp probe(%{tcp_port: port}) when is_integer(port),
    do: probe_timing(%{"tcpSocket" => %{"port" => port}})

  defp probe(%{test: ["CMD" | argv]}), do: probe_timing(%{"exec" => %{"command" => argv}})

  defp probe(%{test: ["CMD-SHELL" | parts]}),
    do: probe_timing(%{"exec" => %{"command" => ["/bin/sh", "-c", Enum.join(parts, " ")]}})

  defp probe(_ready), do: nil

  defp probe_timing(probe) do
    Map.merge(probe, %{
      "periodSeconds" => @probe_period_seconds,
      "failureThreshold" => @probe_failure_threshold
    })
  end

  # --- volumes ---

  defp mounts(ctx, %Service{} = service) do
    Files.mounts(service.name, service.files) ++
      Enum.map(tmpfs(service), fn {path, volume, _size} ->
        %{"name" => volume, "mountPath" => path}
      end) ++
      shm_mounts(service) ++
      user_mounts(ctx, service)
  end

  defp volumes(ctx, %Service{} = service) do
    files =
      if service.files == [],
        do: [],
        else: [Files.volume(ctx.session_key, service.name, service.files)]

    files ++
      Enum.map(tmpfs(service), fn {_path, volume, size} -> memory_volume(volume, size) end) ++
      shm_volumes(service) ++
      user_volumes(ctx, service)
  end

  # `host_config.tmpfs` and `shm_size` are Docker spellings; here both are
  # in-memory emptyDirs, whose size limit is mandatory (an unbounded one is
  # charged to the node and evicts the Pod instead of failing the write).
  defp tmpfs(%Service{host_config: host_config, name: name}) do
    host_config
    |> Map.get(:tmpfs, %{})
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.map(fn {{path, options}, index} ->
      {:ok, size} = tmpfs_size(options)
      {path, "cc-#{name}-tmp-#{index}", size}
    end)
  end

  defp shm_mounts(%Service{host_config: %{shm_size: _}, name: name}),
    do: [%{"name" => "cc-#{name}-shm", "mountPath" => "/dev/shm"}]

  defp shm_mounts(_service), do: []

  defp shm_volumes(%Service{host_config: %{shm_size: bytes}, name: name}),
    do: [memory_volume("cc-#{name}-shm", Integer.to_string(bytes))]

  defp shm_volumes(_service), do: []

  defp memory_volume(name, size),
    do: %{"name" => name, "emptyDir" => %{"medium" => "Memory", "sizeLimit" => size}}

  # The capture directory is the sandbox's own emptyDir, shared read-only; any
  # other named volume is a PersistentVolumeClaim and a host path a hostPath,
  # as for the sandbox's own `:volumes`.
  defp user_mounts(ctx, %Service{volumes: mounts, name: name}) do
    for {mount, index} <- Enum.with_index(mounts) do
      if mount.target == ctx.capture_dir do
        %{"name" => ctx.capture_volume, "mountPath" => mount.target, "readOnly" => true}
      else
        %{
          "name" => "cc-#{name}-vol-#{index}",
          "mountPath" => mount.target,
          "readOnly" => mount.read_only
        }
      end
    end
  end

  defp user_volumes(ctx, %Service{volumes: mounts, name: name}) do
    for {mount, index} <- Enum.with_index(mounts), mount.target != ctx.capture_dir do
      body =
        case mount.kind do
          :volume -> %{"persistentVolumeClaim" => %{"claimName" => mount.source}}
          :host_path -> %{"hostPath" => %{"path" => mount.source}}
        end

      Map.put(body, "name", "cc-#{name}-vol-#{index}")
    end
  end

  # Docker's `size=` option (`512m`, `8k`, `1g`, bare bytes) as a Kubernetes
  # quantity; absent means the same 64Mi the sandbox's in-memory dirs default
  # to.
  defp tmpfs_size(options) when is_binary(options) do
    options
    |> String.split(",")
    |> Enum.find_value(fn option ->
      case String.split(String.trim(option), "=", parts: 2) do
        ["size", value] -> value
        _ -> nil
      end
    end)
    |> case do
      nil -> {:ok, @default_tmpfs_size}
      value -> quantity(value)
    end
  end

  defp tmpfs_size(_options), do: :error

  defp quantity(value) do
    case Regex.run(~r/\A(\d+)([bkmg]?)\z/i, value) do
      [_, digits, unit] -> {:ok, digits <> suffix(String.downcase(unit))}
      nil -> :error
    end
  end

  defp suffix(""), do: ""
  defp suffix("b"), do: ""
  defp suffix("k"), do: "Ki"
  defp suffix("m"), do: "Mi"
  defp suffix("g"), do: "Gi"

  # --- labels ---

  defp metadata(ctx, name, service) do
    %{
      "name" => name,
      "namespace" => ctx.namespace,
      "labels" => %{
        "crowd_control.session" => ctx.session_key,
        "crowd_control.owner_hash" => Kubernetes.owner_label(ctx.owner),
        "crowd_control.created_at" => to_string(System.system_time(:millisecond)),
        "crowd_control.role" => "service",
        "crowd_control.service" => service
      },
      "annotations" => %{"crowd_control.owner" => to_string(ctx.owner)}
    }
  end

  defp service_pod_selector(ctx, name) do
    %{
      "crowd_control.session" => ctx.session_key,
      "crowd_control.role" => "service",
      "crowd_control.service" => name
    }
  end

  defp sandbox_selector(ctx) do
    %{"crowd_control.session" => ctx.session_key, "crowd_control.role" => "sandbox"}
  end

  # --- helpers ---

  defp port?(port), do: is_integer(port) and port in 1..65_535

  defp presence([]), do: nil
  defp presence(list), do: list

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp collect(items, fun) do
    items
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
