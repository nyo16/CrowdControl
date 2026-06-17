defmodule CrowdControl.Session do
  @moduledoc """
  GenServer managing a single Claude Code / Open Code CLI subprocess.

  Each session wraps a `NetRunner.Process` and a linked reader process
  that drains stdout, buffers partial lines, decodes JSON messages,
  and broadcasts them to subscribers.

  Subscribers receive messages of the form `{:crowd_control, session_pid, payload}`
  where `payload` is one of `t:CrowdControl.Protocol.message/0`,
  `{:exit, exit_status}`, `{:timeout, :session_expired}`, or `{:error, reason}`
  (e.g. `{:error, :line_too_large}` when a single newline-free output line
  exceeds `:max_line_bytes`).

  ## Options

  Session-lifecycle options (CLI/argv options are forwarded to
  `CrowdControl.CLI.build_command/1`):

    * `:prompt` - initial prompt sent once the CLI starts (optional)
    * `:timeout` - inactivity ceiling in ms before the session self-expires and
      broadcasts `{:timeout, :session_expired}`; reset on each `send_prompt/2`.
      Use `:infinity` or `nil` to disable. Defaults to `300_000`.
    * `:max_prompt_size` - reject prompts whose byte size exceeds this with
      `{:error, :prompt_too_large}` (optional; unbounded when unset)
    * `:max_line_bytes` - cap for a single newline-free output line. Exceeding it
      kills the subprocess and broadcasts `{:error, :line_too_large}` rather than
      buffering an unbounded remainder. Defaults to `1_000_000`.
    * `:max_messages` - cap on messages retained for `get_messages/1`; oldest are
      dropped past the cap. Live subscribers are unaffected. Clamped to `>= 0`.
      Defaults to `10_000`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias CrowdControl.{CLI, Protocol}

  @default_timeout 300_000
  @default_max_line_bytes 1_000_000
  @default_max_messages 10_000

  defstruct [
    :proc,
    :reader,
    :session_id,
    :opts,
    :timeout,
    :timeout_ref,
    :env_dir,
    :env_file,
    :max_prompt_size,
    :max_line_bytes,
    :max_messages,
    status: :starting,
    subscribers: [],
    buffer: "",
    messages: [],
    message_count: 0
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

  @impl true
  def init(opts) do
    {executable, args, env} = CLI.build_command(opts)
    {cmd, cmd_args, env_dir, env_file} = wrap_with_env(executable, args, env)

    Logger.info("Starting session: executable=#{executable}, model=#{opts[:model] || "default"}")

    case NetRunner.Process.start_link(cmd, cmd_args) do
      {:ok, proc} ->
        session_pid = self()
        reader = spawn_link(fn -> reader_loop(proc, session_pid) end)
        timeout = Keyword.get(opts, :timeout, @default_timeout)
        max_prompt_size = Keyword.get(opts, :max_prompt_size)
        max_line_bytes = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)
        max_messages = max(Keyword.get(opts, :max_messages, @default_max_messages), 0)

        state = %__MODULE__{
          proc: proc,
          reader: reader,
          opts: opts,
          timeout: timeout,
          env_dir: env_dir,
          env_file: env_file,
          max_prompt_size: max_prompt_size,
          max_line_bytes: max_line_bytes,
          max_messages: max_messages
        }

        state = schedule_timeout(state)

        state =
          case Keyword.get(opts, :prompt) do
            nil -> state
            prompt -> do_send_prompt(state, prompt)
          end

        {:ok, state}

      {:error, reason} ->
        cleanup_env_dir(env_dir)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_prompt, prompt}, _from, state) do
    case validate_prompt(prompt, state.max_prompt_size) do
      :ok ->
        case state.status do
          status when status in [:starting, :running] ->
            state = state |> do_send_prompt(prompt) |> schedule_timeout()
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

  def handle_call(:get_session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  def handle_call(:stop, _from, state) do
    state = shutdown_process(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast({:stdout_data, data}, state) do
    buffer = state.buffer <> data
    {lines, remainder} = Protocol.split_lines(buffer)

    if byte_size(remainder) > state.max_line_bytes do
      Logger.error(
        "Session line exceeded max_line_bytes=#{state.max_line_bytes}; killing subprocess"
      )

      state = shutdown_process(%{state | buffer: ""})
      cleanup_env_dir(state.env_dir)
      broadcast(state, {:error, :line_too_large})
      {:stop, :normal, %{state | status: :error, env_dir: nil, env_file: nil}}
    else
      state =
        Enum.reduce(lines, %{state | buffer: remainder}, fn line, acc ->
          if line == "" do
            acc
          else
            message = Protocol.decode_line(line)
            handle_message(acc, message)
          end
        end)

      {:noreply, state}
    end
  end

  def handle_cast(:eof, state) do
    exit_status =
      case safe_await_exit(state.proc, 1_000) do
        {:ok, status} -> status
        _ -> nil
      end

    status = if exit_status == 0 or state.status == :completed, do: :completed, else: :error
    state = %{state | status: status}

    if status == :error do
      Logger.warning("Session exited with error, exit_status=#{inspect(exit_status)}")
    else
      Logger.info("Session completed, exit_status=#{inspect(exit_status)}")
    end

    cleanup_env_dir(state.env_dir)
    broadcast(state, {:exit, exit_status})
    {:noreply, %{state | env_dir: nil, env_file: nil}}
  end

  @impl true
  def handle_info(:session_timeout, state) do
    Logger.warning("Session timed out after #{state.timeout}ms")
    state = shutdown_process(state)
    broadcast(state, {:timeout, :session_expired})
    {:stop, :normal, %{state | status: :error}}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_env_dir(state.env_dir)
    shutdown_process(state)
    :ok
  end

  # --- Private ---

  defp validate_prompt(prompt, _max) when not is_binary(prompt), do: {:error, :invalid_prompt}

  defp validate_prompt(prompt, max) do
    cond do
      not String.valid?(prompt) -> {:error, :invalid_prompt}
      String.contains?(prompt, <<0>>) -> {:error, :invalid_prompt}
      is_integer(max) and byte_size(prompt) > max -> {:error, :prompt_too_large}
      true -> :ok
    end
  end

  defp reader_loop(proc, session_pid) do
    case NetRunner.Process.read(proc) do
      {:ok, data} ->
        GenServer.cast(session_pid, {:stdout_data, data})
        reader_loop(proc, session_pid)

      :eof ->
        GenServer.cast(session_pid, :eof)

      {:error, _} ->
        GenServer.cast(session_pid, :eof)
    end
  end

  defp do_send_prompt(state, prompt) do
    encoded = Protocol.encode_user_message(prompt)
    NetRunner.Process.write(state.proc, encoded)
    state
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

  defp handle_message(state, {:result, _subtype, _map} = msg) do
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

  defp wrap_with_env(executable, args, env) when map_size(env) == 0 do
    {executable, args, nil, nil}
  end

  defp wrap_with_env(executable, args, env) do
    {env_dir, env_file} = write_env_file(env)
    escaped_args = Enum.map_join([executable | args], " ", &shell_escape/1)

    shell_cmd =
      ". #{shell_escape(env_file)} && rm -f #{shell_escape(env_file)} && exec #{escaped_args}"

    {"/bin/sh", ["-c", shell_cmd], env_dir, env_file}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_env_file(env) do
    random = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "cc_env_#{random}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    path = Path.join(dir, "env.sh")

    content =
      Enum.map_join(env, "\n", fn {k, v} ->
        "export #{k}=#{shell_escape(v)}"
      end)

    File.write!(path, content <> "\n")
    File.chmod!(path, 0o600)
    {dir, path}
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp cleanup_env_dir(nil), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_env_dir(dir) do
    _ = File.rm_rf(dir)
    :ok
  end

  defp schedule_timeout(%{timeout: nil} = state), do: state
  defp schedule_timeout(%{timeout: :infinity} = state), do: state

  defp schedule_timeout(%{timeout: timeout} = state) when is_integer(timeout) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    ref = Process.send_after(self(), :session_timeout, timeout)
    %{state | timeout_ref: ref}
  end

  defp shutdown_process(state) do
    if state.proc && safe_alive?(state.proc) do
      _ = safe_kill(state.proc, :sigterm)

      case safe_await_exit(state.proc, 1_000) do
        {:ok, _} ->
          :ok

        _ ->
          _ = safe_kill(state.proc, :sigkill)
          _ = safe_await_exit(state.proc, 1_000)
          :ok
      end
    end

    state
  end

  # `NetRunner.Process.{await_exit,alive?,kill}` are all `GenServer.call`s; a
  # dead or stale daemon makes the call raise an `:exit`, never an `:error`.
  # Catch only `:exit` so genuine bugs (UndefinedFunctionError, etc.) surface
  # instead of being silently swallowed.
  defp safe_await_exit(proc, timeout) do
    NetRunner.Process.await_exit(proc, timeout)
  catch
    :exit, _ -> :timeout
  end

  defp safe_alive?(proc) do
    NetRunner.Process.alive?(proc)
  catch
    :exit, _ -> false
  end

  defp safe_kill(proc, signal) do
    NetRunner.Process.kill(proc, signal)
  catch
    :exit, _ -> :ok
  end
end
