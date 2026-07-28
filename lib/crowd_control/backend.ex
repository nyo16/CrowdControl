defmodule CrowdControl.Backend do
  @moduledoc """
  Behaviour for the sandbox that a `CrowdControl.Session` drives.

  A backend owns everything transport-specific about running a CLI: where the
  process lives, how bytes get in and out of it, and how it is torn down.
  `CrowdControl.Session` owns everything else — line splitting, JSON decoding,
  message accumulation, subscriber broadcast, timeouts — and never learns which
  backend it is talking to.

  Three implementations ship:

    * `CrowdControl.Backend.Local` — a local subprocess via `NetRunner`. The
      default, and behaviourally identical to pre-behaviour CrowdControl.
    * `CrowdControl.Backend.Docker` — a container over the Docker Engine API.
    * `CrowdControl.Backend.Kubernetes` — a Pod over the Kubernetes API server,
      session-facing semantics indistinguishable from the Docker one.

  ## Selecting a backend

      CrowdControl.Session.start_link(backend: CrowdControl.Backend.Local)

      CrowdControl.Session.start_link(
        backend: {CrowdControl.Backend.Docker, image: "my-cli:latest"}
      )

  The `{module, config}` form merges `config` into the session opts before
  `c:provision/1` is called. A bare module is equivalent to `{module, []}`.

  ## Two callbacks that are deliberately not what you would guess

  `read/1` is **not** a callback. A blocking synchronous read is the right shape
  for a NIF-backed pipe and the wrong shape for a streamed HTTP body. Instead,
  `c:start_reader/3` inverts the control flow: the backend is handed the session
  pid and becomes responsible for delivering data to it. How it does that is
  opaque — a blocking loop in a linked process, an async HTTP stream, anything.

  `kill/2` is **not** a callback. `:sigterm`/`:sigkill` is POSIX vocabulary that
  a remote sandbox does not have. `c:destroy/1` is the only teardown primitive;
  a backend that *does* have signals (like `Local`) implements its own
  escalation behind it.

  ## The reader contract

  `c:start_reader/3` **must**:

    * deliver output as `GenServer.cast(session_pid, {:stdout_data, binary})`
    * deliver end-of-stream as `GenServer.cast(session_pid, :eof)` — exactly
      once, and also on transport error, so the session is never left hanging
    * return a pid that is **linked to the calling process**, preserving the
      crash semantics of the original `spawn_link` reader: if the reader dies,
      the session dies with it rather than silently going deaf

  ## The destroy contract

  `c:destroy/1` **must be idempotent**. `Session` calls it from both
  `handle_cast(:eof, _)` and `terminate/2`, and those can both run for a single
  session. It must also tolerate a handle whose underlying resource is already
  gone — a 404 from a remote API is success, not failure.

  ## Error normalization

  Callbacks should return tagged tuples, not raise. Remote backends see failure
  shapes that local ones do not (`%Req.TransportError{}`, `:timeout`, HTTP 5xx),
  and normalizing them is the **backend's** job so that `Session` only ever has
  to reason about one vocabulary. See `safe/2`.
  """

  @typedoc """
  Backend-opaque session handle.

  `Session` never inspects this. It must survive `:erlang.term_to_binary/1` if
  the backend supports reattach, since `CrowdControl.Store` persists it.
  """
  @type handle :: term()

  @typedoc """
  Where a reader should resume from.

  `byte_offset` counts bytes already delivered to the session; `buffer` is the
  partial line left over from the last delivery. A backend consumes only
  `byte_offset` — `Session` re-seeds `buffer` itself before the reader starts.
  Splitting it this way is what makes mid-line resume byte-exact.
  """
  @type cursor :: %{byte_offset: non_neg_integer(), buffer: binary()}

  @doc "Create the sandbox. Called once, before `c:exec/4`."
  @callback provision(opts :: keyword()) :: {:ok, handle()} | {:error, term()}

  @doc """
  Start the CLI inside the sandbox.

  Returns an updated handle so backends can thread exec-specific state (a Docker
  exec id, a tee path) without a second struct.
  """
  @callback exec(handle(), executable :: String.t(), args :: [String.t()], env :: map()) ::
              {:ok, handle()} | {:error, term()}

  @doc """
  Begin delivering output to `session_pid`, resuming from `cursor`.

  See "The reader contract" in the module doc — the linked-pid and cast-shape
  requirements are load-bearing.
  """
  @callback start_reader(handle(), session_pid :: pid(), cursor()) ::
              {:ok, pid()} | {:error, term()}

  @doc "Write to the CLI's stdin."
  @callback write(handle(), iodata()) :: :ok | {:error, term()}

  @doc "Wait for the CLI to exit. `nil` status means exited-but-unknown."
  @callback await_exit(handle(), timeout()) :: {:ok, integer() | nil} | :timeout

  @doc "Whether the sandbox is still running."
  @callback alive?(handle()) :: boolean()

  @doc "Tear down the sandbox. Must be idempotent — see the module doc."
  @callback destroy(handle()) :: :ok

  @doc """
  List sandboxes this backend currently has running.

  Used by `CrowdControl.Reaper` for boot reconciliation, so the result **must**
  be scoped to this node's owner id — a global list would let one node reap
  another's sandboxes. Backends that cannot outlive their session return
  `{:ok, []}`.
  """
  @callback list_live(opts :: keyword()) :: {:ok, [handle()]} | {:error, term()}

  @doc """
  Re-establish control of a sandbox that outlived its session.

  Backends without durable sandboxes return `{:error, :not_supported}`.
  """
  @callback reattach(handle(), cursor()) :: {:ok, handle()} | {:error, term()}

  @doc "Copy a local workspace into the sandbox. Optional; no backend ships this yet."
  @callback push_workspace(handle(), Path.t()) :: :ok | {:error, term()}

  @doc "Copy artifacts out of the sandbox. Optional; no backend ships this yet."
  @callback pull_artifacts(handle(), Path.t()) :: :ok | {:error, term()}

  @doc """
  Return a copy of `handle` with credentials removed, for persistence.

  A handle often carries the backend config it was built from, and that config
  can contain an API key. `CrowdControl.Store` records outlive the VM — on disk,
  with `Store.DETS` — so a handle must be safe to write down. Nothing about
  reattaching needs a credential: the sandbox already has its environment.

  Optional; backends whose handles hold nothing sensitive can omit it.
  """
  @callback scrub(handle()) :: handle()

  @optional_callbacks push_workspace: 2, pull_artifacts: 2, scrub: 1

  @doc """
  Scrub `handle` via the backend's `c:scrub/1`, if it defines one.

  Returns the handle untouched for backends that do not.
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
  Resolve the `:backend` option into `{module, opts}`.

  Accepts a bare module or a `{module, config}` tuple, and merges any config
  into `opts`. Defaults to `CrowdControl.Backend.Local`.

      iex> CrowdControl.Backend.resolve([])
      {CrowdControl.Backend.Local, []}

      iex> CrowdControl.Backend.resolve(backend: {CrowdControl.Backend.Local, image: "x"})
      {CrowdControl.Backend.Local, [image: "x"]}
  """
  @spec resolve(keyword()) :: {module(), keyword()}
  def resolve(opts) do
    rest = Keyword.delete(opts, :backend)

    case Keyword.get(opts, :backend, CrowdControl.Backend.Local) do
      {module, config} when is_atom(module) and is_list(config) ->
        {module, Keyword.merge(rest, config)}

      module when is_atom(module) and not is_nil(module) ->
        {module, rest}

      other ->
        raise ArgumentError,
              ":backend must be a module or {module, keyword}, got: #{inspect(other)}"
    end
  end

  @doc """
  A cursor pointing at the start of the stream.

      iex> CrowdControl.Backend.new_cursor()
      %{byte_offset: 0, buffer: ""}
  """
  @spec new_cursor() :: cursor()
  def new_cursor, do: %{byte_offset: 0, buffer: ""}

  @doc """
  Whether `module` can reattach to a sandbox that outlived its session.

  `Session` uses this to decide whether persisting to `CrowdControl.Store` is
  worth the per-chunk write. A backend whose sandbox dies with the session has
  nothing to reattach to, so the write would be pure overhead.
  """
  @spec reattachable?(module()) :: boolean()
  def reattachable?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :reattachable?, 0) and
      module.reattachable?()
  end

  @doc """
  Run `fun`, returning `default` if it exits.

  Every teardown-path call into a backend goes through this. The discipline it
  encodes is narrow on purpose:

    * `NetRunner.Process.{await_exit,alive?,kill}` are `GenServer.call`s, so a
      dead or stale daemon raises an `:exit`, never an `:error`. Catching that
      is the difference between a tidy shutdown and a crashed session.
    * It catches **only** `:exit`. A `rescue` here would swallow genuine bugs —
      `UndefinedFunctionError`, `FunctionClauseError`, a typo in a backend —
      and turn them into silent "sandbox unavailable". Those must surface.

  Remote backends have failure shapes that are not exits at all
  (`{:error, %Req.TransportError{}}`, an HTTP 500, a `:timeout`). Normalize
  those **inside the backend**, before they reach `Session`, so that `Session`
  keeps having exactly one failure vocabulary to handle.
  """
  @spec safe((-> result), default) :: result | default when result: term(), default: term()
  def safe(fun, default) when is_function(fun, 0) do
    fun.()
  catch
    :exit, _ -> default
  end
end
