defmodule CrowdControl do
  @moduledoc """
  Orchestrate many coding-agent CLI instances in parallel.

  Claude Code, Open Code and [omp](https://omp.sh/) are supported; pick one per
  session with `:agent` (see `CrowdControl.Agent`). Every agent reports through
  the same message contract, so a mixed fan-out collects uniformly.

  See `CrowdControl.CLI.build_command/1` (Claude Code / Open Code) and
  `CrowdControl.Agent.Omp` (omp) for the full list of session options.
  """

  alias CrowdControl.{Backend, RateLimit, Result, Retry, Session, Telemetry}
  alias CrowdControl.Session.Control

  defmodule Seen do
    @moduledoc false
    # What a collector learnt per session: the result it waited for, the
    # spend, the latest rate-limit report, and which sessions answered in the
    # current round.

    alias CrowdControl.{RateLimit, Result}

    defstruct results: %{}, costs: %{}, rate_limits: %{}, answered: MapSet.new()

    def result(seen, pid, msg) do
      %{seen | results: Map.put(seen.results, pid, msg), answered: MapSet.put(seen.answered, pid)}
    end

    def new_round(seen), do: %{seen | answered: MapSet.new()}

    # Claude Code's `total_cost_usd` is the CLI process's running total, so the
    # highest seen is the session's spend, whatever order replays arrive in.
    # omp's is that turn's own cost, so it is kept per turn and summed.
    #
    # Result lines can be forged from inside the sandbox, so a cost may only
    # ever raise what is recorded: a negative one is ignored and every entry
    # keeps its highest value. (A forged result can still stand in for the
    # real one; SECURITY.md has what that leaves.)
    def cost(seen, pid, {:result, _, map} = msg) do
      case {Result.cost_usd(msg), map["agent"]} do
        {usd, "omp"} when is_number(usd) and usd >= 0 -> raise_cost(seen, {pid, map["turn"]}, usd)
        {usd, _cumulative} when is_number(usd) and usd >= 0 -> raise_cost(seen, pid, usd)
        _absent_or_negative -> seen
      end
    end

    defp raise_cost(seen, key, usd),
      do: %{seen | costs: Map.update(seen.costs, key, usd, &max(&1, usd))}

    def rate_limit(seen, pid, msg) do
      case RateLimit.from_event(msg) do
        {:ok, rate_limit} -> %{seen | rate_limits: Map.put(seen.rate_limits, pid, rate_limit)}
        :error -> seen
      end
    end

    def over?(_seen, nil), do: false
    def over?(seen, budget), do: seen.costs |> Map.values() |> Enum.sum() >= budget

    def results(seen, sessions) do
      for pid <- Enum.uniq(sessions),
          Map.has_key?(seen.results, pid),
          do: {pid, seen.results[pid]}
    end
  end

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
  Returns a list of `{session_pid, result_message}` tuples in the order of
  `sessions`, or `{:timeout, partial_results}` if the deadline is reached
  first.

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

  ## Options

    * `:budget_usd` - stop waiting once the sessions together have spent this
      much, returning `{:budget_exceeded, partial_results}` at once; a set
      that completes as it crosses the cap is returned as a plain list. Spend
      is each Claude Code session's latest `total_cost_usd`, which the CLI
      counts for its whole process (so turns before this call count too), and
      the sum of an omp session's per-turn costs. The sessions are left
      running: stop or interrupt them yourself. Against a non-Anthropic
      endpoint the CLI prices tokens it cannot price, so the sum means nothing
      there.
  """
  @spec collect([session()], pos_integer(), keyword()) ::
          [{session(), result_message()}]
          | {:timeout, [{session(), result_message()}]}
          | {:budget_exceeded, [{session(), result_message()}]}
  def collect(sessions, timeout \\ 60_000, opts \\ []) do
    budget = budget!(Keyword.validate!(opts, [:budget_usd]))
    waiting = Map.new(sessions, &{&1, current_turn(&1)})
    Enum.each(sessions, &Session.subscribe/1)
    deadline = System.monotonic_time(:millisecond) + timeout

    {status, seen} = collect_from(waiting, deadline, budget, %Seen{})
    outcome(status, seen, sessions)
  end

  defp budget!(opts) do
    case Keyword.get(opts, :budget_usd) do
      nil ->
        nil

      usd when is_number(usd) and usd > 0 ->
        usd

      other ->
        raise ArgumentError, ":budget_usd must be a positive number, got: #{inspect(other)}"
    end
  end

  defp outcome(:done, seen, sessions), do: Seen.results(seen, sessions)
  defp outcome(status, seen, sessions), do: {status, Seen.results(seen, sessions)}

  # A session that dies between the read and the subscribe is handled by the
  # terminal-message branch in collect_from/4; treat it as turn 0 here
  # rather than crashing the collector.
  defp current_turn(session) do
    Session.current_turn(session)
  catch
    :exit, _ -> 0
  end

  # `waiting` maps each session still owed a result to the first turn that
  # counts; the caller has already subscribed to all of them. Returns
  # `{:done | :timeout | :budget_exceeded, seen}`.
  defp collect_from(waiting, _deadline, _budget, seen) when map_size(waiting) == 0,
    do: {:done, seen}

  defp collect_from(waiting, deadline, budget, seen) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:crowd_control, pid, {:result, _, map} = msg}
      when is_map_key(waiting, pid) and is_map(map) ->
        seen = Seen.cost(seen, pid, msg)

        # An earlier turn's result is a replay: its cost counts, it does not.
        {waiting, seen} =
          if Map.get(map, "turn", waiting[pid]) >= waiting[pid],
            do: {Map.delete(waiting, pid), Seen.result(seen, pid, msg)},
            else: {waiting, seen}

        # A complete set is returned as such; the cap only cuts a wait short.
        if map_size(waiting) > 0 and Seen.over?(seen, budget),
          do: {:budget_exceeded, seen},
          else: collect_from(waiting, deadline, budget, seen)

      {:crowd_control, pid, {:rate_limit, _} = msg} when is_map_key(waiting, pid) ->
        collect_from(waiting, deadline, budget, Seen.rate_limit(seen, pid, msg))

      # Terminal for this session: it can never produce a result now, so stop
      # waiting on it instead of burning the whole deadline. wait_for_result/2
      # already short-circuits on these; collect/2 did not, which left
      # run_many/2 blocked for the full 60s on any session that errored.
      {:crowd_control, pid, {terminal, _}} when terminal in [:exit, :error, :timeout] ->
        collect_from(Map.delete(waiting, pid), deadline, budget, seen)

      {:crowd_control, _pid, _other} ->
        collect_from(waiting, deadline, budget, seen)
    after
      wait -> {:timeout, seen}
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

  ## Retry

  `retry: true` (the defaults) or `retry: [max_retries: 5, ...]` re-sends the
  prompt into the *same* session when the result is a transient API failure
  from a turn that ran no tools; `CrowdControl.Retry` has the rule, the delays
  and the options. The backstop restarts for each attempt, and every re-send
  emits `[:crowd_control, :retry]`. The last result is returned whatever it
  was. Off by default; the option is not passed on to the session.
  """
  @spec run(binary(), opts()) :: result_message() | {:error, term()}
  def run(prompt, opts \\ []) do
    {retry, opts} = Keyword.pop(opts, :retry)
    retry = Retry.new!(retry)
    opts = Keyword.put(opts, :prompt, prompt)

    with {:ok, session} <- start_session(opts) do
      # `retry_on` is the caller's code: whatever it does, the session stops.
      try do
        Session.subscribe(session)
        run_attempt(session, prompt, opts, retry, 0, {0, nil})
      after
        try do
          Session.stop(session)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  # The last argument is `{first turn that counts, latest rate limit seen}`.
  defp run_attempt(session, prompt, opts, retry, attempt, {from_turn, rate_limit}) do
    {result, rate_limit} = wait_for_result(session, run_deadline(opts), from_turn, rate_limit)

    with %Retry{max_retries: max} when attempt < max <- retry,
         {:result, _, _} <- result,
         true <- Retry.retryable?(result, retry),
         {:ok, delay} <- Retry.delay(attempt, retry, rate_limit) do
      retry_event(session, attempt + 1, delay, result)
      Process.sleep(delay)

      case resend(session, prompt) do
        {:ok, turn} -> run_attempt(session, prompt, opts, retry, attempt + 1, {turn, rate_limit})
        {:error, _} -> result
      end
    else
      _no_retry -> result
    end
  end

  defp retry_event(session, attempt, delay, result) do
    Telemetry.execute(
      [:crowd_control, :retry],
      %{system_time: System.system_time(), delay_ms: delay},
      %{session: session, attempt: attempt, category: Retry.category(result)}
    )
  end

  # The turn the re-sent prompt starts, so its wait skips anything older.
  defp resend(session, prompt) do
    case Session.send_prompt(session, prompt) do
      :ok -> {:ok, Session.current_turn(session)}
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :session_exited}
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

  @doc """
  Start N sessions with different options but the same prompt; collect all
  results, in the order of `opts_list`, then stop the sessions.

  ## Options

    * `:retry` - as for `run/2`, in rounds: once every session has answered,
      the ones with a retryable result are re-sent the prompt together after
      one delay, the longest any of them needs, and only they are waited for
      again. A session's last result is kept whatever it was.
    * `:budget_usd` - as for `collect/3`: once the sessions together have
      spent this much, `{:budget_exceeded, partial_results}` is returned and
      the sessions are stopped, which ends any turn still running. No retry
      round starts over budget.
  """
  @spec run_many(binary(), [opts()], keyword()) ::
          [{session(), result_message()}]
          | {:timeout, [{session(), result_message()}]}
          | {:budget_exceeded, [{session(), result_message()}]}
          | {:error, term()}
  def run_many(prompt, opts_list, opts \\ []) do
    opts = Keyword.validate!(opts, [:retry, :budget_usd])
    retry = Retry.new!(opts[:retry])
    budget = budget!(opts)
    opts_list = Enum.map(opts_list, &Keyword.put(&1, :prompt, prompt))

    with {:ok, sessions} <- start_sessions(opts_list) do
      try do
        waiting = Map.new(sessions, &{&1, current_turn(&1)})
        Enum.each(sessions, &Session.subscribe/1)

        {status, seen} = run_round(waiting, prompt, retry, budget, 0, %Seen{})
        outcome(status, seen, sessions)
      after
        stop_all(sessions)
      end
    end
  end

  defp run_round(waiting, prompt, retry, budget, attempt, seen) do
    deadline = System.monotonic_time(:millisecond) + 60_000

    case collect_from(waiting, deadline, budget, Seen.new_round(seen)) do
      # Only a session that answered this round can be retried: one that
      # expired or exited instead still holds an older result.
      {:done, seen} ->
        answered = Enum.filter(Map.keys(waiting), &MapSet.member?(seen.answered, &1))
        retry_round(answered, prompt, retry, budget, attempt, seen)

      stopped ->
        stopped
    end
  end

  # One delay for the round, the longest any retried session needs; a session
  # whose rate limit resets beyond `:max_delay_ms` keeps its result.
  defp retry_round(pids, prompt, %Retry{max_retries: max} = retry, budget, attempt, seen)
       when attempt < max do
    delays =
      for pid <- pids,
          {:ok, result} <- [Map.fetch(seen.results, pid)],
          Retry.retryable?(result, retry),
          {:ok, delay} <- [Retry.delay(attempt, retry, seen.rate_limits[pid])],
          do: {pid, delay}

    cond do
      delays == [] ->
        {:done, seen}

      Seen.over?(seen, budget) ->
        {:budget_exceeded, seen}

      true ->
        delay = delays |> Enum.map(&elem(&1, 1)) |> Enum.max()

        Enum.each(delays, fn {pid, _} ->
          retry_event(pid, attempt + 1, delay, seen.results[pid])
        end)

        Process.sleep(delay)

        waiting =
          for {pid, _} <- delays, {:ok, turn} <- [resend(pid, prompt)], into: %{}, do: {pid, turn}

        run_round(waiting, prompt, retry, budget, attempt + 1, seen)
    end
  end

  defp retry_round(_pids, _prompt, _retry, _budget, _attempt, seen), do: {:done, seen}

  # `deadline` is an absolute `System.monotonic_time(:millisecond)` value, or
  # `:infinity`. Each non-result message recomputes the remaining wait against
  # it instead of restarting the full timeout window (which made the deadline
  # unbounded under a steady stream of intermediate messages). Results of a
  # turn before `from_turn` are skipped; the latest rate limit is returned
  # with the outcome, for the retry delay.
  defp wait_for_result(session, deadline, from_turn, rate_limit) do
    wait =
      if deadline == :infinity,
        do: :infinity,
        else: max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:crowd_control, ^session, {:result, _, map} = msg} ->
        if Map.get(map, "turn", from_turn) >= from_turn,
          do: {msg, rate_limit},
          else: wait_for_result(session, deadline, from_turn, rate_limit)

      {:crowd_control, ^session, {:rate_limit, _} = msg} ->
        rate_limit =
          case RateLimit.from_event(msg) do
            {:ok, latest} -> latest
            :error -> rate_limit
          end

        wait_for_result(session, deadline, from_turn, rate_limit)

      {:crowd_control, ^session, {:exit, _status}} ->
        {{:error, :session_exited}, rate_limit}

      {:crowd_control, ^session, {:error, _reason} = err} ->
        {err, rate_limit}

      # The session hit its own expiry, interrupt grace included: the turn's
      # timeout, from the caller's perspective.
      {:crowd_control, ^session, {:timeout, _}} ->
        {{:error, :timeout}, rate_limit}

      {:crowd_control, ^session, _other} ->
        wait_for_result(session, deadline, from_turn, rate_limit)
    after
      wait -> {{:error, :timeout}, rate_limit}
    end
  end
end
