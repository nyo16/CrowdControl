defmodule CrowdControl.Session do
  @moduledoc """
  GenServer managing a single Claude Code / Open Code CLI subprocess.

  Each session wraps a `NetRunner.Process` and a linked reader process
  that drains stdout, buffers partial lines, decodes JSON messages,
  and broadcasts them to subscribers.
  """

  use GenServer

  alias CrowdControl.{CLI, Protocol}

  defstruct [
    :proc,
    :reader,
    :session_id,
    :opts,
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
    {executable, args} = CLI.build_command(opts)

    case NetRunner.Process.start_link(executable, args) do
      {:ok, proc} ->
        session_pid = self()
        reader = spawn_link(fn -> reader_loop(proc, session_pid) end)

        state = %__MODULE__{
          proc: proc,
          reader: reader,
          opts: opts
        }

        state =
          case Keyword.get(opts, :prompt) do
            nil -> state
            prompt -> do_send_prompt(state, prompt)
          end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_prompt, prompt}, _from, %{status: status} = state)
      when status in [:starting, :running] do
    {:reply, :ok, do_send_prompt(state, prompt)}
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
    broadcast(state, {:exit, exit_status})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
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
