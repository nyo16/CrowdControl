defmodule CrowdControl.Preset.LogShipper do
  @moduledoc """
  A [Vector](https://vector.dev) sidecar that tails the session's capture
  file, redacts it, and ships it — without giving the sandbox a way out.

      # Compose: share the capture directory through a declared volume
      CrowdControl.Preset.LogShipper.spec(sink: :console, capture_volume: "cclog")

      # Kubernetes: a native sidecar in the sandbox Pod, shipping only to an
      # in-cluster aggregator the sandbox's policy names
      CrowdControl.Preset.LogShipper.services(
        placement: :pod,
        sink: {:vector, address: "http://vector-aggregator.logging.svc:6000"},
        aggregator: %{
          namespace_selector: %{"kubernetes.io/metadata.name" => "logging"},
          pod_selector: %{"app" => "vector-aggregator"},
          ip: "10.96.12.7"
        }
      )

  ## It reads the capture and never rotates it

  The file source reads `/var/log/cc/out.jsonl` from the beginning, through a
  read-only mount: the capture is append-only and its byte offsets are
  CrowdControl's resume cursor, so nothing but the sandbox ever writes it.
  Vector's checkpoints live on a Vector-only in-memory `/var/lib/vector`, never
  on the sandbox-writable capture volume, so model-driven code cannot rewrite
  them to skip lines. Lines up to `:max_line_bytes` (the session's own cap,
  1 MiB by default) are shipped; Vector's default of 100 KiB would drop the
  rest. Acknowledgements are on, so a checkpoint advances only after the sink
  accepted the line.

  ## Redaction is on by default and best-effort

  Every line is redacted as raw text *before* it is parsed, so a secret
  nested in a JSON-encoded string at any depth is still caught, and a remap
  error drops the line (`drop_on_error`) rather than forwarding it unredacted.
  The default filters are gitleaks-derived — `sk-ant-` keys, bearer tokens,
  AWS key ids and secrets, GitHub tokens, JWTs, private keys — plus
  CrowdControl's own `ccst_` session tokens and `ccpw_` browser tokens.
  Matches become SHA-256 hex by default, so one leaked key is correlatable
  without being revealed. A regex list always trails new token formats: this
  is defence in depth, not a guarantee. `redact: false` ships the transcript
  verbatim and is refused unless `ship_unredacted: true` says so too.

  ## Draining

  `drain: 15_000` and `shutdown_limit: 20` are set, so teardown waits for the
  file source to reach EOF before SIGTERM (a Kubernetes `preStop` sleep, or a
  Compose wait before `stop`) and then gives Vector its graceful-shutdown limit
  (`VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS`) plus a margin. Without it the end of
  a session is lost. The drain is how long Vector keeps reading after the
  sandbox stops, so it must cover Vector's own latency: measured on
  Kubernetes, a line written after a minute of idle took ~10 s to reach the
  aggregator.

  ## Options

    * `:sink` — required: `:console`, `{:vector, address: url}`,
      `{:http, uri: url}` or `{:loki, endpoint: url}`. On Kubernetes
      (`placement: :pod`) only `{:vector, address: url}` is accepted, because
      the sidecar shares the sandbox's network namespace: any egress it has,
      the sandbox has. The aggregator holds the real sink's credentials. The
      vector address is `host:port` or `http://host:port`, rendered with the
      `http://` Vector needs to connect; `https://` is refused, since there
      are no TLS settings to honour it with.
    * `:aggregator` — Kubernetes, required: the `{:external, target}`
      selector or CIDR the aggregator matches (see
      `CrowdControl.Backend.Kubernetes.Services`). With no DNS in the sandbox
      Pod, an address that is a name needs the aggregator Service's ClusterIP
      as `ip:`; `services/1` turns it into a `hostAliases` entry.
    * `:aggregator_name` — default `"aggregator"`.
    * `:capture_volume` — Compose, required: the declared volume the sandbox
      mounts at the capture directory, mounted read-only here.
    * `:proxy_log_volume` — Compose only: `CrowdControl.Preset.EgressProxy`'s
      `:log_volume`; its decisions are shipped as `type: "proxy_decision"`.
    * `:network` — Compose, for a sink other than `:console`: the network
      Vector joins, default `"log"` (declare it in `:networks`). It gets
      `egress: :allow`, so it must not be `sbx`; with `:console` it stays on
      `sbx` with no egress.
    * `:redact` — `:default`, a list of `:anthropic`, `:bearer`, `:aws`,
      `:github`, `:jwt`, `:private_key`, `:session_token`, `:browser_token` and
      `{:regex, rust_regex}`, or `false` (with `ship_unredacted: true`).
    * `:redactor` — `:sha2` (default), `:full` or `{:text, replacement}`.
    * `:labels` — `%{"team" => "platform"}`, rendered literally into every
      event's `cc.labels`.
    * `:max_line_bytes` — default `1_048_576`, the session default.
    * `:capture_path` — default `/var/log/cc/out.jsonl`.
    * `:image` — default `timberio/vector:0.61.0-distroless-libc`.
    * `:user` — default `"65532:65532"` (the image runs as root otherwise).
    * `:drain`, `:shutdown_limit` — defaults `15_000` ms and `20` s.
    * `:sandbox` — Compose: the sandbox service name, default `"sandbox"`;
      Vector `depends_on` it so the capture directory is copied up with the
      sandbox's ownership before Vector mounts it.
    * `:name` — default `"vector"`.
    * `:placement` — `:pod` on Kubernetes; nothing else can read the capture.

  The configuration is literal YAML delivered through `:files` (a ConfigMap
  on Kubernetes): no `${…}` interpolation, which Vector disables by default,
  and no secrets. On Compose the API listens on loopback inside the Vector
  container only; on Kubernetes it is off, since the Pod's loopback is the
  sandbox's too.
  """

  alias CrowdControl.Backend.Kubernetes.Services
  alias CrowdControl.Preset.YAML

  @default_name "vector"
  @default_image "timberio/vector:0.61.0-distroless-libc"
  @default_user "65532:65532"
  @default_capture "/var/log/cc/out.jsonl"
  # Keep in step with `CrowdControl.Session`'s `:max_line_bytes` default.
  @default_max_line_bytes 1_048_576
  @default_drain 15_000
  @default_shutdown_limit 20
  @default_network "log"
  @default_sandbox "sandbox"
  @default_aggregator "aggregator"
  @data_dir "/var/lib/vector"
  @config_path "/etc/vector/vector.yaml"
  @proxy_dir "/var/log/proxy"

  # Rust `regex` syntax, rendered as VRL raw strings `r'…'`, so none may
  # contain a `'`. Token classes exclude `\` and `"`, so a match ends at a
  # JSON escape and the line stays parseable after substitution.
  @filters [
    anthropic: [~S'sk-ant-[a-z]+[0-9]{2}-[A-Za-z0-9_\-]{20,}'],
    bearer: [~S'(?i)bearer\s+[A-Za-z0-9\-._~+/]+=*'],
    aws: [
      ~S'\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16}\b',
      ~S'(?i)aws_secret_access_key[\s":=\\]+[A-Za-z0-9/+=]{40}'
    ],
    github: [~S'ghp_[0-9a-zA-Z]{36}', ~S'github_pat_\w{82}'],
    jwt: [~S'\bey[a-zA-Z0-9]{17,}\.ey[a-zA-Z0-9/_\-]{17,}\.[a-zA-Z0-9/_\-]{10,}={0,2}'],
    private_key: [
      ~S'(?i)-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----[\s\S-]{64,}?KEY(?: BLOCK)?-----'
    ],
    session_token: [~S'ccst_[A-Za-z0-9_\-]{16,}'],
    browser_token: [~S'ccpw_[A-Za-z0-9_\-]{16,}']
  ]

  @label_key ~r/\A[a-z0-9_]{1,63}\z/
  @label_value ~r/\A[\x20-\x21\x23-\x5b\x5d-\x7e]{0,256}\z/

  @doc """
  The Vector service spec. Raises `ArgumentError` on a missing, malformed or
  refused option.
  """
  @spec spec(keyword()) :: map()
  def spec(opts) do
    cfg = options!(opts)
    user = Keyword.get(opts, :user, @default_user)

    %{
      name: Keyword.get(opts, :name, @default_name),
      image: Keyword.get(opts, :image, @default_image),
      egress: cfg.egress,
      command: ["--config", @config_path],
      env: %{"VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS" => Integer.to_string(cfg.shutdown_limit)},
      files: [%{path: @config_path, content: render(cfg), mode: 0o444}],
      volumes: volumes(cfg),
      host_config: %{tmpfs: %{@data_dir => "rw,noexec,nosuid,size=8m" <> data_dir_owner(user)}},
      user: user,
      drain: cfg.drain,
      shutdown_limit: cfg.shutdown_limit
    }
    |> put_compose(cfg, opts)
    |> CrowdControl.Preset.put_placement(cfg.placement)
    |> CrowdControl.Preset.validate!(__MODULE__)
  end

  @doc """
  `spec/1`, plus on Kubernetes the `{:external, …}` aggregator service its
  sink needs a policy edge to.
  """
  @spec services(keyword()) :: [map()]
  def services(opts) do
    case aggregator(opts) do
      nil -> [spec(opts)]
      aggregator -> [spec(opts), aggregator]
    end
  end

  @doc """
  The `{:external, target}` aggregator service for a Kubernetes shipper, or
  `nil` on Compose. Its port is the sink address's; its `host` alias is the
  address's host when that is a name.

  The aggregator is on the sandbox's own network, so its target is held to
  `CrowdControl.Backend.Kubernetes.Services.check_external/2` here, as
  `provision/1` would: a private or narrow `ip_block`, and no kube-dns
  unless the target says `allow_dns: true`.
  """
  @spec aggregator(keyword()) :: map() | nil
  def aggregator(opts) do
    case options!(opts) do
      %{placement: :pod, sink: {:vector, host, port}, aggregator: target} ->
        %{
          name: Keyword.get(opts, :aggregator_name, @default_aggregator),
          egress: :none,
          placement: {:external, alias_target(target, host)},
          ports: [port]
        }
        |> CrowdControl.Preset.validate!(__MODULE__)
        |> reachable_target!()

      _compose ->
        nil
    end
  end

  defp reachable_target!(spec) do
    {:ok, service} = CrowdControl.Service.normalize(spec, :sidecar)

    case Services.check_external(service, nil) do
      :ok ->
        spec

      {:error, {:k8s, reason}} ->
        refuse!("the aggregator #{inspect(spec.placement)} is refused: #{inspect(reason)}")
    end
  end

  @doc "The rendered `vector.yaml` for `opts`, exactly as `spec/1` stages it."
  @spec config(keyword()) :: String.t()
  def config(opts), do: opts |> options!() |> render()

  @doc """
  The default filter set as Rust regex source, in render order.

      iex> filters = CrowdControl.Preset.LogShipper.default_filters()
      iex> Enum.any?(filters, &String.starts_with?(&1, "ccst_"))
      true
  """
  @spec default_filters() :: [String.t()]
  def default_filters, do: Enum.flat_map(@filters, &elem(&1, 1))

  # --- options ---

  defp options!(opts) do
    placement = placement!(opts)
    sink = sink!(Keyword.get(opts, :sink), placement)

    %{
      placement: placement,
      sink: sink,
      egress: egress(sink, placement),
      aggregator: aggregator_target!(opts, placement),
      capture_path: capture_path!(opts),
      capture_volume: capture_volume!(opts, placement),
      proxy_log_volume: proxy_log_volume!(opts, placement),
      network: network!(opts, sink, placement),
      filters: filters!(opts),
      redactor: redactor!(Keyword.get(opts, :redactor, :sha2)),
      labels: labels!(Keyword.get(opts, :labels, %{})),
      max_line_bytes: positive!(opts, :max_line_bytes, @default_max_line_bytes),
      drain: non_negative!(opts, :drain, @default_drain),
      shutdown_limit: positive!(opts, :shutdown_limit, @default_shutdown_limit),
      sandbox: Keyword.get(opts, :sandbox, @default_sandbox)
    }
  end

  defp placement!(opts) do
    case Keyword.get(opts, :placement) do
      placement when placement in [nil, :pod] ->
        placement

      other ->
        refuse!(
          "placement #{inspect(other)}: only :pod (Kubernetes) can read the sandbox's capture"
        )
    end
  end

  # Q10: a `:pod` sidecar's egress is the sandbox's egress, so on Kubernetes
  # the only sink is an in-cluster aggregator the sandbox policy names.
  defp sink!(nil, _placement), do: refuse!(":sink is required")

  defp sink!({:vector, opts}, _placement) when is_list(opts) do
    {host, port} = address!(Keyword.get(opts, :address))
    {:vector, host, port}
  end

  defp sink!(sink, :pod) do
    refuse!(
      "sink #{inspect(sink)} with placement: :pod: a native sidecar shares the sandbox's " <>
        "network namespace, so only {:vector, address: aggregator} is allowed"
    )
  end

  defp sink!(:console, nil), do: :console
  defp sink!({:http, opts}, nil) when is_list(opts), do: {:http, url!(opts, :uri)}
  defp sink!({:loki, opts}, nil) when is_list(opts), do: {:loki, url!(opts, :endpoint)}
  defp sink!(other, _placement), do: refuse!("unknown :sink #{inspect(other)}")

  defp egress(:console, _placement), do: :none
  defp egress(_sink, :pod), do: :none
  defp egress(_sink, nil), do: :allow

  defp address!(address) when is_binary(address) do
    url = if String.contains?(address, "://"), do: address, else: "http://" <> address

    # Rendered as plain-text `http://`; the preset has no TLS settings, so an
    # `https://` address would be silently downgraded.
    case URI.parse(url) do
      %URI{scheme: "http", host: host, port: port}
      when is_binary(host) and host != "" and is_integer(port) ->
        {host, port}

      _ ->
        refuse!("bad vector sink address #{inspect(address)}")
    end
  end

  defp address!(other), do: refuse!("the vector sink needs address:, got #{inspect(other)}")

  defp url!(opts, key) do
    case URI.parse(to_string(Keyword.get(opts, key))) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        Keyword.fetch!(opts, key)

      _ ->
        refuse!("sink needs an http(s) #{inspect(key)}, got #{inspect(Keyword.get(opts, key))}")
    end
  end

  defp aggregator_target!(opts, :pod) do
    case Keyword.get(opts, :aggregator) do
      target when is_map(target) and map_size(target) > 0 ->
        target

      other ->
        refuse!(
          "placement: :pod needs :aggregator, the {:external, target} selector or CIDR the " <>
            "sandbox Pod's policy allows; got #{inspect(other)}"
        )
    end
  end

  defp aggregator_target!(opts, nil) do
    if Keyword.has_key?(opts, :aggregator),
      do: refuse!(":aggregator is Kubernetes-only (placement: :pod)"),
      else: nil
  end

  # An IP literal needs no alias; a name does, and only the operator knows the
  # address it should resolve to, since the sandbox Pod has no DNS.
  defp alias_target(target, host) do
    cond do
      ip_literal?(host) ->
        target

      is_binary(Map.get(target, :ip)) ->
        Map.put(target, :host, host)

      true ->
        refuse!(
          "the aggregator address #{inspect(host)} is a name and the sandbox Pod has no DNS: " <>
            "give its Service ClusterIP as ip: in :aggregator, or use an IP address"
        )
    end
  end

  defp ip_literal?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

  defp capture_path!(opts) do
    case Keyword.get(opts, :capture_path, @default_capture) do
      "/" <> _ = path -> path
      other -> refuse!("bad :capture_path #{inspect(other)}")
    end
  end

  defp capture_volume!(opts, nil) do
    case Keyword.get(opts, :capture_volume) do
      volume when is_binary(volume) and volume != "" ->
        volume

      other ->
        refuse!(
          "Compose needs :capture_volume, the declared volume the sandbox mounts at the " <>
            "capture directory; got #{inspect(other)}"
        )
    end
  end

  # On Kubernetes the mount target alone selects the sandbox's capture
  # emptyDir; the name is only there because a mount needs one.
  defp capture_volume!(_opts, :pod), do: "capture"

  defp proxy_log_volume!(opts, placement) do
    case {Keyword.get(opts, :proxy_log_volume), placement} do
      {nil, _placement} -> nil
      {volume, nil} when is_binary(volume) and volume != "" -> volume
      {_volume, :pod} -> refuse!(":proxy_log_volume is Compose-only")
      {other, _placement} -> refuse!("bad :proxy_log_volume #{inspect(other)}")
    end
  end

  defp network!(opts, sink, nil) when sink != :console do
    case Keyword.get(opts, :network, @default_network) do
      "sbx" -> refuse!("a shipper with egress may not join sbx, the sandbox's network")
      network when is_binary(network) -> network
      other -> refuse!("bad :network #{inspect(other)}")
    end
  end

  defp network!(_opts, _sink, _placement), do: nil

  defp filters!(opts) do
    case {Keyword.get(opts, :redact, :default), Keyword.get(opts, :ship_unredacted)} do
      {false, true} ->
        false

      {false, _} ->
        refuse!(
          "redact: false ships secrets verbatim; say ship_unredacted: true as well if that " <>
            "is really what you want"
        )

      {:default, _} ->
        default_filters()

      {[_ | _] = names, _} ->
        Enum.flat_map(names, &filter!/1)

      {other, _} ->
        refuse!("bad :redact #{inspect(other)}")
    end
  end

  defp filter!({:regex, pattern}) when is_binary(pattern) and pattern != "" do
    if String.contains?(pattern, ["'", "\n", "\r"]),
      do: refuse!("a :redact regex may not contain a quote or a newline: #{inspect(pattern)}"),
      else: [pattern]
  end

  defp filter!(name) when is_atom(name) do
    case Keyword.fetch(@filters, name) do
      {:ok, patterns} -> patterns
      :error -> refuse!("unknown :redact filter #{inspect(name)}")
    end
  end

  defp filter!(other), do: refuse!("bad :redact entry #{inspect(other)}")

  defp redactor!(:sha2), do: ~s({"type": "sha2", "variant": "SHA-256", "encoding": "base16"})
  defp redactor!(:full), do: nil

  defp redactor!({:text, text}) when is_binary(text) do
    if Regex.match?(@label_value, text),
      do: ~s({"type": "text", "replacement": #{JSON.encode!(text)}}),
      else: refuse!("bad :redactor text #{inspect(text)}")
  end

  defp redactor!(other), do: refuse!("bad :redactor #{inspect(other)}")

  defp labels!(labels) when is_map(labels) do
    if Enum.all?(labels, fn {k, v} ->
         is_binary(k) and is_binary(v) and Regex.match?(@label_key, k) and
           Regex.match?(@label_value, v)
       end),
       do: labels,
       else: refuse!("bad :labels #{inspect(labels)}")
  end

  defp labels!(other), do: refuse!("bad :labels #{inspect(other)}")

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> refuse!("bad #{inspect(key)} #{inspect(other)}")
    end
  end

  defp non_negative!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      other -> refuse!("bad #{inspect(key)} #{inspect(other)}")
    end
  end

  @spec refuse!(String.t()) :: no_return()
  defp refuse!(message), do: raise(ArgumentError, "#{inspect(__MODULE__)}: #{message}")

  # --- spec ---

  # Docker copies the image's directory up into a tmpfs, and the Vector image
  # ships `/var/lib/vector` as root 0755, so a non-root Vector could not
  # create its checkpoints and refused to start. The mount is handed to the
  # user instead (Kubernetes' `emptyDir` ignores these options).
  defp data_dir_owner(user) do
    case Regex.run(~r/\A(\d+)(?::(\d+))?\z/, to_string(user)) do
      [_, uid] -> ",uid=#{uid},mode=0700"
      [_, uid, gid] -> ",uid=#{uid},gid=#{gid},mode=0700"
      nil -> ",mode=1777"
    end
  end

  defp volumes(cfg) do
    capture = %{
      name: cfg.capture_volume,
      target: Path.dirname(cfg.capture_path),
      read_only: true
    }

    proxy =
      if cfg.proxy_log_volume,
        do: [%{name: cfg.proxy_log_volume, target: @proxy_dir, read_only: true}],
        else: []

    [capture | proxy]
  end

  defp put_compose(spec, %{placement: :pod}, _opts), do: spec

  defp put_compose(spec, cfg, _opts) do
    spec
    |> Map.put(:depends_on, [cfg.sandbox])
    |> then(&if cfg.network, do: Map.put(&1, :networks, [cfg.network]), else: &1)
  end

  # --- vector.yaml ---

  defp render(cfg) do
    proxy? = cfg.proxy_log_volume != nil

    inputs = ["transcript_redacted"] ++ if(proxy?, do: ["proxy_redacted"], else: [])

    "# Rendered by CrowdControl.Preset.LogShipper for Vector 0.61. Literal values only:\n" <>
      "# no ${...} interpolation and no secrets.\n" <>
      YAML.encode([
        {"data_dir", @data_dir},
        {"acknowledgements", [{"enabled", true}]},
        {"api", api(cfg)},
        {"sources", sources(cfg, proxy?)},
        {"transforms", transforms(cfg, proxy?)},
        {"sinks", [{"out", sink(cfg.sink, inputs)}]}
      ])
  end

  defp api(%{placement: :pod}), do: [{"enabled", false}]
  defp api(_cfg), do: [{"enabled", true}, {"address", "127.0.0.1:8686"}]

  defp sources(cfg, proxy?) do
    transcript =
      {"transcript",
       [
         {"type", "file"},
         {"include", [cfg.capture_path]},
         {"read_from", "beginning"},
         {"fingerprint", [{"strategy", "checksum"}, {"lines", 1}]},
         {"max_line_bytes", cfg.max_line_bytes},
         {"offset_key", "offset"},
         {"file_key", ""},
         {"host_key", ""}
       ]}

    proxy =
      {"proxy_decisions",
       [
         {"type", "file"},
         {"include", [Path.join(@proxy_dir, "decisions.jsonl")]},
         {"read_from", "beginning"},
         {"max_line_bytes", cfg.max_line_bytes},
         {"file_key", ""},
         {"host_key", ""}
       ]}

    [transcript] ++ if(proxy?, do: [proxy], else: [])
  end

  defp transforms(cfg, proxy?) do
    transcript = remap("transcript_redacted", "transcript", transcript_vrl(cfg))
    proxy = remap("proxy_redacted", "proxy_decisions", proxy_vrl(cfg))

    [transcript] ++ if(proxy?, do: [proxy], else: [])
  end

  # Fail closed: by default a remap error forwards the original event, which
  # for a redaction stage is the leak itself.
  defp remap(name, input, vrl) do
    {name,
     [
       {"type", "remap"},
       {"inputs", [input]},
       {"drop_on_error", true},
       {"drop_on_abort", true},
       {"source", {:block, vrl}}
     ]}
  end

  defp transcript_vrl(cfg) do
    """
    raw = string(.message) ?? ""
    #{redact_vrl(cfg)}parsed, err = parse_json(raw)
    offset = .offset
    . = {}
    if err == null && is_object(parsed) {
      .event = parsed
      .type = parsed.type
    } else {
      .raw = raw
      .type = "unparsed"
    }
    .offset = offset
    .cc = #{cc_vrl(cfg, "transcript")}
    """
  end

  defp proxy_vrl(cfg) do
    """
    raw = string(.message) ?? ""
    #{redact_vrl(cfg)}parsed = object(parse_json(raw) ?? null) ?? {}
    if parsed.msg != "CANONICAL-PROXY-DECISION" { abort }
    . = {"event": parsed, "type": "proxy_decision", "cc": #{cc_vrl(cfg, "proxy")}}
    """
  end

  # The raw line, before parsing: a secret inside a JSON-encoded string is
  # still a substring of the line, at any depth.
  defp redact_vrl(%{filters: false}), do: ""

  defp redact_vrl(%{filters: filters, redactor: redactor}) do
    literals = Enum.map_join(filters, ",\n", &"  r'#{&1}'")
    redactor = if redactor, do: ", redactor: #{redactor}", else: ""

    "raw = redact(raw, filters: [\n#{literals}\n]#{redactor})\n"
  end

  # The hostname is the Pod name `cc-<session_key>` on Kubernetes, and the
  # container id on Compose: the session's identity without an env var.
  defp cc_vrl(cfg, stream) do
    ~s|{"stream": "#{stream}", "host": get_hostname() ?? "", "labels": #{JSON.encode!(cfg.labels)}}|
  end

  defp sink(:console, inputs) do
    [
      {"type", "console"},
      {"inputs", inputs},
      {"target", "stdout"},
      {"encoding", [{"codec", "json"}]}
    ]
  end

  # With a bare `host:port`, Vector 0.61's vector sink cannot connect at all
  # ("HTTP request failed: client error (Connect)", measured against a vector
  # source); the scheme makes it plain-text gRPC.
  defp sink({:vector, host, port}, inputs) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    [{"type", "vector"}, {"inputs", inputs}, {"address", "http://#{host}:#{port}"}]
  end

  defp sink({:http, uri}, inputs) do
    [
      {"type", "http"},
      {"inputs", inputs},
      {"uri", uri},
      {"method", "post"},
      {"encoding", [{"codec", "json"}]},
      {"framing", [{"method", "newline_delimited"}]}
    ]
  end

  # `session_id`-style values belong in structured metadata, never in labels:
  # Loki indexes every label value.
  defp sink({:loki, endpoint}, inputs) do
    [
      {"type", "loki"},
      {"inputs", inputs},
      {"endpoint", endpoint},
      {"out_of_order_action", "accept"},
      {"encoding", [{"codec", "json"}]},
      {"labels", [{"app", "crowd_control"}, {"stream", "{{ cc.stream }}"}]}
    ]
  end
end
