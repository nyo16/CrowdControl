defmodule CrowdControl.Session do
  @moduledoc """
  GenServer managing a single Claude Code / Open Code CLI subprocess.

  Each session wraps a `NetRunner.Process` and a linked reader process
  that drains stdout, buffers partial lines, decodes JSON messages,
  and broadcasts them to subscribers.

  Subscribers receive messages of the form `{:crowd_control, session_pid, payload}`
  where `payload` is one of `t:CrowdControl.Protocol.message/0`,
  `{:exit, exit_status}`, or `{:timeout, :session_expired}`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias CrowdControl.{CLI, Protocol}

  @default_timeout 300_000

  # Short, non-destructive probe used to reap a subprocess that has already
  # exited. NetRunner answers immediately in that case; killing first would
  # leave it waiting on an exit it has already delivered.
  @reap_probe_timeout 50
  @kill_wait_timeout 1_000

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
    :exit_status,
    status: :starting,
    exited: false,
    subscribers: [],
    buffer: "",
    messages: []
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

  @doc "Get all accumulated messages in chronological order."
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

        state = %__MODULE__{
          proc: proc,
          reader: reader,
          opts: opts,
          timeout: timeout,
          env_dir: env_dir,
          env_file: env_file,
          max_prompt_size: max_prompt_size
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
    replay_history(state, pid)
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

  def handle_cast(:eof, state) do
    exit_status =
      case safe_await_exit(state.proc, 1_000) do
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
    state = %{state | session_id: sid, status: :running, messages: [msg | state.messages]}
    broadcast(state, msg)
    state
  end

  defp handle_message(state, {:result, _subtype, _map} = msg) do
    state = %{state | status: :completed, messages: [msg | state.messages]}
    broadcast(state, msg)
    state
  end

  defp handle_message(state, msg) do
    state = %{state | messages: [msg | state.messages]}
    broadcast(state, msg)
    state
  end

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

  # Idempotent: clearing :proc means terminate/2 does not repeat the escalation
  # after handle_info(:session_timeout) or handle_call(:stop) already ran it.
  defp shutdown_process(%{proc: nil} = state), do: state

  defp shutdown_process(state) do
    # Reap before killing. If the subprocess is already gone this returns
    # immediately; going straight to kill/2 would leave NetRunner blocked on an
    # exit it has already reported, costing the full timeout twice over.
    case safe_await_exit(state.proc, @reap_probe_timeout) do
      {:ok, _} -> :ok
      _ -> escalate_kill(state.proc)
    end

    %{state | proc: nil}
  end

  defp escalate_kill(proc) do
    if safe_alive?(proc) do
      _ = safe_kill(proc, :sigterm)

      case safe_await_exit(proc, @kill_wait_timeout) do
        {:ok, _} ->
          :ok

        _ ->
          _ = safe_kill(proc, :sigkill)
          _ = safe_await_exit(proc, @kill_wait_timeout)
          :ok
      end
    end

    :ok
  end

  defp safe_await_exit(nil, _timeout), do: :timeout

  defp safe_await_exit(proc, timeout) do
    NetRunner.Process.await_exit(proc, timeout)
  catch
    :exit, _ -> :timeout
    :error, _ -> :timeout
  end

  defp safe_alive?(proc) do
    NetRunner.Process.alive?(proc)
  catch
    :exit, _ -> false
    :error, _ -> false
  end

  defp safe_kill(proc, signal) do
    NetRunner.Process.kill(proc, signal)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end
end
