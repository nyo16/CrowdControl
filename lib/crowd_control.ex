defmodule CrowdControl do
  @moduledoc """
  Orchestrate many Claude Code / Open Code CLI instances in parallel.

  See `CrowdControl.CLI.build_command/1` for the full list of session options.
  """

  alias CrowdControl.Session

  @type opts :: keyword()
  @type session :: pid()
  @type result_message :: {:result, String.t(), map()}

  @doc """
  Start a single session under the supervisor.

  Options are passed through to `CrowdControl.Session` and `CrowdControl.CLI`.

  Additional option:
    * `:prompt` - initial prompt to send after the CLI starts
  """
  @spec start_session(opts()) :: {:ok, session()} | {:error, term()}
  def start_session(opts \\ []) do
    case DynamicSupervisor.start_child(CrowdControl.SessionSupervisor, {Session, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      :ignore -> {:error, :ignore}
      {:error, :max_children} -> {:error, :max_sessions_reached}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns `true` if the session supervisor is alive and healthy."
  @spec healthy?() :: boolean()
  def healthy? do
    case Process.whereis(CrowdControl.SessionSupervisor) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Start multiple sessions in parallel.

  Takes a list of option keyword lists. Returns `{:ok, pids}` if every
  session started, or `{:error, errors}` listing the failing entries.

  Concurrency is clamped to the configured `:max_sessions` cap.
  """
  @spec start_sessions([opts()]) :: {:ok, [session()]} | {:error, [term()]}
  def start_sessions([]), do: {:ok, []}

  def start_sessions(opts_list) when is_list(opts_list) do
    cap = Application.get_env(:crowd_control, :max_sessions, 50)
    concurrency = max(1, min(length(opts_list), cap))

    results =
      opts_list
      |> Task.async_stream(&start_session/1,
        max_concurrency: concurrency,
        on_timeout: :kill_task,
        timeout: :infinity
      )
      |> Enum.map(&normalize_task_result/1)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, pid} -> pid end)}
    else
      {:error, errors}
    end
  end

  defp normalize_task_result({:ok, {:ok, pid}}), do: {:ok, pid}
  defp normalize_task_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_task_result({:exit, reason}), do: {:error, {:task_exit, reason}}

  @doc "Send the same prompt to all sessions."
  @spec broadcast([session()], binary()) :: :ok
  def broadcast(sessions, prompt) do
    Enum.each(sessions, fn session ->
      try do
        Session.send_prompt(session, prompt)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  @doc """
  Wait for all sessions to produce a result message.

  Subscribes to each session and collects `{:result, _, _}` messages.
  Returns a list of `{session_pid, result_message}` tuples, or
  `{:timeout, partial_results}` if the deadline is reached first.
  """
  @spec collect([session()], pos_integer()) ::
          [{session(), result_message()}] | {:timeout, [{session(), result_message()}]}
  def collect(sessions, timeout \\ 60_000) do
    Enum.each(sessions, &Session.subscribe/1)
    remaining = Map.new(sessions, &{&1, true})
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(remaining, %{}, deadline)
  end

  defp do_collect(remaining, results, deadline) do
    if map_size(remaining) == 0 do
      Map.to_list(results)
    else
      do_collect_wait(remaining, results, deadline)
    end
  end

  defp do_collect_wait(remaining, results, deadline) do
    now = System.monotonic_time(:millisecond)
    wait = max(deadline - now, 0)

    receive do
      {:crowd_control, pid, {:result, _, _} = msg} ->
        if Map.has_key?(remaining, pid) do
          do_collect(Map.delete(remaining, pid), Map.put(results, pid, msg), deadline)
        else
          do_collect(remaining, results, deadline)
        end

      {:crowd_control, _pid, _other} ->
        do_collect(remaining, results, deadline)
    after
      wait -> {:timeout, Map.to_list(results)}
    end
  end

  @doc "Stop all sessions in parallel."
  @spec stop_all([session()]) :: :ok
  def stop_all(sessions) do
    sessions
    |> Task.async_stream(
      fn session ->
        try do
          Session.stop(session)
        catch
          :exit, _ -> :ok
        end
      end,
      max_concurrency: 16,
      ordered: false,
      on_timeout: :kill_task,
      timeout: 15_000
    )
    |> Stream.run()

    :ok
  end

  @doc "Single-shot convenience: start a session, send prompt, collect result, stop."
  @spec run(binary(), opts()) :: result_message() | {:error, term()}
  def run(prompt, opts \\ []) do
    opts = Keyword.put(opts, :prompt, prompt)

    with {:ok, session} <- start_session(opts) do
      Session.subscribe(session)
      result = wait_for_result(session, Keyword.get(opts, :timeout, 60_000))

      try do
        Session.stop(session)
      catch
        :exit, _ -> :ok
      end

      result
    end
  end

  @doc "Start N sessions with different options but the same prompt; collect all results."
  @spec run_many(binary(), [opts()]) ::
          [{session(), result_message()}]
          | {:timeout, [{session(), result_message()}]}
          | {:error, term()}
  def run_many(prompt, opts_list) do
    opts_list = Enum.map(opts_list, &Keyword.put(&1, :prompt, prompt))

    with {:ok, sessions} <- start_sessions(opts_list) do
      results = collect(sessions)
      stop_all(sessions)
      results
    end
  end

  defp wait_for_result(session, timeout) do
    receive do
      {:crowd_control, ^session, {:result, _, _} = msg} ->
        msg

      {:crowd_control, ^session, {:exit, _status}} ->
        {:error, :session_exited}

      {:crowd_control, ^session, _other} ->
        wait_for_result(session, timeout)
    after
      timeout -> {:error, :timeout}
    end
  end
end
