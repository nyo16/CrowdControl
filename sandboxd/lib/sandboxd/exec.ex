defmodule Sandboxd.Exec do
  @moduledoc """
  The one CLI process this sandbox will ever run.

  Spawns it through `NetRunner.Process`, so the zero-zombie shepherd that the
  parent app relies on locally applies inside the sandbox too: if this release
  is killed, the shepherd sees the UDS hang up and reaps the child. Nothing is
  reimplemented here.

  ## One exec per sandbox lifetime

  A second `POST /v1/exec` is a `409`, not a new process. A sandbox is a
  disposable unit bound to one session, its capture file is an append-only byte
  log with offsets the parent app persists, and a second process appending to
  it would interleave two output streams behind one cursor. If you want another
  process, take another sandbox.

  ## Env never enters argv

  `ps` works inside the sandbox, and the code running there is model-driven and
  untrusted, so `export KEY=secret` in a command string hands it every
  credential. `NetRunner` has no `:env` option — which is why
  `CrowdControl.Backend.Local` uses an env-file indirection — so the same
  mechanism is used here: a `0600` file inside a `0700` directory, sourced and
  `rm`'d by a wrapper shell before the CLI is `exec`'d.

  The wrapper passes the executable and its arguments through `"$@"`:

      /bin/sh -c '. "$0"; rm -f "$0"; exec "$@"' <env-file> <executable> <args...>

  so nothing but the env values ever needs shell quoting, and those are quoted
  where they are written. `CrowdControl.Backend.Local` interpolates escaped
  argv into the command string instead; that predates this module and has the
  same security property, but this shape has strictly less to get wrong.

  Env values are never logged. Neither is the env file's content.
  """

  use GenServer

  require Logger

  alias Sandboxd.Capture

  @type status :: %{
          alive: boolean(),
          exit_status: integer() | nil,
          bytes: non_neg_integer(),
          started: boolean()
        }

  # --- Client ---

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start the CLI. Returns `{:error, :already_executed}` on the second call.
  """
  @spec exec(String.t(), [String.t()], %{optional(String.t()) => String.t()}) ::
          :ok | {:error, term()}
  def exec(executable, args, env)
      when is_binary(executable) and is_list(args) and is_map(env) do
    GenServer.call(__MODULE__, {:exec, executable, args, env}, 30_000)
  end

  @doc "Append `data` to the CLI's stdin."
  @spec write(binary()) :: :ok | {:error, term()}
  def write(data) when is_binary(data), do: GenServer.call(__MODULE__, {:write, data})

  @doc "Liveness, exit status, and total captured bytes."
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Kill the CLI and finalize the capture.

  Teardown of the *sandbox* is the provider's job, never this process's.
  """
  @spec shutdown() :: :ok
  def shutdown, do: GenServer.call(__MODULE__, :shutdown, 10_000)

  # --- Server ---

  @impl true
  def init(_opts) do
    # Required, not decorative: NetRunner.Process.start_link/2 links to this
    # process and so does the reader, so without trapping exits either one
    # dying takes the only exec supervisor in the sandbox with it — and the
    # capture is never finalized, leaving every streaming client parked.
    Process.flag(:trap_exit, true)
    {:ok, %{proc: nil, reader: nil, exit_status: nil, started: false, env_dir: nil}}
  end

  @impl true
  def handle_call({:exec, _executable, _args, _env}, _from, %{started: true} = state) do
    {:reply, {:error, :already_executed}, state}
  end

  @impl true
  def handle_call({:exec, executable, args, env}, _from, state) do
    {cmd, cmd_args, env_dir} = wrap_with_env(executable, args, env)

    case NetRunner.Process.start_link(cmd, cmd_args) do
      {:ok, proc} ->
        # Reading is a blocking loop in a separate process, exactly as
        # CrowdControl.Backend.Local's reader is. It funnels every byte through
        # Capture.append/1, which is what makes waiter notification possible.
        parent = self()
        reader = spawn_link(fn -> reader_loop(proc, parent) end)

        Logger.info("exec started: #{executable} (#{length(args)} args)")
        {:reply, :ok, %{state | proc: proc, reader: reader, started: true, env_dir: env_dir}}

      {:error, reason} ->
        cleanup_env_dir(env_dir)
        Logger.error("exec failed to start: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:write, _data}, _from, %{proc: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    {:reply, safe_call(fn -> NetRunner.Process.write(state.proc, data) end, {:error, :closed}),
     state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       alive: alive?(state),
       exit_status: state.exit_status,
       bytes: Capture.bytes(),
       started: state.started
     }, state}
  end

  @impl true
  def handle_call(:shutdown, _from, state) do
    {:reply, :ok, terminate_child(state)}
  end

  # The reader hit EOF or the process exited: record the status and finalize the
  # capture so a streaming client stops waiting for bytes that will never come.
  @impl true
  def handle_info({:cli_exit, status}, state) do
    Capture.finalize()
    {:noreply, %{state | exit_status: status, proc: nil}}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{reader: pid} = state) do
    # Reader died without reporting an exit (its own crash, or the NetRunner
    # process going away underneath it). Finalize anyway: a client hanging on a
    # stream that can never advance is strictly worse than a missing status.
    Capture.finalize()
    {:noreply, %{state | reader: nil}}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = terminate_child(state)
    :ok
  end

  # --- Private ---

  defp reader_loop(proc, parent) do
    # safe_call, because NetRunner.Process.read/1 is a GenServer.call: a dead
    # NetRunner process raises an :exit here, and reporting :cli_exit is far
    # better than crashing and relying on the {:EXIT, reader, _} fallback.
    case safe_call(fn -> NetRunner.Process.read(proc) end, {:error, :down}) do
      {:ok, data} ->
        Capture.append(data)
        reader_loop(proc, parent)

      :eof ->
        status = safe_call(fn -> NetRunner.Process.await_exit(proc, 5_000) end, :timeout)
        send(parent, {:cli_exit, exit_status(status)})

      {:error, _reason} ->
        send(parent, {:cli_exit, nil})
    end
  end

  defp exit_status({:ok, status}), do: status
  defp exit_status(_), do: nil

  defp alive?(%{proc: nil}), do: false
  defp alive?(%{proc: proc}), do: safe_call(fn -> NetRunner.Process.alive?(proc) end, false)

  defp terminate_child(%{proc: nil} = state) do
    cleanup_env_dir(state.env_dir)
    %{state | env_dir: nil}
  end

  defp terminate_child(state) do
    _ = safe_call(fn -> NetRunner.Process.kill(state.proc, :sigterm) end, :ok)

    status =
      case safe_call(fn -> NetRunner.Process.await_exit(state.proc, 2_000) end, :timeout) do
        {:ok, status} ->
          status

        _ ->
          _ = safe_call(fn -> NetRunner.Process.kill(state.proc, :sigkill) end, :ok)
          _ = safe_call(fn -> NetRunner.Process.await_exit(state.proc, 2_000) end, :timeout)
          nil
      end

    Capture.finalize()
    cleanup_env_dir(state.env_dir)
    %{state | proc: nil, env_dir: nil, exit_status: state.exit_status || status}
  end

  defp wrap_with_env(executable, args, env) when map_size(env) == 0 do
    {executable, args, nil}
  end

  defp wrap_with_env(executable, args, env) do
    {dir, file} = write_env_file(env)

    # $0 is the env file; $@ is the executable and its arguments, so neither
    # needs quoting here and neither can be reinterpreted by the shell.
    {"/bin/sh", ["-c", ~s|. "$0"; rm -f "$0"; exec "$@"|, file, executable | args], dir}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_env_file(env) do
    random = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "sandboxd_env_#{random}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    path = Path.join(dir, "env.sh")
    content = Enum.map_join(env, "\n", fn {k, v} -> "export #{k}=#{single_quote(v)}" end)

    File.write!(path, content <> "\n")
    File.chmod!(path, 0o600)
    {dir, path}
  end

  # Single-quoting is the only POSIX shell quoting with no escapes inside it, so
  # the only case to handle is a literal quote: close, emit an escaped quote,
  # reopen. This must stay behaviourally identical to
  # `CrowdControl.Backend.Shell.escape/1` in the parent app. It is duplicated
  # rather than shared because this release deliberately cannot depend on it.
  defp single_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp cleanup_env_dir(nil), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_env_dir(dir) do
    _ = File.rm_rf(dir)
    :ok
  end

  # NetRunner's API is GenServer.call-based, so a dead or stale process raises
  # an :exit, never an :error. Catching only :exit is deliberate: a rescue here
  # would swallow genuine bugs and report them as "sandbox unavailable".
  defp safe_call(fun, default) do
    fun.()
  catch
    :exit, _ -> default
  end
end
