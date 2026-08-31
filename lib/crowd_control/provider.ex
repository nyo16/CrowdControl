defmodule CrowdControl.Provider do
  @moduledoc """
  Behaviour for the infrastructure a `CrowdControl.Backend.Sandboxd` talks to.

  A provider owns the *lifecycle of a sandbox*: acquiring one, handing back a
  reachable endpoint, reconnecting to one that outlived its session, releasing
  it, and enumerating the ones that are still alive. It owns nothing about
  bytes. `CrowdControl.Backend.Sandboxd` is the byte transport for every
  provider, because every provider runs the same in-sandbox agent
  (`sandboxd`) and speaks the same HTTP protocol to it.

  That split is the point. `CrowdControl.Backend` already parameterizes *where*
  it provisions, but each substrate had to bring its own transport too — the
  Docker backend's FIFO/`tee` pair, the Kubernetes backend's exec stream. A VM
  has no exec API at all, so a fourth substrate meant a fourth transport. With
  one agent, a new substrate is provisioning code and nothing else.

      Session --(Backend, unchanged)--> Backend.Sandboxd
                                            |
                              HTTP/1.1 + bearer token
                                            |
                                       sandboxd (in sandbox)

      Backend.Sandboxd --(Provider, this module)--> Docker | Compose | Gce

  ## Selecting a provider

      CrowdControl.run("hello",
        backend:
          {CrowdControl.Backend.Sandboxd,
           provider: {CrowdControl.Provider.Docker, image: "crowd_control/sandbox:dev"}}
      )

  The `{module, config}` form merges `config` into the backend opts before
  `c:acquire/1` is called, exactly as `CrowdControl.Backend.resolve/1` does.
  Unlike `:backend`, `:provider` has **no default**: a provider decides where
  untrusted model-driven code runs, and guessing that is not a service this
  library provides.

  ## Three load-bearing contracts

  ### 1. `c:acquire/1` returns only when the agent has answered health

  Not when the API call succeeded, not when the container is "created", not
  when the operation is `DONE`. Provisioning that reports success before the
  agent answers is the single largest source of flaky remote backends, and it
  is the default behaviour of the substrates underneath: `gcp_compute`'s
  `insert_and_wait/3` waits for the *operation*, never for the guest. Every
  implementation must poll `GET /v1/health` until it answers `200` or
  `:ready_timeout` elapses.

  A failed `c:acquire/1` **must release whatever it created** before returning.
  A leaked container is untidy; a leaked spot VM bills forever.

  ### 2. `c:release/1` is idempotent, and "already gone" is success

  `CrowdControl.Session` calls `destroy/1` from both `handle_cast(:eof, _)` and
  `terminate/2`, and both can run for one session. A `404` from the substrate
  means the sandbox is gone, which is precisely what the caller asked for.
  Returning an error there turns a tidy shutdown into a crash.

  ### 3. The endpoint is never persisted

  `t:handle/0` goes into `CrowdControl.Store` and must survive
  `:erlang.term_to_binary/1`. `t:CrowdControl.Provider.Endpoint.t/0` must not:
  it holds a derived token, a live tunnel pid, and a `base_url` whose port is
  assigned per-connection. Persisting it would make reattach fail after a node
  restart in the most confusing way available — a stale port that belongs to
  some other process.

  So the handle persists the *resource* (`{instance_name, zone}`,
  `{container_id}`, `{project_name}`) and `c:reconnect/1` rebuilds the *path*.
  The token is never persisted either; `token/1` re-derives it from the
  `session_key` that `CrowdControl.Store` already holds.

  ## Token derivation

      token = Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, session_key), padding: false)

  where `secret` is `config :crowd_control, :sandboxd_secret`. See `token/1`.
  Nothing secret is written to disk, and reattach recomputes the token from the
  persisted session key. Rotating `:sandboxd_secret` therefore invalidates
  every live sandbox's token, and reattach fails closed with
  `{:error, {:sandboxd, :unauthorized}}`. That is the intended trade: the
  alternative is a live credential at rest in DETS.

  ## What a provider must not do

  Infer a security posture. If a sidecar needs egress, the caller says so; if a
  network must be reachable, the caller names it. `CrowdControl.Backend.Docker`
  already refuses to guess `:network_mode` (returning
  `{:error, {:docker, :network_mode_required}}`) and providers inherit that
  discipline.

  ## Adding a provider: the Kubernetes mapping

  `CrowdControl.Provider.Kubernetes` is deliberately not shipped yet, but the
  behaviour is graded on admitting it as provisioning code only. The mapping:

  | Callback | Kubernetes implementation |
  |---|---|
  | `c:acquire/1` | `POST /api/v1/namespaces/{ns}/pods` with `sandboxd` as the container command and the token in an env var, reusing `Backend.Kubernetes`' existing manifest hardening → poll `GET …/pods/{name}` for `status.phase == "Running"` → build the endpoint → poll `GET /v1/health` |
  | `c:reconnect/1` | rebuild the endpoint for the persisted `{namespace, pod_name}`. Nothing is re-created; only the path is |
  | `c:release/1` | `DELETE …/pods/{name}`, `404` = success |
  | `c:list_live/1` | `GET …/pods?labelSelector=crowd-control-owner-hash=…`, hand-paginated through `metadata.continue` exactly as `Backend.Kubernetes.API.list_all/3` already does, because a truncated page makes the reaper prune live sandboxes |
  | `c:age_ms/1` | `now - metadata.creationTimestamp` |
  | `c:scrub/1` | keep `{namespace, pod_name, session_key, owner}`; drop the kubeconfig and every `Req` option |

  ### What writing that table changed about this behaviour

  The reachability row did not fit, and the behaviour was wrong until it did.

  A pod's agent port is not routable, so the endpoint has to be either a
  websocket port-forward (`/portforward` subresource, `v4.channel.k8s.io` —
  a transport, not ~200 lines) or the API server's pod proxy
  (`GET …/pods/{name}:{port}/proxy/v1/health` — a plain HTTP path, which is
  the ~200-line option). But the pod proxy consumes the `authorization`
  header for its *own* authentication, so a single `token` field cannot carry
  both credentials.

  Hence `t:CrowdControl.Provider.Endpoint.t/0` carries `headers` and
  `req_options` alongside `token`: a provider may state exactly how its
  transport is authenticated and configured, and `Backend.Sandboxd.API` merges
  those over its defaults. The one-header protocol assumption survives for
  Docker, Compose and GCE, where the agent is reached directly through a
  loopback port and `authorization` is free.
  """

  alias CrowdControl.Provider.Endpoint

  @typedoc """
  Provider-opaque sandbox handle.

  Persisted by `CrowdControl.Store`, so it must survive
  `:erlang.term_to_binary/1` and must contain no credential, no live pid, and
  no ephemeral path. See `c:scrub/1`.
  """
  @type handle :: term()

  @doc """
  Create a sandbox and return a handle plus a reachable endpoint.

  Must not return until `GET /v1/health` has answered `200`, and must release
  anything it created if it cannot get there.
  """
  @callback acquire(opts :: keyword()) :: {:ok, handle(), Endpoint.t()} | {:error, term()}

  @doc """
  Rebuild the endpoint for an existing sandbox.

  Called on reattach, where the handle came out of `CrowdControl.Store` and the
  endpoint did not exist. Returns a possibly-updated handle so a provider can
  refresh substrate state it learned while reconnecting.
  """
  @callback reconnect(handle()) :: {:ok, handle(), Endpoint.t()} | {:error, term()}

  @doc "Destroy the sandbox. Must be idempotent; already-gone is success."
  @callback release(handle()) :: :ok

  @doc """
  Every sandbox this provider can still see, owner-scoped.

  Backs `CrowdControl.Reaper`. Must paginate exhaustively: a truncated list
  makes the reaper treat live sandboxes as dead records and prune them.
  """
  @callback list_live(opts :: keyword()) :: {:ok, [handle()]} | {:error, term()}

  @doc """
  Age of the sandbox in milliseconds, or `nil` if unknown.

  `CrowdControl.Reaper` uses it to spare sandboxes still inside the reap grace
  period: a sandbox younger than the grace window may belong to a session that
  has provisioned but not yet written its store record, and destroying it would
  be a race the caller cannot win.

  ## Optional in the behaviour, mandatory in practice

  Omitting it does **not** mean "no grace period". It means orphans are never
  collected at all, and the chain is worth spelling out because no single link
  looks wrong:

  `CrowdControl.Backend.Sandboxd` exports `age_ms/1`, so the reaper always
  consults it → `age_ms/2` returns `nil` for a provider that defines no
  callback → the reaper reads an unknown age as "too young to reap", because
  fail-open is the right default there (a missed reap costs one sweep interval;
  a wrong reap costs a live session).

  So a provider without this callback leaks every orphan forever. Implement it.
  Both shipped Docker-shaped providers read it from the
  `crowd_control.created_at` label they set at create time.
  """
  @callback age_ms(handle()) :: non_neg_integer() | nil

  @doc """
  Strip everything from `handle` that must not be persisted.

  Optional; the default is the handle untouched. Implement it whenever the
  handle carries substrate configuration, which for at least one provider
  holds a live token-provider argument.
  """
  @callback scrub(handle()) :: handle()

  @optional_callbacks age_ms: 1, scrub: 1

  @doc """
  Resolve the `:provider` option into `{module, opts}`.

  Accepts a bare module or a `{module, config}` tuple, merging `config` into
  the remaining opts. Mirrors `CrowdControl.Backend.resolve/1` with one
  deliberate difference: there is no default provider.

      iex> CrowdControl.Provider.resolve(provider: {CrowdControl.Provider.Docker, image: "x"})
      {CrowdControl.Provider.Docker, [image: "x"]}
  """
  @spec resolve(keyword()) :: {module(), keyword()}
  def resolve(opts) do
    rest = Keyword.delete(opts, :provider)

    case Keyword.get(opts, :provider) do
      {module, config} when is_atom(module) and is_list(config) ->
        {module, Keyword.merge(rest, config)}

      module when is_atom(module) and not is_nil(module) ->
        {module, rest}

      nil ->
        raise ArgumentError,
              ":provider is required by CrowdControl.Backend.Sandboxd and has no default. " <>
                "Pass e.g. provider: {CrowdControl.Provider.Docker, image: \"my-sandbox:latest\"}"

      other ->
        raise ArgumentError,
              ":provider must be a module or {module, keyword}, got: #{inspect(other)}"
    end
  end

  @doc """
  Age of `handle` via the provider's `c:age_ms/1`, or `nil` if it defines none.
  """
  @spec age_ms(module(), handle()) :: non_neg_integer() | nil
  def age_ms(module, handle) do
    if Code.ensure_loaded?(module) and function_exported?(module, :age_ms, 1) do
      module.age_ms(handle)
    end
  end

  @doc """
  Scrub `handle` via the provider's `c:scrub/1`, if it defines one.

  Returns the handle untouched for providers that do not.
  """
  @spec scrub(module(), handle()) :: handle()
  def scrub(module, handle) do
    if Code.ensure_loaded?(module) and function_exported?(module, :scrub, 1) do
      module.scrub(handle)
    else
      handle
    end
  end

  @doc """
  Derive the agent token for `session_key`.

  `:sandboxd_secret` must be configured; it is deliberately not defaulted or
  auto-generated, because a per-boot secret would silently break reattach
  across a node restart — the one thing the derivation exists to support.

      config :crowd_control, sandboxd_secret: System.fetch_env!("CC_SANDBOXD_SECRET")
  """
  @spec token(String.t()) :: String.t()
  def token(session_key) when is_binary(session_key) do
    :hmac
    |> :crypto.mac(:sha256, secret!(), session_key)
    |> Base.url_encode64(padding: false)
  end

  defp secret! do
    case Application.fetch_env(:crowd_control, :sandboxd_secret) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 ->
        secret

      _ ->
        raise ArgumentError, """
        :sandboxd_secret is not configured.

        CrowdControl.Backend.Sandboxd derives each sandbox's agent token from it
        so that no credential is ever persisted:

            config :crowd_control, sandboxd_secret: System.fetch_env!("CC_SANDBOXD_SECRET")

        Use at least 32 bytes of random data, and keep it stable across restarts
        or reattach will fail closed with {:sandboxd, :unauthorized}.
        """
    end
  end
end
