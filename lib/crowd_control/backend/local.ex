defmodule CrowdControl.Backend.Local do
  @moduledoc """
  Runs the CLI as a local subprocess via `NetRunner`.

  This is the default backend and it is behaviour-preserving: every mechanism
  here — the env-file indirection, the reap-probe/SIGTERM/SIGKILL escalation,
  the blocking reader loop — moved out of `CrowdControl.Session` unchanged when
  the `CrowdControl.Backend` behaviour was introduced.

  ## Env vars never appear in argv

  Environment variables are written to a `0600` file in a `0700` directory,
  sourced by a wrapper shell, and `rm`'d before the CLI is `exec`'d. Passing
  them on the command line instead would expose secrets — `ANTHROPIC_API_KEY`
  among them — to any user who can run `ps`. Remote backends have first-class
  env injection and no local `ps` to hide from, so **only this backend uses the
  env-file mechanism**.

  ## No reattach

  A local subprocess dies with the VM that spawned it, so there is nothing to
  reattach to: `list_live/1` returns `{:ok, []}` and `reattach/2` returns
  `{:error, :not_supported}`. `CrowdControl.Session` consequently skips all
  `CrowdControl.Store` writes for this backend — see
  `CrowdControl.Backend.reattachable?/1`.
  """

  @behaviour CrowdControl.Backend

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Shell

  # Short, non-destructive probe used to reap a subprocess that has already
  # exited. NetRunner answers immediately in that case; killing first would
  # leave it waiting on an exit it has already delivered.
  @reap_probe_timeout 50
  @kill_wait_timeout 1_000

  defstruct [:proc, :env_dir, :env_file, opts: []]

  @type t :: %__MODULE__{
          proc: pid() | nil,
          env_dir: Path.t() | nil,
          env_file: Path.t() | nil,
          opts: keyword()
        }

  @doc false
  @spec reattachable?() :: false
  def reattachable?, do: false

  @impl true
  def provision(opts), do: {:ok, %__MODULE__{opts: opts}}

  @impl true
  def exec(%__MODULE__{} = handle, executable, args, env) do
    {cmd, cmd_args, env_dir, env_file} = wrap_with_env(executable, args, env)

    # NetRunner.Process.start_link/2 links to the CALLING process, so this must
    # be invoked from inside Session.init/1 for the link to land on the session.
    case NetRunner.Process.start_link(cmd, cmd_args) do
      {:ok, proc} ->
        {:ok, %{handle | proc: proc, env_dir: env_dir, env_file: env_file}}

      {:error, reason} ->
        cleanup_env_dir(env_dir)
        {:error, reason}
    end
  end

  @impl true
  def start_reader(%__MODULE__{proc: proc}, session_pid, _cursor) when is_pid(proc) do
    {:ok, spawn_link(fn -> reader_loop(proc, session_pid) end)}
  end

  def start_reader(%__MODULE__{}, _session_pid, _cursor), do: {:error, :not_started}

  @impl true
  def write(%__MODULE__{proc: proc}, data) when is_pid(proc) do
    NetRunner.Process.write(proc, data)
    :ok
  end

  def write(%__MODULE__{}, _data), do: {:error, :not_started}

  @impl true
  def await_exit(%__MODULE__{proc: proc}, timeout), do: safe_await_exit(proc, timeout)

  @impl true
  def alive?(%__MODULE__{proc: proc}) when is_pid(proc), do: safe_alive?(proc)
  def alive?(%__MODULE__{}), do: false

  @impl true
  def destroy(%__MODULE__{} = handle) do
    shutdown_process(handle.proc)
    cleanup_env_dir(handle.env_dir)
    :ok
  end

  @impl true
  def list_live(_opts), do: {:ok, []}

  @impl true
  def reattach(%__MODULE__{}, _cursor), do: {:error, :not_supported}

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

  defp wrap_with_env(executable, args, env) when map_size(env) == 0 do
    {executable, args, nil, nil}
  end

  defp wrap_with_env(executable, args, env) do
    {env_dir, env_file} = write_env_file(env)
    escaped_args = Enum.map_join([executable | args], " ", &Shell.escape/1)

    shell_cmd =
      ". #{Shell.escape(env_file)} && rm -f #{Shell.escape(env_file)} && exec #{escaped_args}"

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
        "export #{k}=#{Shell.escape(v)}"
      end)

    File.write!(path, content <> "\n")
    File.chmod!(path, 0o600)
    {dir, path}
  end

  defp cleanup_env_dir(nil), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_env_dir(dir) do
    _ = File.rm_rf(dir)
    :ok
  end

  # Idempotent by construction: for an already-exited subprocess the reap probe
  # returns immediately, so a second destroy/1 costs one cheap call and skips
  # the escalation entirely. That is what makes calling destroy/1 from both
  # handle_cast(:eof, _) and terminate/2 safe.
  defp shutdown_process(nil), do: :ok

  defp shutdown_process(proc) do
    # Reap before killing. If the subprocess is already gone this returns
    # immediately; going straight to kill/2 would leave NetRunner blocked on an
    # exit it has already reported, costing the full timeout twice over.
    case safe_await_exit(proc, @reap_probe_timeout) do
      {:ok, _} -> :ok
      _ -> escalate_kill(proc)
    end

    :ok
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

  # See `CrowdControl.Backend.safe/2` for why these catch `:exit` and nothing
  # else. NetRunner has no remote failure shapes to normalize, so the local
  # backend needs no normalization beyond the exit catch.
  defp safe_await_exit(nil, _timeout), do: :timeout

  defp safe_await_exit(proc, timeout) do
    Backend.safe(fn -> NetRunner.Process.await_exit(proc, timeout) end, :timeout)
  end

  defp safe_alive?(proc) do
    Backend.safe(fn -> NetRunner.Process.alive?(proc) end, false)
  end

  defp safe_kill(proc, signal) do
    Backend.safe(fn -> NetRunner.Process.kill(proc, signal) end, :ok)
  end
end
