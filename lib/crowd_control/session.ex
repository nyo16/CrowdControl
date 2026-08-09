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
  exceeds `:max_line_bytes`).

  ## Options

  Session-lifecycle options (CLI/argv options are forwarded to the agent
  adapter's `build_command/1`, e.g. `CrowdControl.CLI.build_command/1`):

    * `:agent` - `CrowdControl.Agent` adapter selecting the CLI dialect:
      `:claude` (default), `:open_code`, `:omp`, or a module. Inferred from
      `:executable` when omitted.
    * `:backend` - `CrowdControl.Backend` implementation, either a module or a
      `{module, config}` tuple whose config is merged into these opts. Defaults
      to `CrowdControl.Backend.Local`.
    * `:prompt` - initial prompt sent once the CLI starts (optional)
    * `:timeout` - inactivity ceiling in ms before the session self-expires and
      broadcasts `{:timeout, :session_expired}`; reset on each `send_prompt/2`.
      Use `:infinity` or `nil` to disable. Defaults to `300_000`.
    * `:max_prompt_size` - reject prompts whose byte size exceeds this with
      `{:error, :prompt_too_large}` (optional; unbounded when unset)
    * `:max_line_bytes` - cap for a single newline-free output line. Exceeding it
      kills the subprocess and broadcasts `{:error, :line_too_large}` rather than
      buffering an unbounded remainder. Defaults to `1_000_000`.
    * `:max_stream_bytes` - cap on a session's **total** output. Exceeding it
      destroys the sandbox and broadcasts `{:error, :stream_too_large}`. Mainly
      for remote backends, whose output file grows without bound; unbounded when
      unset.
    * `:max_messages` - cap on messages retained for `get_messages/1`; oldest are
      dropped past the cap. Live subscribers are unaffected. Clamped to `>= 0`.
      Defaults to `10_000`.
  """

  # :transient, not :temporary. `:temporary` is right when the OS process dies
  # with the GenServer -- and exactly backwards when a *billed* remote sandbox
  # outlives it. A transient child is restarted on abnormal exit, which is what
  # gives CrowdControl.Reaper a session to reattach the surviving sandbox to.
  # Normal exits (`:normal`, `:shutdown`) are still not restarted, so an ordinary
  # completed session does not respawn and does not hold a `:max_children` slot.
  use GenServer, restart: :transient

  require Logger

  alias CrowdControl.{Agent, Backend, Protocol, Store}

  @default_timeout 300_000
  # 1 MiB, matching the `maxFrameBytes` omp advertises in its ready frame. A
  # lower cap would destroy a session over a frame omp considers legal, which
  # is a worse failure than the 48 KiB of extra headroom this costs.
  @default_max_line_bytes 1_048_576
  @default_max_messages 10_000

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
    status: :starting,
    exited: false,
    persist?: false,
    subscribers: [],
    buffer: "",
    byte_offset: 0,
    messages: [],
    message_count: 0,
    prompt_seq: 0
  ]

  @type t :: %__MODULE__{}
  @type session :: pid()
  @type status :: :starting | :running | :completed | :error

  # --- Public API ---

  @doc "Start a session linked to the caller."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a user prompt to the CLI subprocess.

  Returns `:ok` on success or `{:error, reason}` where reason is one of
  `:invalid_prompt`, `:prompt_too_large`, `:completed`, `:error`.
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

  @doc "Subscribe the calling process to receive session messages."
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
      state = %__MODULE__{
        agent: Agent.resolve(record.opts),
        backend: backend,
        backend_state: handle,
        reader: reader,
        store_key: record.key,
        owner: record.owner,
        session_id: record.session_id,
        persist?: Backend.reattachable?(backend),
        opts: record.opts,
        # The merged list is not persisted, so the record's opts are the best
        # available. Backend config is re-applied by the reattach path itself.
        agent_opts: record.opts,
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
        status: :running
      }

      {:ok, schedule_timeout(state)}
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

    # Bounds are validated before provisioning so that a bad :max_messages
    # raises without having created (and leaked) a sandbox first.
    max_line_bytes = bound_opt!(opts, :max_line_bytes, @default_max_line_bytes)
    max_messages = bound_opt!(opts, :max_messages, @default_max_messages)

    case start_backend(backend, backend_opts, executable, args, env) do
      {:ok, handle, reader} ->
        state = %__MODULE__{
          agent: agent,
          backend: backend,
          backend_state: handle,
          reader: reader,
          store_key: store_key,
          owner: owner,
          persist?: Backend.reattachable?(backend),
          opts: opts,
          agent_opts: backend_opts,
          timeout: Keyword.get(opts, :timeout, @default_timeout),
          max_prompt_size: Keyword.get(opts, :max_prompt_size),
          max_line_bytes: max_line_bytes,
          max_stream_bytes: Keyword.get(opts, :max_stream_bytes),
          max_messages: max_messages
        }

        start_turn(schedule_timeout(state), opts)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # A failed handshake is fatal, not something to discover via the inactivity
  # timeout minutes later: for omp it means no `get_state`, so no session id
  # and no `{:system_init, _}` ever.
  defp start_turn(state, opts) do
    case write_init_frames(state) do
      :ok ->
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
  defp start_backend(backend, opts, executable, args, env) do
    with {:ok, handle} <- backend.provision(opts),
         {:ok, handle} <- exec_or_destroy(backend, handle, executable, args, env),
         {:ok, reader} <- reader_or_destroy(backend, handle, Backend.new_cursor()) do
      {:ok, handle, reader}
    end
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

  @impl true
  def handle_call({:send_prompt, prompt}, _from, state) do
    case validate_prompt(prompt, state.max_prompt_size) do
      :ok ->
        case state.status do
          status when status in [:starting, :running] ->
            state = state |> do_send_prompt(prompt) |> schedule_timeout()
            {:reply, :ok, state}

          # A result ends a *turn*, not the process: `omp --mode rpc` and
          # `claude --input-format stream-json` both keep reading stdin
          # afterwards. Rejecting here would make multi-turn conversations
          # impossible for every CLI that outlives its first result. Only an
          # exited subprocess (`exited: true`, set on EOF) is really terminal.
          :completed when not state.exited ->
            state = %{state | status: :running} |> do_send_prompt(prompt) |> schedule_timeout()
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

        state = consume_lines(state, lines)
        persist(state)

        # Tell the reader these bytes are through, so it can lift any
        # backpressure pause it applied. Backends whose reader never pauses
        # (Local) simply ignore it.
        if is_pid(state.reader), do: send(state.reader, {:cc_ack, byte_size(data)})

        {:noreply, state}
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
  def handle_info(:session_timeout, state) do
    Logger.warning("Session timed out after #{state.timeout}ms")
    state = destroy_backend(state)
    broadcast(state, {:timeout, :session_expired})
    {:stop, :normal, %{state | status: :error}}
  end

  @impl true
  def terminate(_reason, state) do
    destroy_backend(state)
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

  # Handshake frames the CLI needs before it will behave (omp's `get_state`,
  # which is what makes a session id observable). Written before the initial
  # prompt so the id lands first, exactly where Claude Code emits its own
  # system/init.
  @spec write_init_frames(t()) :: :ok | {:error, term()}
  defp write_init_frames(state) do
    Enum.reduce_while(state.agent.init_frames(state.agent_opts), :ok, fn frame, :ok ->
      case state.backend.write(state.backend_state, frame) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:handshake_failed, reason}}}
      end
    end)
  end

  defp do_send_prompt(state, prompt) do
    encoded = state.agent.encode_prompt(prompt, state.prompt_seq, state.agent_opts)
    _ = state.backend.write(state.backend_state, encoded)
    %{state | prompt_seq: state.prompt_seq + 1}
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
    %{state | backend_state: nil}
  end

  # Persistence is skipped entirely for backends that cannot reattach -- a store
  # write per stdout chunk is real overhead, and Backend.Local has nothing to
  # reattach to.
  defp persist(%{persist?: false}), do: :ok

  defp persist(state) do
    Store.put(
      state.store_key,
      Store.build(
        key: state.store_key,
        session_id: state.session_id,
        backend: state.backend,
        # Both the handle and the opts are scrubbed of credentials before they
        # touch the store -- a record can outlive the VM on disk, and nothing
        # about reattaching needs an API key.
        handle: Backend.scrub(state.backend, state.backend_state),
        byte_offset: state.byte_offset,
        buffer: state.buffer,
        opts: Store.scrub_opts(state.opts),
        owner: state.owner
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

  defp consume_lines(state, lines) do
    Enum.reduce(lines, state, fn
      "", acc -> acc
      line, acc -> handle_message(acc, acc.agent.decode_line(line))
    end)
  end

  defp handle_message(state, {:invalid_json, raw}) do
    Logger.debug("Session received non-JSON line: #{inspect(String.slice(raw, 0, 200))}")
    state
  end

  defp handle_message(state, {:system_init, %{"session_id" => sid}} = msg) do
    state = accumulate(%{state | session_id: sid, status: :running}, msg)
    broadcast(state, msg)
    state
  end

  # Every result carries the turn it belongs to. `subscribe/1` replays history,
  # so without this a collector attaching during turn 2 matches turn 1's
  # replayed result and returns stale data instantly. `prompt_seq` is the
  # number of prompts written, which is exactly the turn number.
  defp handle_message(state, {:result, subtype, map}) do
    msg = {:result, subtype, Map.put(map, "turn", state.prompt_seq)}
    state = accumulate(%{state | status: :completed}, msg)
    broadcast(state, msg)
    state
  end

  defp handle_message(state, msg) do
    state = accumulate(state, msg)
    broadcast(state, msg)
    state
  end

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
  # session's life.
  defp replay_history(state, pid) do
    state.messages
    |> Enum.reverse()
    |> Enum.each(&send(pid, {:crowd_control, self(), &1}))

    if state.exited do
      send(pid, {:crowd_control, self(), {:exit, state.exit_status}})
    end

    :ok
  end

  defp schedule_timeout(%{timeout: nil} = state), do: state
  defp schedule_timeout(%{timeout: :infinity} = state), do: state

  defp schedule_timeout(%{timeout: timeout} = state) when is_integer(timeout) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    ref = Process.send_after(self(), :session_timeout, timeout)
    %{state | timeout_ref: ref}
  end
end
