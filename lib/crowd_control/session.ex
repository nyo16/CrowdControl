defmodule CrowdControl.Session do
  @moduledoc """
  GenServer managing a single coding-agent CLI instance.

  Each session drives a `CrowdControl.Backend` — a local subprocess by default,
  or a container — plus a linked reader process that delivers stdout. The
  session buffers partial lines, decodes JSON messages, and broadcasts them to
  subscribers. Everything from line splitting onward is transport-agnostic: the
  session never learns which backend it is talking to.

  Subscribers receive messages of the form `{:crowd_control, session_pid, payload}`
  where `payload` is one of `t:CrowdControl.Protocol.message/0`,
  `{:exit, exit_status}`, `{:timeout, :session_expired}`, or `{:error, reason}`
  (e.g. `{:error, :line_too_large}` when a single newline-free output line
  exceeds `:max_line_bytes`, or `{:error, {:write_failed, reason}}` when a
  prompt or control answer could not be written to the CLI).

  Control frames are the session's business, not the subscribers': answers to
  the session's own requests, `keep_alive` heartbeats and incoming control
  requests are not broadcast. Subscribers see a control request only when its
  callback defers it (see "Control protocol" below).

  ## Options

  Session-lifecycle options (CLI/argv options are forwarded to the agent
  adapter's `build_command/1`, e.g. `CrowdControl.CLI.build_command/1`):

    * `:agent` - `CrowdControl.Agent` adapter selecting the CLI dialect:
      `:claude` (default), `:open_code`, `:omp`, or a module. Inferred from
      `:executable` when omitted.
    * `:backend` - `CrowdControl.Backend` implementation, either a module or a
      `{module, config}` tuple whose config is merged into these opts. Defaults
      to `CrowdControl.Backend.Local`. What a reattachable backend persists is
      scrubbed by `CrowdControl.Store.scrub_opts/1`: credentials, service `:env`
      and `:files` are dropped at every level, including inside this tuple.
    * `:prompt` - initial prompt sent once the CLI starts (optional)
    * `:timeout` - ceiling in ms on a single **turn**, after which the session
      self-expires and broadcasts `{:timeout, :session_expired}`. The timer is
      armed at start and re-armed by `send_prompt/2` — **not** by output, so a
      turn that streams for longer than this is still killed mid-flight. Size it
      against the slowest turn you expect, not the length of the conversation;
      long autonomous tasks against a self-hosted model routinely need more than
      the default. Use `:infinity` or `nil` to disable. Defaults to `300_000`.
      The timer is paused while a permission request (or a deferred hook) is
      waiting on an answer, and a reattached session keeps the deadline it had.
    * `:max_prompt_size` - reject prompts whose byte size exceeds this with
      `{:error, :prompt_too_large}` (optional; unbounded when unset)
    * `:max_line_bytes` - cap for a single newline-free output line. Exceeding it
      kills the subprocess and broadcasts `{:error, :line_too_large}` rather than
      buffering an unbounded remainder. Defaults to `1_048_576` (1 MiB).
    * `:max_stream_bytes` - cap on a session's **total** output. Exceeding it
      destroys the sandbox and broadcasts `{:error, :stream_too_large}`. Mainly
      for remote backends, whose output file grows without bound; unbounded when
      unset.
    * `:max_messages` - cap on messages retained for `get_messages/1`; oldest are
      dropped past the cap. Live subscribers are unaffected. Clamped to `>= 0`.
      Defaults to `10_000`.

  ## Control protocol

  An agent with the `:control` capability (`CrowdControl.Agent.ClaudeCode`)
  speaks the stream-json control protocol. These options switch it on; each
  callback is an MFA tuple `{module, function, extra_args}`, called as
  `apply(module, function, [request, context | extra_args])`. Funs are refused
  at start with `ArgumentError`, because session options are persisted and a
  closure cannot be; so are funs, pids, references and ports anywhere inside
  `extra_args`. `extra_args` are persisted to `CrowdControl.Store` as given, so
  they **must not hold secrets**: look a credential up inside the callback. The
  options may be given at top level or inside a `backend: {module, config}`
  tuple; either way a reattached session keeps them.

    * `:can_use_tool` - answers the CLI's tool-permission requests. `request` is
      the `can_use_tool` request map (`"tool_name"`, `"input"`,
      `"tool_use_id"`, ...). Returns `{:allow, input}`, `{:allow, input,
      permission_updates}`, `{:deny, message}`, `{:deny, message, interrupt:
      true}` or `:defer`. The input is always sent back as `updatedInput`, so
      pass the original to allow it unchanged.
    * `:hooks` - hook callbacks, see `CrowdControl.Agent.ClaudeCode`. Each
      returns `{:ok, hook_output}`, `{:error, message}` or `:defer`.
    * `:sdk_mcp_servers` - a map of name to `CrowdControl.SdkMcp.tool_server/2`
      spec, answered in-BEAM.
    * `:on_control_request` - any other CLI request subtype; returns
      `{:ok, response}`, `{:error, message}` or `:defer`. Without it such a
      request is answered with an error, so the CLI never waits.
    * `:permission_timeout` - ms a permission request may stay unanswered before
      it is denied with `"permission timed out"`. Defaults to `:infinity`.
    * `:interrupt_grace` - when the turn deadline passes, an `:interrupt`-capable
      agent is first sent `interrupt`, and the sandbox is destroyed only if no
      result arrives within this many ms. Defaults to `30_000` for sessions using
      a control feature and to `0` (destroy at the deadline) otherwise.

  `context` is `%{session: pid, store_key: key, request_id: id, subtype: subtype}`.
  Callbacks run under `CrowdControl.CallbackSupervisor`, so one that blocks on a
  human never stalls the session. A callback that crashes, or returns anything
  else, is answered as a failure (a deny for a permission request).

  A callback that returns `:defer` leaves the request pending; subscribers get
  `{:control_request, request_id, subtype, request}` (again on every later
  `subscribe/1`) and answer it with `respond/3`. When the CLI withdraws a
  request it is dropped and subscribers get `{:control_cancelled, request_id}`.

  A request the session has persisted but not answered survives a host restart:
  on reattach the session re-sends `initialize`, takes the CLI's
  `pending_permission_requests` as the truth for permission requests, and runs
  the rest again. Callbacks are therefore **at-least-once**; make them
  idempotent by `request_id`. An MCP tool call is re-run only if the tool is
  declared `idempotent: true`; otherwise the CLI gets a JSON-RPC error.

  A session using a control feature refuses a Claude Code older than
  `CrowdControl.CLI.min_version/0`: `CrowdControl.Backend.Local` checks
  `--version` before spawning (start fails with `{:cli_version, have, need}`),
  and every backend checks the `system/init` frame, broadcasting
  `{:error, {:cli_version, have, need}}` and stopping.
  """

  # :transient, not :temporary. `:temporary` is right when the OS process dies
  # with the GenServer -- and exactly backwards when a *billed* remote sandbox
  # outlives it. A transient child is restarted on abnormal exit, which is what
  # gives CrowdControl.Reaper a session to reattach the surviving sandbox to.
  # Normal exits (`:normal`, `:shutdown`) are still not restarted, so an ordinary
  # completed session does not respawn and does not hold a `:max_children` slot.
  use GenServer, restart: :transient

  require Logger

  alias CrowdControl.{Agent, Backend, CLI, Protocol, Result, SdkMcp, Store, Telemetry}
  alias CrowdControl.Backend.Shell
  alias CrowdControl.Session.Control

  @default_timeout 300_000
  # 1 MiB, matching the `maxFrameBytes` omp advertises in its ready frame. A
  # lower cap would destroy a session over a frame omp considers legal, which
  # is a worse failure than the 48 KiB of extra headroom this costs.
  @default_max_line_bytes 1_048_576
  @default_max_messages 10_000

  # The host-side wait for a control request's answer; the CLI has none.
  @control_timeout 60_000
  # How long a reattached session waits for its `initialize` reply before it
  # falls back to the permission requests it persisted.
  @reattach_reply_timeout 60_000
  @version_check_timeout 10_000

  # Control opts a reattached session needs at top level of its record; see
  # persisted_opts/2.
  @control_opts [
    :can_use_tool,
    :hooks,
    :sdk_mcp_servers,
    :on_control_request,
    :permission_timeout,
    :interrupt_grace
  ]

  defstruct [
    :agent,
    :backend,
    :backend_state,
    :reader,
    :session_id,
    :store_key,
    :owner,
    :opts,
    # The backend-merged option list. `:opts` is what gets persisted and
    # re-derived from; `:agent_opts` is what the adapter's framing callbacks
    # see, so an option written inside a `{Backend, config}` tuple reaches
    # them the same way it already reaches build_command/1.
    :agent_opts,
    :timeout,
    :timeout_ref,
    :max_prompt_size,
    :exit_status,
    :max_line_bytes,
    :max_stream_bytes,
    :max_messages,
    # Monotonic start, for the session stop event's duration.
    :started_at,
    # Set by a line that ends the session (a too-old CLI); consume_lines stops.
    :fatal,
    # Total cost reported by the previous result, for the per-turn delta.
    :last_cost_usd,
    status: :starting,
    exited: false,
    persist?: false,
    subscribers: [],
    buffer: "",
    byte_offset: 0,
    messages: [],
    message_count: 0,
    prompt_seq: 0,
    # Monotonic times of prompts still waiting on their result, oldest first.
    turn_starts: [],
    control: %Control{}
  ]

  @type t :: %__MODULE__{}
  @type session :: pid()
  @type status :: :starting | :running | :completed | :error

  @typedoc """
  An answer for `respond/3`: a `t:CrowdControl.Protocol.permission_decision/0`
  for `can_use_tool`, `{:ok, map} | {:error, message}` for any other subtype.
  """
  @type decision :: Protocol.permission_decision() | Protocol.control_result()

  @typedoc "A pending CLI request, as listed by `pending_requests/1`."
  @type pending_request :: %{
          request_id: Protocol.request_id(),
          subtype: String.t(),
          request: map(),
          status: :received | :dispatched | :deferred
        }

  # --- Public API ---

  @doc "Start a session linked to the caller."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a user prompt to the CLI subprocess.

  Returns `:ok` on success or `{:error, reason}` where reason is one of
  `:invalid_prompt`, `:prompt_too_large`, `:completed`, `:error`. A write that
  fails after validation is broadcast as `{:error, {:write_failed, reason}}`.
  """
  @spec send_prompt(session(), binary()) :: :ok | {:error, atom()}
  def send_prompt(session, prompt) do
    GenServer.call(session, {:send_prompt, prompt})
  end

  @doc "Get the current session status."
  @spec get_status(session()) :: status()
  def get_status(session) do
    GenServer.call(session, :get_status)
  end

  @doc "Get the session ID (assigned by the CLI on init)."
  @spec get_session_id(session()) :: String.t() | nil
  def get_session_id(session) do
    GenServer.call(session, :get_session_id)
  end

  @doc """
  The turn currently in flight, i.e. the number of prompts written so far.

  Every `{:result, _, map}` carries the same number under `"turn"`. A collector
  that reads this *before* subscribing can tell a replayed result from an
  earlier turn apart from the one it is waiting for; see `CrowdControl.collect/2`.
  Returns `0` for a session that has not been prompted.
  """
  @spec current_turn(session()) :: non_neg_integer()
  def current_turn(session) do
    GenServer.call(session, :current_turn)
  end

  @doc """
  Subscribe the calling process to receive session messages.

  History is replayed first, then every control request still deferred, then
  the exit if the CLI has already exited.
  """
  @spec subscribe(session()) :: :ok
  def subscribe(session) do
    GenServer.call(session, {:subscribe, self()})
  end

  @doc """
  Get accumulated messages in chronological order.

  Retention is capped at `:max_messages` (default #{@default_max_messages}); once
  the cap is reached the oldest messages are dropped so the returned list is a
  bounded, newest-biased window. Live subscribers (see `subscribe/1`) receive
  every message regardless of this cap.
  """
  @spec get_messages(session()) :: [Protocol.message()]
  def get_messages(session) do
    GenServer.call(session, :get_messages)
  end

  @doc "Gracefully stop the session."
  @spec stop(session()) :: :ok
  def stop(session) do
    GenServer.call(session, :stop, 10_000)
  end

  @doc """
  Answer a pending CLI control request, typically one a callback deferred.

  `decision` is a `t:CrowdControl.Protocol.permission_decision/0` for
  `can_use_tool` and `{:ok, map} | {:error, message}` for any other subtype. A
  callback still running for the request is cancelled. An unknown (or already
  answered) `request_id` is a no-op returning `:ok`.
  """
  @spec respond(session(), Protocol.request_id(), decision()) ::
          :ok | {:error, :unsupported | {:invalid_decision, term()}}
  def respond(session, request_id, decision) when is_binary(request_id) do
    GenServer.call(session, {:respond, request_id, decision})
  end

  @doc """
  Interrupt the turn in progress without killing the CLI. The CLI withdraws any
  pending permission request (`{:control_cancelled, id}`) and ends the turn
  with a result that `CrowdControl.Result.classify/1` reports as `:aborted`.

  Needs the `:interrupt` capability; see `control/3` for the return value.
  """
  @spec interrupt(session()) :: {:ok, map()} | {:error, term()}
  def interrupt(session),
    do: request(session, %{"subtype" => "interrupt"}, @control_timeout, :interrupt)

  @doc "Switch the model for later turns; `nil` resets it to the default. See `control/3`."
  @spec set_model(session(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def set_model(session, model) when is_binary(model) or is_nil(model),
    do:
      request(session, %{"subtype" => "set_model", "model" => model}, @control_timeout, :control)

  @doc """
  Switch the permission mode (`"default"`, `"acceptEdits"`, `"plan"`,
  `"bypassPermissions"`, ...). See `control/3`.
  """
  @spec set_permission_mode(session(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_permission_mode(session, mode) when is_binary(mode) do
    request(
      session,
      %{"subtype" => "set_permission_mode", "mode" => mode},
      @control_timeout,
      :control
    )
  end

  @doc """
  Send a host-originated control request and wait for the CLI's answer.

  `request` carries its `"subtype"`; the session mints the `request_id`
  (`req_<n>_<hex>`). Returns `{:ok, response}` or `{:error, message}` as the CLI
  answered, `{:error, :timeout}` after `timeout` ms, `{:error, {:write_failed,
  reason}}`, `{:error, :closed}` when the session tears down first, or
  `{:error, :unsupported}` for an agent without the `:control` capability.
  """
  @spec control(session(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def control(session, %{"subtype" => subtype} = request, timeout \\ @control_timeout)
      when is_binary(subtype),
      do: request(session, request, timeout, :control)

  @doc """
  The CLI control requests not yet answered, oldest first, or
  `{:error, :unsupported}` for an agent without the `:control` capability.
  """
  @spec pending_requests(session()) :: {:ok, [pending_request()]} | {:error, :unsupported}
  def pending_requests(session) do
    GenServer.call(session, :pending_requests)
  end

  defp request(session, request, timeout, capability) do
    GenServer.call(session, {:control, request, timeout, capability}, call_timeout(timeout))
  end

  # The session answers `{:error, :timeout}` itself; the call's own timeout is a
  # backstop for a session that cannot answer at all.
  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(ms) when is_integer(ms) and ms >= 0, do: ms + 5_000

  # --- GenServer Callbacks ---

  @doc """
  Start a session that takes over a sandbox which outlived its previous session.

  `record` comes from `CrowdControl.Store`. Used by `CrowdControl.Reaper`; you
  rarely call this directly.
  """
  @spec start_reattached(Store.t()) :: GenServer.on_start()
  def start_reattached(record) do
    GenServer.start_link(__MODULE__, {:reattach, record})
  end

  @impl true
  def init({:reattach, record}) do
    backend = record.backend
    cursor = %{byte_offset: record.byte_offset, buffer: record.buffer}

    Logger.info(
      "Reattaching session #{record.key}: backend=#{inspect(backend)}, " <>
        "offset=#{record.byte_offset}, buffer=#{byte_size(record.buffer)}B"
    )

    with {:ok, handle} <- backend.reattach(record.handle, cursor),
         {:ok, reader} <- reader_or_destroy(backend, handle, cursor) do
      agent = Agent.resolve(record.opts)
      # The record holds the scrubbed opts, `backend: {mod, config}` tuple
      # included, so merging them again yields what init/1 ran with, minus the
      # credentials. Control opts given inside the tuple live there too.
      {_backend, merged} = Backend.resolve(record.opts)

      state = %__MODULE__{
        agent: agent,
        backend: backend,
        backend_state: handle,
        reader: reader,
        store_key: record.key,
        owner: record.owner,
        session_id: record.session_id,
        persist?: Backend.reattachable?(backend),
        # Scrubbed again so a record written before the scrub recursed into
        # `backend:` loses its nested credentials on the next write.
        opts: Store.scrub_opts(record.opts),
        agent_opts: merged,
        timeout: Keyword.get(record.opts, :timeout, @default_timeout),
        max_prompt_size: Keyword.get(record.opts, :max_prompt_size),
        max_line_bytes: bound_opt!(record.opts, :max_line_bytes, @default_max_line_bytes),
        max_stream_bytes: Keyword.get(record.opts, :max_stream_bytes),
        max_messages: bound_opt!(record.opts, :max_messages, @default_max_messages),
        # The cursor is seeded here, in the state init/1 returns, which is
        # necessarily before any {:stdout_data, _} cast is processed -- the
        # GenServer does not touch its mailbox until init/1 has returned. So the
        # partial line is in place before the first resumed byte arrives, and
        # the two rejoin exactly.
        buffer: record.buffer,
        byte_offset: record.byte_offset,
        # Subscribers are pids from a previous VM state and are meaningless now.
        # Callers re-subscribe/1; this is expected, not a gap.
        subscribers: [],
        status: :running,
        control: merged |> Control.new(agent) |> Control.restore(Map.get(record, :control))
      }

      # :reattach_control runs before any stdout cast, so the `initialize` is
      # written and the replayed lines are deduped against the restored set.
      {:ok, state |> restore_deadline() |> session_started(), {:continue, :reattach_control}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def init(opts) do
    {backend, backend_opts} = Backend.resolve(opts)

    # Minted before provisioning so the sandbox can be labelled with it. See
    # CrowdControl.Store's "Two different ids" -- this is not the CLI's id.
    store_key = Store.new_key()
    backend_opts = Keyword.put(backend_opts, :session_key, store_key)

    # This MUST be resolved the same way the backend resolves the owner it stamps
    # onto the sandbox. If the record's owner and the sandbox's label can differ,
    # the reaper sees live sandboxes with no matching record and destroys every
    # one of them as an orphan.
    owner = backend_opts[:owner] || Store.owner_id()
    backend_opts = Keyword.put(backend_opts, :owner, owner)

    agent = Agent.resolve(backend_opts)

    # Pin the resolved module into the opts the store persists, so a reattached
    # session cannot re-derive a *different* adapter from a backend config that
    # is no longer in scope.
    opts = Keyword.put(opts, :agent, agent)

    {executable, args, env} = agent.build_command(backend_opts)

    Logger.info(
      "Starting session: backend=#{inspect(backend)}, agent=#{inspect(agent)}, " <>
        "executable=#{executable}, model=#{backend_opts[:model] || "default"}"
    )

    # Bounds and callbacks are validated before provisioning so that a bad
    # option raises without having created (and leaked) a sandbox first.
    max_line_bytes = bound_opt!(opts, :max_line_bytes, @default_max_line_bytes)
    max_messages = bound_opt!(opts, :max_messages, @default_max_messages)
    control = Control.new(backend_opts, agent)
    meta = %{store_key: store_key, agent: agent, backend: backend}

    with :ok <- check_cli_version(backend, control, executable, env, backend_opts),
         {:ok, handle, reader} <-
           start_backend(backend, backend_opts, executable, args, env, meta) do
      state = %__MODULE__{
        agent: agent,
        backend: backend,
        backend_state: handle,
        reader: reader,
        store_key: store_key,
        owner: owner,
        persist?: Backend.reattachable?(backend),
        opts: persisted_opts(opts, backend_opts),
        agent_opts: backend_opts,
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        max_prompt_size: Keyword.get(opts, :max_prompt_size),
        max_line_bytes: max_line_bytes,
        max_stream_bytes: Keyword.get(opts, :max_stream_bytes),
        max_messages: max_messages,
        control: control
      }

      start_turn(schedule_timeout(state), opts)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # The opts a reattach starts from, computed once rather than per store write.
  # Control opts may have come from inside `backend: {mod, config}`; they are
  # lifted to the top level so the record names them wherever they were given
  # (they are MFA-only, so plain data -- see Control.check_extra_args!/2).
  # Then the whole list, tuple included, is scrubbed of credentials.
  defp persisted_opts(opts, backend_opts) do
    opts
    |> Keyword.merge(Keyword.take(backend_opts, @control_opts))
    |> Store.scrub_opts()
  end

  # A failed handshake is fatal, not something to discover via the inactivity
  # timeout minutes later: for omp it means no `get_state`, so no session id
  # and no `{:system_init, _}` ever.
  defp start_turn(state, opts) do
    case write_init_frames(state) do
      {:ok, state} ->
        state = session_started(state)
        {:ok, maybe_prompt(state, Keyword.get(opts, :prompt))}

      {:error, reason} ->
        # init/1 returning :stop does not run terminate/2, so the sandbox has
        # to be torn down here or a billed container leaks.
        destroy_backend(state)
        {:stop, reason}
    end
  end

  defp maybe_prompt(state, nil), do: state
  defp maybe_prompt(state, prompt), do: do_send_prompt(state, prompt)

  # provision -> exec -> start_reader, tearing down whatever was created if a
  # later step fails. Without the destroy/1 on the error paths, a backend that
  # provisions a billed sandbox and then fails to exec would leak it silently.
  defp start_backend(backend, opts, executable, args, env, meta) do
    with {:ok, handle} <- provision(backend, opts, meta),
         {:ok, handle} <- exec_or_destroy(backend, handle, executable, args, env),
         {:ok, reader} <- reader_or_destroy(backend, handle, Backend.new_cursor()) do
      {:ok, handle, reader}
    end
  end

  defp provision(backend, opts, meta) do
    Telemetry.span([:crowd_control, :backend, :provision], meta, fn ->
      result = backend.provision(opts)
      {result, Map.put(meta, :result, if(match?({:ok, _}, result), do: :ok, else: :error))}
    end)
  end

  defp exec_or_destroy(backend, handle, executable, args, env) do
    case backend.exec(handle, executable, args, env) do
      {:ok, handle} -> {:ok, handle}
      {:error, reason} -> destroy_and_return(backend, handle, reason)
    end
  end

  defp reader_or_destroy(backend, handle, cursor) do
    case backend.start_reader(handle, self(), cursor) do
      {:ok, reader} -> {:ok, reader}
      {:error, reason} -> destroy_and_return(backend, handle, reason)
    end
  end

  defp destroy_and_return(backend, handle, reason) do
    backend.destroy(handle)
    {:error, reason}
  end

  # A local CLI can be asked its version before anything exists, so a too-old
  # one fails the start instead of failing mid-session. Remote CLIs live in the
  # sandbox image and are checked at `system/init` instead.
  defp check_cli_version(Backend.Local, %Control{features?: true}, executable, env, opts) do
    case local_cli_version(executable, probe_env(env, opts)) do
      {:ok, have} -> version_gate(have)
      :unknown -> :ok
    end
  end

  defp check_cli_version(_backend, _control, _executable, _env, _opts), do: :ok

  # The probe runs the same binary the session is about to spawn, so it gets
  # the same release scrub `CrowdControl.Backend.Local` applies: `System.cmd/3`
  # only adds to the inherited environment, so each scrubbed name is unset
  # (`{name, nil}`) and the release-free `PATH` exported. An explicit `:env`
  # entry still wins, as under Local. Anything but `release_env: :inherit`
  # scrubs; Local refuses an unknown value at provision.
  defp probe_env(env, opts) do
    scrub =
      case Keyword.get(opts, :release_env, :scrub) do
        :inherit ->
          %{}

        _scrub ->
          {unset, path} = Shell.release_scrub(System.get_env())
          scrubbed = Map.new(unset, &{&1, nil})
          if path, do: Map.put(scrubbed, "PATH", path), else: scrubbed
      end

    scrub |> Map.merge(env) |> Map.to_list()
  end

  # `:unknown` (no binary, no Claude Code banner, a hang) skips the gate: the
  # spawn then fails, or system/init decides.
  defp local_cli_version(executable, env) do
    task =
      Task.async(fn ->
        try do
          System.cmd(executable, ["--version"], stderr_to_stdout: true, env: env)
        rescue
          _ in [ErlangError, ArgumentError] -> :error
        end
      end)

    with {:ok, {output, 0}} <-
           Task.yield(task, @version_check_timeout) || Task.shutdown(task, :brutal_kill),
         [_, have] <- Regex.run(~r/(\d+\.\d+\.\d+\S*)\s+\(Claude Code\)/, output) do
      {:ok, have}
    else
      _ -> :unknown
    end
  end

  defp version_gate(have) do
    need = CLI.min_version()

    case Version.parse(have) do
      {:ok, version} ->
        if Version.compare(version, need) == :lt,
          do: {:error, {:cli_version, have, need}},
          else: :ok

      :error ->
        :ok
    end
  end

  @impl true
  def handle_call({:send_prompt, prompt}, _from, state) do
    case validate_prompt(prompt, state.max_prompt_size) do
      :ok ->
        case state.status do
          status when status in [:starting, :running] ->
            state = state |> do_send_prompt(prompt) |> schedule_timeout()
            persist(state)
            {:reply, :ok, state}

          # A result ends a *turn*, not the process: `omp --mode rpc` and
          # `claude --input-format stream-json` both keep reading stdin
          # afterwards. Rejecting here would make multi-turn conversations
          # impossible for every CLI that outlives its first result. Only an
          # exited subprocess (`exited: true`, set on EOF) is really terminal.
          :completed when not state.exited ->
            state = %{state | status: :running} |> do_send_prompt(prompt) |> schedule_timeout()
            persist(state)
            {:reply, :ok, state}

          status ->
            {:reply, {:error, status}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:current_turn, _from, state) do
    {:reply, state.prompt_seq, state}
  end

  def handle_call(:get_session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    replay_history(state, pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  def handle_call(:stop, _from, state) do
    state = destroy_backend(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:respond, _id, _decision}, _from, %{control: %{capable?: false}} = state),
    do: {:reply, {:error, :unsupported}, state}

  def handle_call({:respond, request_id, decision}, _from, state) do
    with {key, entry} <- Control.find(state.control, request_id),
         reply when is_tuple(reply) <- Control.reply(entry, decision) do
      state = state |> answer(key, reply, :respond) |> settle()
      {:reply, :ok, state}
    else
      nil -> {:reply, :ok, state}
      _defer_or_invalid -> {:reply, {:error, {:invalid_decision, decision}}, state}
    end
  end

  def handle_call({:control, request, timeout, capability}, from, state) do
    if Agent.capable?(state.agent, capability) do
      {id, control} = Control.next_request_id(state.control)
      state = put_control(state, control)

      case write_frame(
             state,
             state.agent.encode_control({:request, id, request}, state.agent_opts)
           ) do
        :ok -> {:noreply, track_outbound(state, id, from, timeout)}
        {:error, reason} -> {:reply, {:error, {:write_failed, reason}}, state}
      end
    else
      {:reply, {:error, :unsupported}, state}
    end
  end

  def handle_call(:pending_requests, _from, %{control: %{capable?: true} = control} = state),
    do: {:reply, {:ok, Control.list(control)}, state}

  def handle_call(:pending_requests, _from, state), do: {:reply, {:error, :unsupported}, state}

  @impl true
  def handle_cast({:stdout_data, data}, state) do
    buffer = state.buffer <> data
    {lines, remainder} = Protocol.split_lines(buffer)

    cond do
      byte_size(remainder) > state.max_line_bytes ->
        stop_line_too_large(state)

      exceeds_stream_cap?(state, byte_size(data)) ->
        stop_stream_too_large(state)

      true ->
        # Where the first complete line starts in the CLI's output: the partial
        # line carried over sits at the end of every byte delivered so far. A
        # control request is keyed by this offset, which is the same however
        # the bytes were chunked -- so a replayed request is recognisable.
        line_offset = state.byte_offset - byte_size(state.buffer)

        # Both halves of the cursor advance here, in one clause. `byte_offset`
        # counts every byte the reader has delivered; `buffer` is the partial line
        # among them that has not been consumed yet. Reattach reads from the
        # offset and prepends the buffer, so a line split across a crash rejoins
        # exactly -- which only holds if these two can never disagree.
        state = %{
          state
          | buffer: remainder,
            byte_offset: state.byte_offset + byte_size(data)
        }

        state
        |> consume_lines(lines, line_offset)
        |> lines_consumed(byte_size(data))
    end
  end

  def handle_cast(:eof, state) do
    exit_status =
      case await_exit(state, 1_000) do
        {:ok, status} -> status
        _ -> nil
      end

    status = if exit_status == 0 or state.status == :completed, do: :completed, else: :error
    state = %{state | status: status, exited: true, exit_status: exit_status}

    if status == :error do
      Logger.warning("Session exited with error, exit_status=#{inspect(exit_status)}")
    else
      Logger.info("Session completed, exit_status=#{inspect(exit_status)}")
    end

    # Destroy before broadcasting: a subscriber that receives {:exit, _} is
    # entitled to assume the sandbox and its env file are already gone.
    state = destroy_backend(state)
    broadcast(state, {:exit, exit_status})
    {:noreply, state}
  end

  @impl true
  def handle_continue(:dispatch_control, state) do
    {:noreply, state |> dispatch_received() |> settle()}
  end

  def handle_continue(:reattach_control, %{control: control} = state) do
    if control.features? or map_size(control.pending) > 0 do
      state =
        state
        |> write_reattach_frames()
        |> answer_unrecoverable()
        |> dispatch_received()
        |> settle()

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, ref, :session_timeout}, %{timeout_ref: ref} = state),
    do: on_deadline(%{state | timeout_ref: nil})

  def handle_info({:timeout, ref, :interrupt_grace}, %{control: %{grace_ref: ref}} = state) do
    Logger.warning("Session produced no result within interrupt_grace after its deadline")
    expire(state)
  end

  def handle_info({:timeout, ref, {:permission_timeout, key}}, state) do
    with ^ref <- Map.get(state.control.permission_timers, key),
         {:ok, _entry} <- Map.fetch(state.control.pending, key) do
      Logger.warning("Permission request #{elem(key, 0)} timed out; denying")

      state
      |> answer(key, {:permission, {:deny, "permission timed out"}}, :timeout)
      |> settle()
      |> noreply()
    else
      _stale -> {:noreply, state}
    end
  end

  def handle_info({:timeout, ref, {:control_timeout, id}}, state) do
    case Map.fetch(state.control.outbound, id) do
      {:ok, %{timer: ^ref}} -> state |> outbound_timeout(id) |> settle() |> noreply()
      _stale -> {:noreply, state}
    end
  end

  # A timer cancelled after it had already fired: its ref no longer matches.
  def handle_info({:timeout, _ref, _stale}, state), do: {:noreply, state}

  def handle_info({:control_result, key, result}, state) do
    state
    |> take_task(key)
    |> callback_result(key, result)
    |> settle()
    |> noreply()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.control.tasks, fn {_key, {_pid, mref}} -> mref == ref end) do
      nil ->
        {:noreply, state}

      {key, _task} ->
        state |> take_task(key) |> callback_down(key, reason) |> settle() |> noreply()
    end
  end

  @impl true
  def terminate(reason, state) do
    state = destroy_backend(state)
    session_stopped(state, reason)
    :ok
  end

  # --- Private ---

  # These two options are resource-exhaustion guards, and Erlang term ordering
  # puts every number below every atom -- so `byte_size(x) > nil` is always
  # false and `max(nil, 0)` is nil. Passing nil (the shape you get straight out
  # of an unset `Application.get_env/2`) would therefore switch the guard OFF
  # silently, which is the exact opposite of what the caller intended. Treat nil
  # as "unset" and fall back to the default; reject anything else loudly.
  defp bound_opt!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n >= 0 ->
        n

      nil ->
        default

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a non-negative integer or nil, got: #{inspect(other)}"
    end
  end

  defp validate_prompt(prompt, _max) when not is_binary(prompt), do: {:error, :invalid_prompt}

  defp validate_prompt(prompt, max) do
    cond do
      not String.valid?(prompt) -> {:error, :invalid_prompt}
      String.contains?(prompt, <<0>>) -> {:error, :invalid_prompt}
      is_integer(max) and byte_size(prompt) > max -> {:error, :prompt_too_large}
      true -> :ok
    end
  end

  # Every write to the CLI goes through here, so a failure is always seen.
  @spec write_frame(t(), iodata()) :: :ok | {:error, term()}
  defp write_frame(%{backend_state: nil}, _frame), do: {:error, :closed}
  defp write_frame(state, frame), do: state.backend.write(state.backend_state, frame)

  # Handshake frames the CLI needs before it will behave (omp's `get_state`,
  # which is what makes a session id observable). Written before the initial
  # prompt so the id lands first, exactly where Claude Code emits its own
  # system/init.
  @spec write_init_frames(t()) :: {:ok, t()} | {:error, term()}
  defp write_init_frames(state) do
    state.agent.init_frames(state.agent_opts)
    |> Enum.reduce_while({:ok, state}, fn frame, {:ok, acc} ->
      case write_frame(acc, frame) do
        :ok -> {:cont, {:ok, track_init_frame(acc, frame)}}
        {:error, reason} -> {:halt, {:error, {:handshake_failed, reason}}}
      end
    end)
  end

  defp do_send_prompt(state, prompt) do
    encoded = state.agent.encode_prompt(prompt, state.prompt_seq, state.agent_opts)
    state = %{state | prompt_seq: state.prompt_seq + 1}

    case write_frame(state, encoded) do
      :ok ->
        turn_started(state)

      {:error, reason} ->
        Logger.error("Session could not write prompt: #{inspect(reason)}")
        broadcast(state, {:error, {:write_failed, reason}})
        state
    end
  end

  defp await_exit(%{backend_state: nil}, _timeout), do: :timeout

  defp await_exit(state, timeout), do: state.backend.await_exit(state.backend_state, timeout)

  # Clearing :backend_state is what keeps teardown idempotent across the four
  # paths that can reach it (:eof, :stop, :session_timeout, terminate/2) --
  # backends are required to tolerate a repeat destroy/1 anyway, but not calling
  # it twice is cheaper and keeps the "already torn down" state explicit.
  defp destroy_backend(%{backend_state: nil} = state), do: state

  defp destroy_backend(state) do
    state.backend.destroy(state.backend_state)
    # Drop the record in the same breath as the sandbox. A record outliving its
    # sandbox is worse than no record: the reaper would try to reattach to a
    # container that no longer exists.
    forget(state)
    shutdown_control(%{state | backend_state: nil})
  end

  # Persistence is skipped entirely for backends that cannot reattach -- a store
  # write per stdout chunk is real overhead, and Backend.Local has nothing to
  # reattach to. A torn-down session must not write either, or a late callback
  # result would resurrect the record destroy_backend/1 just deleted.
  defp persist(%{persist?: false}), do: :ok
  defp persist(%{backend_state: nil}), do: :ok

  defp persist(state) do
    Store.put(
      state.store_key,
      Store.build(
        key: state.store_key,
        session_id: state.session_id,
        backend: state.backend,
        # Both the handle and the opts are scrubbed of credentials before they
        # touch the store -- a record can outlive the VM on disk, and nothing
        # about reattaching needs an API key. `state.opts` was scrubbed once,
        # by persisted_opts/2 (or came scrubbed from a record).
        handle: Backend.scrub(state.backend, state.backend_state),
        byte_offset: state.byte_offset,
        buffer: state.buffer,
        opts: state.opts,
        owner: state.owner,
        control: Control.to_store(state.control)
      )
    )
  end

  defp forget(%{persist?: false}), do: :ok
  defp forget(state), do: Store.delete(state.store_key)

  # A remote sandbox writes its output to a file that grows without bound. The
  # cap destroys the sandbox rather than rotating the file: rotation would
  # invalidate every persisted byte offset and silently corrupt resume, which is
  # the precise failure the offset cursor exists to prevent. `nil` = unbounded.
  defp exceeds_stream_cap?(%{max_stream_bytes: nil}, _added), do: false

  defp exceeds_stream_cap?(state, added) do
    state.byte_offset + added > state.max_stream_bytes
  end

  defp stop_stream_too_large(state) do
    Logger.error(
      "Session stream exceeded max_stream_bytes=#{state.max_stream_bytes}; destroying sandbox"
    )

    state = destroy_backend(%{state | buffer: ""})
    broadcast(state, {:error, :stream_too_large})
    {:stop, :normal, %{state | status: :error}}
  end

  defp stop_line_too_large(state) do
    Logger.error(
      "Session line exceeded max_line_bytes=#{state.max_line_bytes}; killing subprocess"
    )

    state = destroy_backend(%{state | buffer: ""})
    broadcast(state, {:error, :line_too_large})
    {:stop, :normal, %{state | status: :error}}
  end

  defp lines_consumed(%{fatal: nil} = state, delivered) do
    # Persist before dispatch: a control request received in this chunk is on
    # record before any callback runs, so a crash in between re-runs it from
    # the record, and a crash before this point replays the line instead.
    # Either way it is never lost.
    state = sync_timer(state)
    persist(state)

    # Tell the reader these bytes are through, so it can lift any backpressure
    # pause it applied. Backends whose reader never pauses (Local) simply
    # ignore it.
    if is_pid(state.reader), do: send(state.reader, {:cc_ack, delivered})

    noreply(state)
  end

  defp lines_consumed(state, _delivered), do: stop_fatal(state)

  defp stop_fatal(state) do
    Logger.error("Session stopping: #{inspect(state.fatal)}")
    state = destroy_backend(state)
    broadcast(state, {:error, state.fatal})
    {:stop, :normal, %{state | status: :error}}
  end

  defp consume_lines(state, lines, offset) do
    {state, _offset} =
      Enum.reduce_while(lines, {state, offset}, fn line, {acc, at} ->
        acc = if line == "", do: acc, else: handle_message(acc, acc.agent.decode_line(line), at)

        if acc.fatal,
          do: {:halt, {acc, at}},
          else: {:cont, {acc, at + byte_size(line) + 1}}
      end)

    state
  end

  # Control frames first: none of them is history a subscriber replays.
  defp handle_message(
         %{control: %{capable?: true}} = state,
         {:control_request, id, subtype, request},
         offset
       ),
       do: receive_request(state, id, subtype, request, offset)

  defp handle_message(state, {:control_response, id, result, envelope}, _offset),
    do: receive_response(state, id, result, envelope)

  defp handle_message(state, {:control_cancel, id}, _offset), do: cancel_request(state, id)

  # "receivers must ignore it": accumulating heartbeats would fill
  # :max_messages during a long-held control request.
  defp handle_message(state, :keep_alive, _offset), do: state

  defp handle_message(state, message, _offset), do: handle_message(state, message)

  defp handle_message(state, {:invalid_json, raw}) do
    Logger.debug("Session received non-JSON line: #{inspect(String.slice(raw, 0, 200))}")
    state
  end

  defp handle_message(state, {:system_init, %{"session_id" => sid} = frame} = msg) do
    case init_version_gate(state, frame) do
      :ok ->
        state = accumulate(%{state | session_id: sid, status: :running}, msg)
        broadcast(state, msg)
        state

      {:error, reason} ->
        %{state | fatal: reason}
    end
  end

  # Every result carries the turn it belongs to. `subscribe/1` replays history,
  # so without this a collector attaching during turn 2 matches turn 1's
  # replayed result and returns stale data instantly. `prompt_seq` is the
  # number of prompts written, which is exactly the turn number.
  defp handle_message(state, {:result, subtype, map}) do
    msg = {:result, subtype, Map.put(map, "turn", state.prompt_seq)}
    state = state |> clear_grace() |> turn_stopped(msg)
    state = accumulate(%{state | status: :completed}, msg)
    broadcast(state, msg)
    state
  end

  defp handle_message(state, msg) do
    state = accumulate(state, msg)
    broadcast(state, msg)
    state
  end

  # Only a session using control features depends on the protocol floor.
  defp init_version_gate(%{control: %{features?: true}}, %{"claude_code_version" => have})
       when is_binary(have),
       do: version_gate(have)

  defp init_version_gate(_state, _init), do: :ok

  # Append `msg` to the newest-first `messages` list, capping retention at
  # `max_messages`. Subscribers still receive every message live; this bounds
  # only the in-memory history returned by `get_messages/1`.
  defp accumulate(state, msg) do
    count = state.message_count + 1
    messages = [msg | state.messages]

    if count > state.max_messages do
      # Prepend then drop the oldest (tail) so retention stays a bounded,
      # newest-first window. Correct even for max_messages == 0 (trims to []).
      %{
        state
        | messages: trim_oldest(messages, state.max_messages),
          message_count: state.max_messages
      }
    else
      %{state | messages: messages, message_count: count}
    end
  end

  # `messages` is newest-first, so the newest `n` entries are simply the head.
  defp trim_oldest(messages, n), do: Enum.take(messages, n)

  defp broadcast(state, message) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:crowd_control, self(), message})
    end)
  end

  # Broadcasts are fire-and-forget, so a subscriber that attaches after the CLI
  # has already produced output would never see it -- and a caller waiting on a
  # `{:result, _, _}` that was emitted a moment too early would block until its
  # own deadline. Replaying the accumulated history (and the exit, if it has
  # already happened) makes subscribe/1 safe to call at any point in the
  # session's life. Deferred control requests are replayed too: after a
  # reattach they are the only way a new subscriber learns of them.
  defp replay_history(state, pid) do
    state.messages
    |> Enum.reverse()
    |> Enum.each(&send(pid, {:crowd_control, self(), &1}))

    for {{id, _offset}, %{status: :deferred} = entry} <- Control.ordered(state.control) do
      send(pid, {:crowd_control, self(), {:control_request, id, entry.subtype, entry.request}})
    end

    if state.exited do
      send(pid, {:crowd_control, self(), {:exit, state.exit_status}})
    end

    :ok
  end

  # --- Control protocol: inbound requests ---

  defp put_control(state, control), do: %{state | control: control}

  defp noreply(state) do
    if Control.dispatchable?(state.control),
      do: {:noreply, state, {:continue, :dispatch_control}},
      else: {:noreply, state}
  end

  # After any change to the pending set: the turn timer follows it, and the
  # record follows both.
  defp settle(state) do
    state = sync_timer(state)
    persist(state)
    state
  end

  defp receive_request(state, id, subtype, request, offset) do
    control = state.control

    # The same line replayed from the capture, or a duplicate delivery of a
    # request still in flight (the ids are unique among in-flight requests).
    if Map.has_key?(control.pending, {id, offset}) or Control.find(control, id) do
      Logger.debug("Session ignored a repeated control request #{id}")
      state
    else
      add_request(state, {id, offset}, subtype, request)
    end
  end

  defp add_request(state, key, subtype, request) do
    entry = %{subtype: subtype, request: request, status: :received}
    put_control(state, %{state.control | pending: Map.put(state.control.pending, key, entry)})
  end

  defp dispatch_received(state) do
    Enum.reduce(Control.dispatchable(state.control), state, fn {key, entry}, acc ->
      dispatch(acc, key, entry)
    end)
  end

  defp dispatch(state, key, %{subtype: "can_use_tool"} = entry) do
    case state.control.can_use_tool do
      nil -> answer(state, key, unsupported(entry), :callback)
      callback -> state |> start_callback(key, entry, callback) |> arm_permission_timer(key)
    end
  end

  defp dispatch(state, key, %{subtype: "hook_callback"} = entry) do
    callback_id = entry.request["callback_id"]

    case Map.fetch(state.control.hooks, callback_id) do
      {:ok, callback} ->
        start_callback(state, key, entry, callback)

      :error ->
        reply = {:response, {:error, "unknown hook callback: #{inspect(callback_id)}"}}
        answer(state, key, reply, :callback)
    end
  end

  defp dispatch(state, key, %{subtype: "mcp_message", request: request}) do
    case Map.fetch(state.control.sdk_servers, request["server_name"]) do
      {:ok, server} ->
        dispatch_mcp(state, key, server, request["message"])

      :error ->
        error =
          SdkMcp.error_response(
            Control.jsonrpc_id(request),
            -32_601,
            "Server #{inspect(request["server_name"])} not found"
          )

        answer(state, key, Control.mcp_reply(error), :callback)
    end
  end

  defp dispatch(state, key, entry) do
    case state.control.on_control_request do
      nil -> answer(state, key, unsupported(entry), :callback)
      callback -> start_callback(state, key, entry, callback)
    end
  end

  # Only a tool call runs user code; the rest of MCP is answered inline.
  defp dispatch_mcp(state, key, server, %{"method" => "tools/call"} = message),
    do: start_task(state, key, fn -> SdkMcp.handle(server, message) end)

  defp dispatch_mcp(state, key, server, message),
    do: answer(state, key, Control.mcp_reply(SdkMcp.handle(server, message)), :callback)

  # The CLI's own wording for a subtype nobody handles, so it never waits.
  defp unsupported(entry),
    do: {:response, {:error, "Unsupported control request subtype: #{entry.subtype}"}}

  defp start_callback(state, {id, _offset} = key, entry, callback) do
    # Bound outside the closure, so the task copies the request and not the
    # whole session state.
    request = entry.request

    context = %{
      session: self(),
      store_key: state.store_key,
      request_id: id,
      subtype: entry.subtype
    }

    start_task(state, key, fn -> Control.call(callback, request, context) end)
  end

  # Under CallbackSupervisor rather than in the session: a callback may block on
  # a human, and the session has to keep reading stdout meanwhile. Monitored,
  # not linked, so a crash becomes an answer instead of taking the session down.
  defp start_task(state, key, fun) do
    session = self()

    case Task.Supervisor.start_child(CrowdControl.CallbackSupervisor, fn ->
           send(session, {:control_result, key, fun.()})
         end) do
      {:ok, pid} ->
        control = state.control
        ref = Process.monitor(pid)

        put_control(state, %{
          control
          | tasks: Map.put(control.tasks, key, {pid, ref}),
            pending: Map.update!(control.pending, key, &%{&1 | status: :dispatched})
        })

      {:error, reason} ->
        Logger.error("Session could not start a control callback: #{inspect(reason)}")

        answer(
          state,
          key,
          Control.failure(state.control.pending[key], "callback crashed"),
          :callback
        )
    end
  end

  defp arm_permission_timer(state, key) do
    control = state.control

    case {control.permission_timeout, Map.fetch(control.pending, key)} do
      {ms, {:ok, _entry}} when is_integer(ms) ->
        timer = :erlang.start_timer(ms, self(), {:permission_timeout, key})

        put_control(state, %{
          control
          | permission_timers: Map.put(control.permission_timers, key, timer)
        })

      _infinite_or_answered ->
        state
    end
  end

  defp take_task(state, key) do
    case Map.pop(state.control.tasks, key) do
      {nil, _tasks} ->
        state

      {{_pid, ref}, tasks} ->
        Process.demonitor(ref, [:flush])
        put_control(state, %{state.control | tasks: tasks})
    end
  end

  defp callback_result(state, key, result) do
    case Map.fetch(state.control.pending, key) do
      # Answered or withdrawn while the callback ran.
      :error ->
        state

      {:ok, %{subtype: "mcp_message"}} ->
        answer(state, key, Control.mcp_reply(result), :callback)

      {:ok, entry} ->
        case Control.reply(entry, result) do
          :defer ->
            defer(state, key, entry)

          :invalid ->
            Logger.error("Control callback for #{elem(key, 0)} returned #{inspect(result)}")
            answer(state, key, Control.failure(entry, "invalid callback decision"), :callback)

          reply ->
            answer(state, key, reply, :callback)
        end
    end
  end

  defp callback_down(state, key, reason) do
    case Map.fetch(state.control.pending, key) do
      :error ->
        state

      {:ok, entry} ->
        Logger.error("Control callback for #{elem(key, 0)} crashed: #{inspect(reason)}")

        message =
          if entry.subtype == "mcp_message", do: "tool call crashed", else: "callback crashed"

        answer(state, key, Control.failure(entry, message), :callback)
    end
  end

  defp defer(state, {id, _offset} = key, entry) do
    control = state.control
    broadcast(state, {:control_request, id, entry.subtype, entry.request})

    put_control(state, %{
      control
      | pending: Map.put(control.pending, key, %{entry | status: :deferred})
    })
  end

  # Writes the answer and forgets the request. A second answer for an id the
  # CLI already settled is harmless ("a requester ignores responses for
  # request_ids it is not waiting on"), so recovery may answer twice.
  defp answer(state, {id, _offset} = key, reply, source) do
    entry = Map.fetch!(state.control.pending, key)
    write_reply(state, id, entry, reply)
    decision_event(state, id, entry, reply, source)
    drop_entry(state, key)
  end

  defp write_reply(state, id, entry, reply) do
    case write_frame(state, encode_reply(state, id, reply)) do
      :ok ->
        :ok

      # A transport with a frame limit (Docker exec argv): the CLI still gets an
      # answer, an MCP error instead of a tool result it cannot receive.
      {:error, :frame_too_large} when entry.subtype == "mcp_message" ->
        Logger.warning("MCP response for #{id} exceeds the backend's frame limit")

        error =
          SdkMcp.error_response(
            Control.jsonrpc_id(entry.request),
            -32_603,
            "tool result too large for the session's transport"
          )

        state
        |> write_frame(encode_reply(state, id, Control.mcp_reply(error)))
        |> write_failed(state)

      error ->
        write_failed(error, state)
    end
  end

  defp write_failed(:ok, _state), do: :ok

  defp write_failed({:error, reason}, state) do
    Logger.error("Session could not write a control answer: #{inspect(reason)}")
    broadcast(state, {:error, {:write_failed, reason}})
  end

  defp encode_reply(state, id, {:permission, decision}),
    do: state.agent.encode_control({:permission, id, decision}, state.agent_opts)

  defp encode_reply(state, id, {:response, result}),
    do: state.agent.encode_control({:response, id, result}, state.agent_opts)

  defp drop_entry(state, key) do
    control = state.control
    {task, tasks} = Map.pop(control.tasks, key)
    stop_task(task)
    {timer, timers} = Map.pop(control.permission_timers, key)
    cancel_timer(timer)

    put_control(state, %{
      control
      | pending: Map.delete(control.pending, key),
        tasks: tasks,
        permission_timers: timers
    })
  end

  defp stop_task(nil), do: :ok

  defp stop_task({pid, ref}) do
    Process.demonitor(ref, [:flush])
    _ = Task.Supervisor.terminate_child(CrowdControl.CallbackSupervisor, pid)
    :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  # The CLI no longer needs an answer (interrupt, or answered elsewhere).
  defp cancel_request(state, id) do
    case Control.find(state.control, id) do
      nil ->
        state

      {key, entry} ->
        decision_event(state, id, entry, :cancel, :cancel)
        state = drop_entry(state, key)
        broadcast(state, {:control_cancelled, id})
        state
    end
  end

  # --- Control protocol: host-originated requests ---

  defp track_outbound(state, id, from, timeout) do
    timer =
      if is_integer(timeout), do: :erlang.start_timer(timeout, self(), {:control_timeout, id})

    outbound = Map.put(state.control.outbound, id, %{from: from, timer: timer})
    put_control(state, %{state.control | outbound: outbound})
  end

  # Registers a written handshake frame's request id, so its reply is consumed
  # (and a rejection logged) rather than dropped unread.
  defp track_init_frame(state, frame) do
    case control_request_id(frame) do
      nil -> state
      id -> track_outbound(state, id, :init, :infinity)
    end
  end

  # The id of a control request among an adapter's opaque handshake frames.
  defp control_request_id(frame) do
    case JSON.decode(IO.iodata_to_binary(frame)) do
      {:ok, %{"type" => "control_request", "request_id" => id}} when is_binary(id) -> id
      _other -> nil
    end
  end

  defp receive_response(state, id, result, envelope) do
    case Map.pop(state.control.outbound, id) do
      # Not ours, or answered after we stopped waiting.
      {nil, _outbound} ->
        state

      {%{from: from, timer: timer}, outbound} ->
        cancel_timer(timer)
        state = put_control(state, %{state.control | outbound: outbound})
        route_response(state, from, result, envelope)
    end
  end

  defp route_response(state, :init, {:error, message}, _envelope) do
    Logger.warning("CLI rejected initialize: #{message}")
    state
  end

  defp route_response(state, :init, _result, _envelope), do: state
  defp route_response(state, :reattach, result, envelope), do: reconcile(state, result, envelope)

  defp route_response(state, from, result, _envelope) do
    GenServer.reply(from, result)
    state
  end

  defp outbound_timeout(state, id) do
    {%{from: from}, outbound} = Map.pop(state.control.outbound, id)
    state = put_control(state, %{state.control | outbound: outbound})

    case from do
      :reattach ->
        Logger.warning("No reply to initialize after reattach; using the persisted requests")
        finish_reconcile(state)

      :init ->
        state

      from ->
        GenServer.reply(from, {:error, :timeout})
        state
    end
  end

  # --- Control protocol: reattach recovery ---

  # `initialize` again, with the same hook ids and SDK servers. Its reply lists
  # the permission requests the CLI is still waiting on.
  defp write_reattach_frames(state) do
    state.agent
    |> Agent.reattach_frames(state.agent_opts)
    |> Enum.reduce(state, &write_reattach_frame/2)
  end

  # A control request among them is awaited: until its reply arrives,
  # permission requests are not dispatched (see reconcile/3).
  defp write_reattach_frame(frame, state) do
    with :ok <- write_frame(state, frame),
         id when is_binary(id) <- control_request_id(frame) do
      state = track_outbound(state, id, :reattach, @reattach_reply_timeout)
      put_control(state, %{state.control | reconciling: true})
    else
      nil ->
        state

      {:error, reason} ->
        Logger.warning("Session could not write reattach frame: #{inspect(reason)}")
        state
    end
  end

  # A tool call whose first run may or may not have completed is not re-run
  # unless the tool says that is safe; the model gets an error it can act on.
  defp answer_unrecoverable(state) do
    unrecoverable =
      for {key, %{subtype: "mcp_message", status: :received} = entry} <-
            Control.ordered(state.control),
          not mcp_idempotent?(state, entry),
          do: {key, entry}

    Enum.reduce(unrecoverable, state, fn {key, entry}, acc ->
      error =
        SdkMcp.error_response(
          Control.jsonrpc_id(entry.request),
          -32_603,
          "host restarted; call state unknown"
        )

      answer(acc, key, Control.mcp_reply(error), :callback)
    end)
  end

  defp mcp_idempotent?(state, %{request: request}) do
    case Map.fetch(state.control.sdk_servers, request["server_name"]) do
      {:ok, server} -> SdkMcp.idempotent?(server, request["message"])
      # Answered with "not found" by dispatch, which is safe to repeat.
      :error -> true
    end
  end

  # `pending_permission_requests` is the CLI's own pending set, so it decides
  # which permission requests are still open: persisted ones it no longer lists
  # were settled (or withdrawn) while we were down, and listed ones we never
  # persisted arrived after the last write. Without the field (an older CLI, or
  # an error) the persisted set stands.
  defp reconcile(state, {:ok, _response}, %{"pending_permission_requests" => frames})
       when is_list(frames) do
    live =
      for frame <- frames,
          is_map(frame),
          {:control_request, id, "can_use_tool", request} <- [Protocol.classify(frame)],
          do: {id, request}

    live_ids = MapSet.new(live, &elem(&1, 0))

    settled =
      for {{id, _offset}, %{subtype: "can_use_tool"}} <- state.control.pending,
          not MapSet.member?(live_ids, id),
          do: id

    state = Enum.reduce(settled, state, &cancel_request(&2, &1))

    state =
      Enum.reduce(live, state, fn {id, request}, acc ->
        if Control.find(acc.control, id),
          do: acc,
          else: add_request(acc, {id, nil}, "can_use_tool", request)
      end)

    finish_reconcile(state)
  end

  defp reconcile(state, _result, _envelope), do: finish_reconcile(state)

  defp finish_reconcile(state), do: put_control(state, %{state.control | reconciling: false})

  # --- Timers ---

  defp now_ms, do: System.system_time(:millisecond)

  defp schedule_timeout(%{timeout: nil} = state), do: state
  defp schedule_timeout(%{timeout: :infinity} = state), do: state

  defp schedule_timeout(%{timeout: timeout} = state) when is_integer(timeout) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    state = %{state | timeout_ref: nil}

    # A new turn while a permission request is still open starts paused.
    if Control.blocked?(state.control) do
      put_control(state, %{state.control | paused_remaining_ms: timeout, turn_deadline_at: nil})
    else
      arm_deadline(state, timeout)
    end
  end

  # `turn_deadline_at` is wall-clock, not monotonic: it is persisted, and a
  # monotonic reading means nothing in another VM.
  defp arm_deadline(state, ms) do
    ref = :erlang.start_timer(ms, self(), :session_timeout)
    put_control(%{state | timeout_ref: ref}, %{state.control | turn_deadline_at: now_ms() + ms})
  end

  # The turn timer stops while a human holds the turn, and resumes with what was
  # left once nothing blocks it. Driven only by the pending set, so it is
  # recomputed rather than counted.
  defp sync_timer(%{control: control} = state) do
    blocked = Control.blocked?(control)

    cond do
      blocked and is_reference(state.timeout_ref) ->
        # `false` means it already fired; that message no longer matches
        # `timeout_ref`, and the deadline resumes as already due.
        remaining =
          case Process.cancel_timer(state.timeout_ref) do
            ms when is_integer(ms) -> ms
            _fired -> 0
          end

        put_control(%{state | timeout_ref: nil}, %{
          control
          | paused_remaining_ms: remaining,
            turn_deadline_at: nil
        })

      not blocked and is_integer(control.paused_remaining_ms) ->
        state
        |> put_control(%{control | paused_remaining_ms: nil})
        |> arm_deadline(control.paused_remaining_ms)

      true ->
        state
    end
  end

  # A reattached session keeps the deadline its turn already had: time spent
  # with the host down counts, so a crash loop cannot extend a turn forever.
  # sync_timer/1 then pauses it again if a restored request still blocks, or
  # resumes a paused remainder that nothing blocks any more.
  defp restore_deadline(%{control: control} = state) do
    cond do
      not is_integer(state.timeout) ->
        state

      is_integer(control.paused_remaining_ms) ->
        sync_timer(state)

      is_integer(control.turn_deadline_at) ->
        state
        |> arm_deadline(max(control.turn_deadline_at - now_ms(), 0))
        |> sync_timer()

      true ->
        schedule_timeout(state)
    end
  end

  # An agent that can stop a turn gets the chance to: `interrupt` first, and
  # the destructive path only if no result follows within the grace period.
  defp on_deadline(%{control: control} = state) do
    state = put_control(state, %{control | turn_deadline_at: nil})

    if control.interrupt_grace > 0 and state.status != :completed and is_nil(control.grace_ref) do
      {id, control} = Control.next_request_id(state.control)
      state = put_control(state, control)

      frame =
        state.agent.encode_control({:request, id, %{"subtype" => "interrupt"}}, state.agent_opts)

      case write_frame(state, frame) do
        :ok ->
          Logger.warning(
            "Session turn exceeded #{state.timeout}ms; interrupting " <>
              "(grace #{control.interrupt_grace}ms)"
          )

          grace = :erlang.start_timer(control.interrupt_grace, self(), :interrupt_grace)
          {:noreply, put_control(state, %{control | grace_ref: grace})}

        {:error, _reason} ->
          expire(state)
      end
    else
      expire(state)
    end
  end

  defp expire(state) do
    Logger.warning("Session timed out after #{state.timeout}ms")
    state = destroy_backend(state)
    broadcast(state, {:timeout, :session_expired})
    {:stop, :normal, %{state | status: :error}}
  end

  defp clear_grace(%{control: %{grace_ref: nil}} = state), do: state

  defp clear_grace(%{control: control} = state) do
    cancel_timer(control.grace_ref)
    put_control(state, %{control | grace_ref: nil})
  end

  # Teardown: every callback is cancelled and every waiter answered, so nothing
  # outlives the CLI it was talking to.
  defp shutdown_control(%{control: control} = state) do
    Enum.each(control.tasks, fn {_key, task} -> stop_task(task) end)
    Enum.each(control.permission_timers, fn {_key, timer} -> cancel_timer(timer) end)
    cancel_timer(control.grace_ref)

    Enum.each(control.outbound, fn {_id, %{from: from, timer: timer}} ->
      cancel_timer(timer)
      if is_tuple(from), do: GenServer.reply(from, {:error, :closed})
    end)

    put_control(state, %{
      control
      | pending: %{},
        outbound: %{},
        tasks: %{},
        permission_timers: %{},
        grace_ref: nil,
        reconciling: false
    })
  end

  # --- Telemetry ---

  defp meta(state), do: %{store_key: state.store_key, agent: state.agent, backend: state.backend}

  defp session_started(state) do
    now = System.monotonic_time()

    Telemetry.execute(
      [:crowd_control, :session, :start],
      %{system_time: System.system_time(), monotonic_time: now},
      meta(state)
    )

    %{state | started_at: now}
  end

  defp session_stopped(%{started_at: nil}, _reason), do: :ok

  defp session_stopped(state, reason) do
    now = System.monotonic_time()
    measurements = %{duration: now - state.started_at, monotonic_time: now}

    if clean_exit?(reason) do
      Telemetry.execute(
        [:crowd_control, :session, :stop],
        measurements,
        Map.merge(meta(state), %{status: state.status, exit_status: state.exit_status})
      )
    else
      Telemetry.execute(
        [:crowd_control, :session, :exception],
        measurements,
        Map.merge(meta(state), %{kind: :exit, reason: reason, stacktrace: []})
      )
    end
  end

  defp clean_exit?(reason) when reason in [:normal, :shutdown], do: true
  defp clean_exit?({:shutdown, _detail}), do: true
  defp clean_exit?(_reason), do: false

  defp turn_started(state) do
    now = System.monotonic_time()

    Telemetry.execute(
      [:crowd_control, :turn, :start],
      %{system_time: System.system_time(), monotonic_time: now},
      Map.put(meta(state), :turn, state.prompt_seq)
    )

    %{state | turn_starts: state.turn_starts ++ [now]}
  end

  # Claude Code's `total_cost_usd` is cumulative for the process, so a turn's
  # own cost is the difference from the previous result.
  defp turn_stopped(state, {:result, subtype, map} = msg) do
    cost = Result.cost_usd(msg)

    turn_cost =
      if is_number(cost) and is_number(state.last_cost_usd) and cost >= state.last_cost_usd,
        do: cost - state.last_cost_usd,
        else: cost

    state = %{state | last_cost_usd: cost || state.last_cost_usd}

    case state.turn_starts do
      [] ->
        state

      [started | rest] ->
        now = System.monotonic_time()

        error_kind =
          case Result.classify(msg) do
            {:ok, _map} -> nil
            {:error, %{kind: kind}} -> kind
          end

        Telemetry.execute(
          [:crowd_control, :turn, :stop],
          %{duration: now - started, monotonic_time: now},
          Map.merge(meta(state), %{
            turn: map["turn"],
            cost_usd: cost,
            turn_cost_usd: turn_cost,
            subtype: subtype,
            error_kind: error_kind
          })
        )

        %{state | turn_starts: rest}
    end
  end

  # The audit trail for permission decisions: answers are written to stdin and
  # never reach the capture, so this event is the only record of them.
  defp decision_event(state, id, %{subtype: "can_use_tool", request: request}, reply, source) do
    Telemetry.execute(
      [:crowd_control, :control, :decision],
      %{system_time: System.system_time()},
      %{
        store_key: state.store_key,
        request_id: id,
        tool_name: request["tool_name"],
        behavior: Control.behavior(reply),
        source: source
      }
    )
  end

  defp decision_event(_state, _id, _entry, _reply, _source), do: :ok
end
