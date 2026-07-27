defmodule CrowdControl.Backend.Mock do
  @moduledoc false
  # Hand-rolled test backend. Mox is deliberately not a dependency of this
  # project, and a behaviour with nine callbacks whose interesting property is
  # *sequencing* (reader delivers chunks, then :eof, then destroy is recorded)
  # is clearer as an Agent than as expectation scripting anyway.
  #
  # Usage (started under the ExUnit supervisor so it dies with the test):
  #
  #     ctl = start_supervised!({Mock, events: [{:stdout_data, "..."}, :eof]})
  #     Session.start_link(backend: {Mock, mock: ctl}, ...)
  #     assert Mock.destroy_count(ctl) == 1

  @behaviour CrowdControl.Backend

  defstruct [:ctl, :id, :session_key]

  @type ctl :: pid()
  @type t :: %__MODULE__{ctl: ctl(), id: String.t(), session_key: String.t() | nil}

  @poll_interval 5

  # --- Test-side control API ---

  @doc """
  Start a mock control process. Use via `start_supervised!/1` so ExUnit owns
  its lifecycle and it is torn down with the test.

  Options:

    * `:events` - reader events delivered in order; `{:stdout_data, bin}`,
      `:eof`, or `{:sleep, ms}`
    * `:live` - handles returned by `list_live/1`
    * `:reattachable` - whether `reattachable?/0` reports true (default `true`)
    * `:fail` - map of `callback_name => reason` to force `{:error, reason}`
  """
  @spec start_link(keyword()) :: {:ok, ctl()} | {:error, term()}
  def start_link(opts \\ []) do
    Agent.start_link(fn ->
      %{
        events: Keyword.get(opts, :events, []),
        live: Keyword.get(opts, :live, []),
        reattachable: Keyword.get(opts, :reattachable, true),
        fail: Keyword.get(opts, :fail, %{}),
        calls: [],
        writes: [],
        destroyed: []
      }
    end)
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Append reader events for an already-running reader to pick up."
  @spec push_events(ctl(), [term()]) :: :ok
  def push_events(ctl, events) do
    Agent.update(ctl, &%{&1 | events: &1.events ++ events})
  end

  @doc "Callback names in call order."
  @spec calls(ctl()) :: [atom()]
  def calls(ctl), do: Agent.get(ctl, &Enum.reverse(&1.calls))

  @doc "Everything written via `write/2`, in order."
  @spec writes(ctl()) :: [binary()]
  def writes(ctl), do: Agent.get(ctl, &Enum.reverse(&1.writes))

  @doc "Handle ids passed to `destroy/1`, in order. Repeats are kept."
  @spec destroyed(ctl()) :: [String.t()]
  def destroyed(ctl), do: Agent.get(ctl, &Enum.reverse(&1.destroyed))

  @doc "How many times `destroy/1` was called."
  @spec destroy_count(ctl()) :: non_neg_integer()
  def destroy_count(ctl), do: ctl |> destroyed() |> length()

  @doc "Replace what `list_live/1` reports."
  @spec set_live(ctl(), [t()]) :: :ok
  def set_live(ctl, live), do: Agent.update(ctl, &%{&1 | live: live})

  @doc "Build a handle without going through `provision/1`."
  @spec handle(ctl(), String.t()) :: t()
  def handle(ctl, id \\ "mock-handle"), do: %__MODULE__{ctl: ctl, id: id, session_key: id}

  # --- Backend callbacks ---

  @doc false
  def reattachable?, do: true

  @impl true
  def provision(opts) do
    ctl = Keyword.fetch!(opts, :mock)
    record(ctl, :provision)

    with :ok <- check_fail(ctl, :provision) do
      key = Keyword.get(opts, :session_key)

      {:ok,
       %__MODULE__{
         ctl: ctl,
         id: Keyword.get(opts, :mock_id, key || "mock-handle"),
         session_key: key
       }}
    end
  end

  @impl true
  def exec(%__MODULE__{ctl: ctl} = handle, _executable, _args, _env) do
    record(ctl, :exec)

    with :ok <- check_fail(ctl, :exec), do: {:ok, handle}
  end

  @impl true
  def start_reader(%__MODULE__{ctl: ctl}, session_pid, cursor) do
    record(ctl, :start_reader)

    with :ok <- check_fail(ctl, :start_reader) do
      # spawn_link, per the Backend reader contract: a dead reader must take
      # the session down rather than leave it silently deaf.
      {:ok, spawn_link(fn -> reader_loop(ctl, session_pid, cursor) end)}
    end
  end

  @impl true
  def write(%__MODULE__{ctl: ctl}, data) do
    record(ctl, :write)
    Agent.update(ctl, &%{&1 | writes: [IO.iodata_to_binary(data) | &1.writes]})

    check_fail(ctl, :write)
  end

  @impl true
  def await_exit(%__MODULE__{ctl: ctl}, _timeout) do
    record(ctl, :await_exit)
    {:ok, 0}
  end

  @impl true
  def alive?(%__MODULE__{ctl: ctl}) do
    record(ctl, :alive?)
    true
  end

  @impl true
  def destroy(%__MODULE__{ctl: ctl, id: id}) do
    record(ctl, :destroy)
    Agent.update(ctl, &%{&1 | destroyed: [id | &1.destroyed]})
    :ok
  end

  @impl true
  def list_live(opts) do
    case Keyword.get(opts, :mock) do
      nil ->
        {:ok, []}

      ctl ->
        record(ctl, :list_live)

        case Agent.get(ctl, & &1.fail)[:list_live] do
          nil -> {:ok, Agent.get(ctl, & &1.live)}
          reason -> {:error, reason}
        end
    end
  end

  @impl true
  def reattach(%__MODULE__{ctl: ctl} = handle, cursor) do
    record(ctl, :reattach)
    Agent.update(ctl, &Map.put(&1, :reattach_cursor, cursor))

    with :ok <- check_fail(ctl, :reattach), do: {:ok, handle}
  end

  @doc "The cursor the last `reattach/2` was called with."
  @spec reattach_cursor(ctl()) :: CrowdControl.Backend.cursor() | nil
  def reattach_cursor(ctl), do: Agent.get(ctl, &Map.get(&1, :reattach_cursor))

  # --- Private ---

  defp record(ctl, name), do: Agent.update(ctl, &%{&1 | calls: [name | &1.calls]})

  defp check_fail(ctl, name) do
    case Agent.get(ctl, & &1.fail)[name] do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  # Drains scripted events, polling so a test can push more after the session
  # has already started.
  defp reader_loop(ctl, session_pid, cursor) do
    case Agent.get_and_update(ctl, fn
           %{events: []} = s -> {nil, s}
           %{events: [e | rest]} = s -> {e, %{s | events: rest}}
         end) do
      nil ->
        Process.sleep(@poll_interval)
        reader_loop(ctl, session_pid, cursor)

      {:sleep, ms} ->
        Process.sleep(ms)
        reader_loop(ctl, session_pid, cursor)

      :eof ->
        GenServer.cast(session_pid, :eof)

      {:stdout_data, data} ->
        GenServer.cast(session_pid, {:stdout_data, data})
        reader_loop(ctl, session_pid, cursor)
    end
  end
end
