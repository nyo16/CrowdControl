defmodule CrowdControl do
  @moduledoc """
  Orchestrate many coding-agent CLI instances in parallel.

  Claude Code, Open Code and [omp](https://omp.sh/) are supported; pick one per
  session with `:agent` (see `CrowdControl.Agent`). Every agent reports through
  the same message contract, so a mixed fan-out collects uniformly.

  See `CrowdControl.CLI.build_command/1` (Claude Code / Open Code) and
  `CrowdControl.Agent.Omp` (omp) for the full list of session options.
  """

  alias CrowdControl.{Backend, Session}
  alias CrowdControl.Session.Control

  # Per-session start ceiling for `start_sessions/1`. Without a finite timeout,
  # `on_timeout: :kill_task` is dead code and a wedged start blocks the stream
  # forever. A killed start normalizes to `{:error, {:task_exit, _}}`.
  @start_timeout 30_000

  # Slack on top of a run's turn timeout and interrupt grace before `run/2`
  # gives up on a session that never reported its own expiry (a wedged
  # session): enough for the expiry's teardown and broadcast to land.
  @run_margin 30_000

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
        timeout: @start_timeout
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

  A session that broadcasts a terminal message instead of a result -- it
  exited, expired, or hit `:line_too_large` -- is dropped from the wait set
  rather than waited out, since it can never produce one. Such a session is
  simply absent from the returned list, so the list can be shorter than
  `sessions`.

  Results are matched by turn. `Session.subscribe/1` replays history, so a
  session already carrying a finished turn would otherwise hand the collector
  that old result the instant it attached -- returning stale data for a turn
  still in flight. Each session's `Session.current_turn/1` is read *before*
  subscribing, and only results stamped with that turn or later are accepted.
  """
  @spec collect([session()], pos_integer()) ::
          [{session(), result_message()}] | {:timeout, [{session(), result_message()}]}
  def collect(sessions, timeout \\ 60_000) do
    remaining = Map.new(sessions, &{&1, current_turn(&1)})
    Enum.each(sessions, &Session.subscribe/1)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(remaining, %{}, deadline)
  end

  # A session that dies between the read and the subscribe is handled by the
  # terminal-message branch in do_collect_wait/3; treat it as turn 0 here
  # rather than crashing the collector.
  defp current_turn(session) do
    Session.current_turn(session)
  catch
    :exit, _ -> 0
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
      {:crowd_control, pid, {:result, _, map} = msg} ->
        case Map.fetch(remaining, pid) do
          {:ok, from_turn} when is_map(map) ->
            if Map.get(map, "turn", from_turn) >= from_turn do
              do_collect(Map.delete(remaining, pid), Map.put(results, pid, msg), deadline)
            else
              # A replayed result from an earlier turn. Keep waiting.
              do_collect(remaining, results, deadline)
            end

          _ ->
            do_collect(remaining, results, deadline)
        end

      # Terminal for this session: it can never produce a result now, so stop
      # waiting on it instead of burning the whole deadline. wait_for_result/2
      # already short-circuits on these; collect/2 did not, which left
      # run_many/2 blocked for the full 60s on any session that errored.
      {:crowd_control, pid, {terminal, _}} when terminal in [:exit, :error, :timeout] ->
        do_collect(Map.delete(remaining, pid), results, deadline)

      {:crowd_control, _pid, _other} ->
        do_collect(remaining, results, deadline)
    after
      wait -> {:timeout, Map.to_list(results)}
    end
  end

  @doc """
  Stop all sessions in parallel.

  Waits for every session's teardown, which `CrowdControl.Session.stop/1`
  does not bound (see there): a Kubernetes sandbox with drained sidecars can
  take most of a minute to be destroyed.
  """
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
      timeout: :infinity
    )
    |> Stream.run()

    :ok
  end

  @doc """
  Single-shot convenience: start a session, send prompt, collect result, stop.

  Returns the `{:result, subtype, map}` message, or `{:error, reason}`:
  `{:error, :timeout}` when the session expired (its turn outlived
  `:timeout`), `{:error, :session_exited}`, or the session's own error.

  The wait follows the session's own clock rather than a separate one: the
  session's turn timer pauses while a permission request (or a deferred hook)
  waits on an answer, and when the deadline passes a control-capable agent is
  first interrupted and given `:interrupt_grace` to report its result, which
  `run/2` then returns. A human-in-the-loop `:can_use_tool` may therefore hold
  the turn for longer than `:timeout`. `run/2` keeps one wall-clock backstop
  for a session that never reports anything: `:timeout` plus
  `:interrupt_grace` (given at the top level or in the `backend:` config,
  #{div(Control.default_interrupt_grace(), 1_000)} s when unset) plus #{div(@run_margin, 1_000)} s,
  counted once the session has started. That backstop is not paused, so an
  approval held longer than it ends the run with `{:error, :timeout}`; for an
  open-ended human wait use `start_session/1` and `CrowdControl.Session`
  directly, or `timeout: :infinity`.
  """
  @spec run(binary(), opts()) :: result_message() | {:error, term()}
  def run(prompt, opts \\ []) do
    opts = Keyword.put(opts, :prompt, prompt)

    with {:ok, session} <- start_session(opts) do
      Session.subscribe(session)
      result = wait_for_result(session, run_deadline(opts))

      try do
        Session.stop(session)
      catch
        :exit, _ -> :ok
      end

      result
    end
  end

  # `:infinity` when the session never expires on its own, so neither does
  # the wait.
  defp run_deadline(opts) do
    case Keyword.get(opts, :timeout, Session.default_timeout()) do
      timeout when is_integer(timeout) ->
        System.monotonic_time(:millisecond) + timeout + run_grace(opts) + @run_margin

      _nil_or_infinity ->
        :infinity
    end
  end

  # The grace run/2's backstop allows for. Resolved from the same opts the
  # session resolves it from (Backend.resolve/1, so a `backend: {_, kw}` value
  # wins over a top-level one), falling back to the default a control-feature
  # session gets: the backstop must never be shorter than the session's own.
  @doc false
  @spec run_grace(opts()) :: non_neg_integer()
  def run_grace(opts) do
    {_backend, resolved} = Backend.resolve(opts)
    Keyword.get(resolved, :interrupt_grace) || Control.default_interrupt_grace()
  end

  @doc """
  Like `run/2`, but returns the result map of a successful turn and raises
  `CrowdControl.Error` otherwise.

  A result that classifies as an error (see `CrowdControl.Result.classify/1`)
  raises with that error's kind. A run that produced no result at all (a start
  failure, a timeout, the session exiting) raises with kind `:session_error`
  and the `run/2` error term as its `reason`.
  """
  @spec run!(binary(), opts()) :: map()
  def run!(prompt, opts \\ []) do
    case run(prompt, opts) do
      {:result, _, _} = result ->
        case classify(result) do
          {:ok, map} -> map
          {:error, error} -> raise error
        end

      {:error, reason} ->
        raise CrowdControl.Error, kind: :session_error, reason: reason
    end
  end

  @doc "Classify a `{:result, subtype, map}` message. See `CrowdControl.Result.classify/1`."
  @spec classify(result_message()) :: {:ok, map()} | {:error, CrowdControl.Error.t()}
  defdelegate classify(result), to: CrowdControl.Result

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

  # `deadline` is an absolute `System.monotonic_time(:millisecond)` value, or
  # `:infinity`. Each non-result message recomputes the remaining wait against
  # it instead of restarting the full timeout window (which made the deadline
  # unbounded under a steady stream of intermediate messages).
  defp wait_for_result(session, deadline) do
    wait =
      if deadline == :infinity,
        do: :infinity,
        else: max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:crowd_control, ^session, {:result, _, _} = msg} ->
        msg

      {:crowd_control, ^session, {:exit, _status}} ->
        {:error, :session_exited}

      {:crowd_control, ^session, {:error, _reason} = err} ->
        err

      # The session hit its own expiry, interrupt grace included: the turn's
      # timeout, from the caller's perspective.
      {:crowd_control, ^session, {:timeout, _}} ->
        {:error, :timeout}

      {:crowd_control, ^session, _other} ->
        wait_for_result(session, deadline)
    after
      wait -> {:error, :timeout}
    end
  end
end
