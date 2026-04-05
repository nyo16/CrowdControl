defmodule CrowdControl do
  @moduledoc """
  Orchestrate many Claude Code / Open Code CLI instances in parallel.
  """

  alias CrowdControl.Session

  @doc """
  Start a single session under the supervisor.

  Options are passed through to `CrowdControl.Session` and `CrowdControl.CLI`.
  See `CrowdControl.CLI.build_command/1` for available options.

  Additionally:
    * `:prompt` - initial prompt to send after the CLI starts
  """
  def start_session(opts \\ []) do
    case DynamicSupervisor.start_child(CrowdControl.SessionSupervisor, {Session, opts}) do
      {:error, :max_children} -> {:error, :max_sessions_reached}
      other -> other
    end
  end

  @doc """
  Returns `true` if the session supervisor is alive and healthy.
  """
  def healthy? do
    case Process.whereis(CrowdControl.SessionSupervisor) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Start multiple sessions in parallel.

  Takes a list of option keyword lists. Returns `{:ok, pids}` or
  `{:error, reason}` if any session fails to start.
  """
  def start_sessions(opts_list) do
    results =
      opts_list
      |> Task.async_stream(&start_session/1, max_concurrency: length(opts_list))
      |> Enum.map(fn {:ok, result} -> result end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, pid} -> pid end)}
    else
      {:error, errors}
    end
  end

  @doc """
  Send the same prompt to all sessions.
  """
  def broadcast(sessions, prompt) do
    Enum.each(sessions, &Session.send_prompt(&1, prompt))
  end

  @doc """
  Wait for all sessions to produce a result message.

  Subscribes to each session and collects `{:result, _, _}` messages.
  Returns a list of `{session_pid, result_message}` tuples.
  """
  def collect(sessions, timeout \\ 60_000) do
    Enum.each(sessions, &Session.subscribe/1)
    remaining = MapSet.new(sessions)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(remaining, %{}, deadline)
  end

  defp do_collect(remaining, results, _deadline) when map_size(remaining) == 0 do
    Enum.map(results, fn {pid, msg} -> {pid, msg} end)
  end

  defp do_collect(remaining, results, deadline) do
    now = System.monotonic_time(:millisecond)
    wait = max(deadline - now, 0)

    receive do
      {:crowd_control, pid, {:result, _, _} = msg} when is_map_key(remaining, pid) ->
        do_collect(MapSet.delete(remaining, pid), Map.put(results, pid, msg), deadline)

      {:crowd_control, _pid, _other} ->
        do_collect(remaining, results, deadline)
    after
      wait -> {:timeout, Enum.map(results, fn {pid, msg} -> {pid, msg} end)}
    end
  end

  @doc """
  Stop all sessions.
  """
  def stop_all(sessions) do
    Enum.each(sessions, fn session ->
      try do
        Session.stop(session)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  @doc """
  Single-shot convenience: start a session, send prompt, collect result, stop.
  """
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

  @doc """
  Start N sessions with different options but the same prompt, collect all results.
  """
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
