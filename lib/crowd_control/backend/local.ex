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

  ## A release's environment is not inherited

  NetRunner has no `:env` option, so the CLI inherits the BEAM's full OS
  environment. Inside a `mix release` that includes `RELEASE_COOKIE` (the
  distribution cookie), the other `RELEASE_*` boot variables, `BINDIR`,
  `ROOTDIR`, `EMU`, `PROGNAME`, and a `PATH` led by the release's `bin` and
  `erts-*/bin`. The wrapper shell therefore always runs (even with an empty
  env), and first `unset`s those names and exports a `PATH` without the
  release entries (see `CrowdControl.Backend.Shell.release_scrub/1`); only
  then does it source the env file, so an explicit `:env` value can still set
  a scrubbed name. Pass `release_env: :inherit` to opt out and hand the CLI
  the release's environment unchanged.

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
  def provision(opts) do
    case Keyword.get(opts, :release_env, :scrub) do
      mode when mode in [:scrub, :inherit] -> {:ok, %__MODULE__{opts: opts}}
      other -> {:error, {:invalid_option, {:release_env, other}}}
    end
  end

  @impl true
  def exec(%__MODULE__{} = handle, executable, args, env) do
    scrub = release_scrub(handle.opts)
    {cmd, cmd_args, env_dir, env_file} = wrap_with_env(executable, args, env, scrub)

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

  defp release_scrub(opts) do
    case Keyword.get(opts, :release_env, :scrub) do
      :inherit -> {[], nil}
      :scrub -> Shell.release_scrub(System.get_env())
    end
  end

  # Nothing to export and nothing to scrub means there is nothing for a wrapper
  # to do, so the CLI is spawned directly. Under a running BEAM that only
  # happens with `release_env: :inherit`: `erl` itself exports BINDIR, ROOTDIR,
  # EMU and PROGNAME.
  defp wrap_with_env(executable, args, env, {[], nil}) when map_size(env) == 0 do
    {executable, args, nil, nil}
  end

  # The scrub runs first so that an explicit `:env` entry can still set a
  # scrubbed name (PATH included). It is inline rather than in the env file
  # because it carries no secret: variable *names* and the PATH. The env file
  # stays reserved for `:env` values and is only created when there are some.
  defp wrap_with_env(executable, args, env, scrub) do
    {env_dir, env_file} = write_env_file(env)
    escaped_args = Enum.map_join([executable | args], " ", &Shell.escape/1)

    shell_cmd = scrub_prefix(scrub) <> source_prefix(env_file) <> "exec #{escaped_args}"

    {"/bin/sh", ["-c", shell_cmd], env_dir, env_file}
  end

  # `Shell.release_scrub/1` only returns names that are valid shell
  # identifiers, so they are safe to interpolate unquoted.
  defp scrub_prefix({unset, path}) do
    unset_cmd = if unset == [], do: "", else: "unset #{Enum.join(unset, " ")}; "
    path_cmd = if path, do: "PATH=#{Shell.escape(path)}; export PATH; ", else: ""
    unset_cmd <> path_cmd
  end

  defp source_prefix(nil), do: ""

  defp source_prefix(env_file),
    do: ". #{Shell.escape(env_file)} && rm -f #{Shell.escape(env_file)} && "

  defp write_env_file(env) when map_size(env) == 0, do: {nil, nil}

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
