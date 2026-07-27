defmodule CrowdControl.Store.ETS do
  @moduledoc """
  In-memory `CrowdControl.Store`. The default.

  A named public table owned by this GenServer, so reads and writes go straight
  to ETS from the session process with no serialization through a single mailbox
  — `Session` writes on every stdout chunk, and funnelling that through one
  process would make the store the bottleneck for every session at once.

  Survives a session crash: the sandbox stays labelled, the record stays in the
  table, and `CrowdControl.Reaper` can reattach. Does **not** survive a node
  restart — the table dies with the VM. Use `CrowdControl.Store.DETS` for that.
  """

  @behaviour CrowdControl.Store

  use GenServer

  @table :crowd_control_sessions

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    _ =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end

  @impl CrowdControl.Store
  def put(session_id, record) do
    :ets.insert(@table, {session_id, record})
    :ok
  end

  @impl CrowdControl.Store
  def get(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, record}] -> {:ok, record}
      [] -> :error
    end
  end

  @impl CrowdControl.Store
  def delete(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end

  @impl CrowdControl.Store
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, record} -> record end)
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table
end
