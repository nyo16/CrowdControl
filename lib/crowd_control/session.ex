defmodule CrowdControl.Session do
  @moduledoc """
  GenServer managing a single Claude Code / Open Code CLI subprocess.

  Each session wraps a `NetRunner.Process` and a linked reader process
  that drains stdout, buffers partial lines, decodes JSON messages,
  and broadcasts them to subscribers.
  """

  use GenServer

  require Logger

  alias CrowdControl.{CLI, Protocol}

  defstruct [
    :proc,
    :reader,
    :session_id,
    :opts,
    :timeout,
    :timeout_ref,
    :env_file,
    :max_prompt_size,
    status: :starting,
    subscribers: [],
    buffer: "",
    messages: []
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Send a user prompt to the CLI subprocess."
  def send_prompt(session, prompt) do
    GenServer.call(session, {:send_prompt, prompt})
  end

  @doc "Get the current session status."
  def get_status(session) do
    GenServer.call(session, :get_status)
  end

  @doc "Get the session ID (assigned by the CLI on init)."
  def get_session_id(session) do
    GenServer.call(session, :get_session_id)
  end

  @doc "Subscribe the calling process to receive session messages."
  def subscribe(session) do
    GenServer.call(session, {:subscribe, self()})
  end

  @doc "Get all accumulated messages."
  def get_messages(session) do
    GenServer.call(session, :get_messages)
  end

  @doc "Gracefully stop the session."
  def stop(session) do
    GenServer.call(session, :stop, 10_000)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    {executable, args, env} = CLI.build_command(opts)
    {cmd, cmd_args, env_file} = wrap_with_env(executable, args, env)

    Logger.info("Starting session: executable=#{executable}, model=#{opts[:model] || "default"}")

    case NetRunner.Process.start_link(cmd, cmd_args) do
      {:ok, proc} ->
        session_pid = self()
        reader = spawn_link(fn -> reader_loop(proc, session_pid) end)
        timeout = Keyword.get(opts, :timeout)
        max_prompt_size = Keyword.get(opts, :max_prompt_size)

        state = %__MODULE__{
          proc: proc,
          reader: reader,
          opts: opts,
          timeout: timeout,
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
        cleanup_env_file(env_file)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_prompt, prompt}, _from, state) when not is_binary(prompt) do
    {:reply, {:error, :invalid_prompt}, state}
  end

  def handle_call({:send_prompt, prompt}, _from, %{max_prompt_size: max} = state)
      when is_integer(max) and byte_size(prompt) > max do
    {:reply, {:error, :prompt_too_large}, state}
  end

  def handle_call({:send_prompt, prompt}, _from, %{status: status} = state)
      when status in [:starting, :running] do
    state = state |> do_send_prompt(prompt) |> schedule_timeout()
    {:reply, :ok, state}
  end

  def handle_call({:send_prompt, _prompt}, _from, state) do
    {:reply, {:error, state.status}, state}
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
      case NetRunner.Process.await_exit(state.proc, 5_000) do
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

    cleanup_env_file(state.env_file)
    broadcast(state, {:exit, exit_status})
    {:noreply, state}
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
    cleanup_env_file(state.env_file)
    shutdown_process(state)
    :ok
  end

  # --- Private ---

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

  defp wrap_with_env(executable, args, env) when map_size(env) == 0 do
    {executable, args, nil}
  end

  defp wrap_with_env(executable, args, env) do
    env_file = write_env_file(env)
    escaped_args = Enum.map_join([executable | args], " ", &shell_escape/1)
    shell_cmd = ". #{env_file} && rm -f #{env_file} && exec #{escaped_args}"
    {"/bin/sh", ["-c", shell_cmd], env_file}
  end

  defp write_env_file(env) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    path = Path.join(System.tmp_dir!(), "cc_env_#{random}.sh")

    content =
      Enum.map_join(env, "\n", fn {k, v} ->
        "export #{k}=#{shell_escape(v)}"
      end)

    File.write!(path, content <> "\n")
    File.chmod!(path, 0o600)
    path
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp cleanup_env_file(nil), do: :ok

  defp cleanup_env_file(path) do
    File.rm(path)
    :ok
  end

  defp schedule_timeout(%{timeout: nil} = state), do: state

  defp schedule_timeout(%{timeout: timeout} = state) when is_integer(timeout) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    ref = Process.send_after(self(), :session_timeout, timeout)
    %{state | timeout_ref: ref}
  end

  defp shutdown_process(state) do
    if state.proc && NetRunner.Process.alive?(state.proc) do
      NetRunner.Process.kill(state.proc, :sigterm)

      case NetRunner.Process.await_exit(state.proc, 5_000) do
        {:ok, _} -> :ok
        _ -> NetRunner.Process.kill(state.proc, :sigkill)
      end
    end

    state
  end
end
