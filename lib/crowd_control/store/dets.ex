defmodule CrowdControl.Store.DETS do
  @moduledoc """
  Disk-backed `CrowdControl.Store`. Survives a node restart, adds no dependency.

  Opt in with:

      config :crowd_control, :store,
        {CrowdControl.Store.DETS, path: "/var/lib/crowd_control/sessions.dets"}

  ## Durability

  Every write is followed by `:dets.sync/1`. That is deliberately the slow,
  correct choice: the whole reason this store exists is to survive an ungraceful
  death, and a record still sitting in a DETS buffer when the node is SIGKILLed
  is a leaked container nobody can find. Sessions that write frequently and can
  tolerate loss should use `CrowdControl.Store.ETS` instead.

  ## Scope

  This is a *node-local* durable store, not a distributed one. Two nodes
  pointing at two different DETS files each see only their own sessions — which
  is why sandbox ownership is enforced by label (`CrowdControl.Store.owner_id/0`)
  rather than by store contents. Callers wanting a shared view implement
  `CrowdControl.Store` over Ecto or Redis.
  """

  @behaviour CrowdControl.Store

  use GenServer

  require Logger

  @table :crowd_control_sessions_dets

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = resolve_path(opts)

    case :dets.open_file(@table, file: to_charlist(path), type: :set, auto_save: 1_000) do
      {:ok, @table} ->
        restrict_permissions(path)
        Logger.info("CrowdControl.Store.DETS opened at #{path}")
        {:ok, %{path: path}}

      {:error, reason} ->
        {:stop, {:dets_open_failed, path, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, _state) do
    _ = :dets.close(@table)
    :ok
  end

  @impl CrowdControl.Store
  def put(session_id, record) do
    :ok = :dets.insert(@table, {session_id, record})
    _ = :dets.sync(@table)
    :ok
  end

  @impl CrowdControl.Store
  def get(session_id) do
    case :dets.lookup(@table, session_id) do
      [{^session_id, record}] -> {:ok, record}
      _ -> :error
    end
  end

  @impl CrowdControl.Store
  def delete(session_id) do
    :ok = :dets.delete(@table, session_id)
    _ = :dets.sync(@table)
    :ok
  end

  @impl CrowdControl.Store
  def all do
    @table
    |> :dets.match_object({:_, :_})
    |> Enum.map(fn {_id, record} -> record end)
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc "The default on-disk location when `:path` is not configured."
  @spec default_path() :: Path.t()
  def default_path, do: Path.join(System.tmp_dir!(), "crowd_control_sessions.dets")

  # Session records are not secret by design -- `Session` scrubs credentials
  # before persisting -- but they still carry session ids, prompt-adjacent
  # buffered output, and sandbox handles. On a shared host the default location
  # is a world-readable temp dir, so lock the file down to its owner. This
  # mirrors the 0600-file-in-a-0700-dir treatment the local env file gets.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp restrict_permissions(path) do
    _ = File.chmod(Path.dirname(path), 0o700)

    case File.chmod(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not restrict permissions on #{path}: #{inspect(reason)}")
        :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp resolve_path(opts) do
    path =
      opts[:path] || Application.get_env(:crowd_control, :store_path) || default_path()

    path
    |> Path.dirname()
    |> File.mkdir_p!()

    path
  end
end
