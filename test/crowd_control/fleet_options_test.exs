defmodule CrowdControl.FleetOptionsTest do
  # `:retry` on run/2 and run_many/3, `:budget_usd` on collect/3 and
  # run_many/3, against Backend.Mock: the test plays the CLI, answering each
  # prompt the session writes with a scripted result.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Mock
  alias CrowdControl.{Session, TestHelpers}

  def retry_execution_errors(result) do
    match?(
      {:error, %CrowdControl.Error{kind: :execution_error}},
      CrowdControl.Result.classify(result)
    )
  end

  def explode(_result), do: raise("policy bug")

  defp line(map), do: JSON.encode!(map) <> "\n"

  defp ok(fields \\ %{}) do
    Map.merge(
      %{"type" => "result", "subtype" => "success", "is_error" => false, "num_turns" => 1},
      fields
    )
  end

  defp overloaded(fields \\ %{}) do
    Map.merge(
      %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => true,
        "terminal_reason" => "api_error",
        "api_error_status" => 529,
        "num_turns" => 1,
        "result" => "API Error: 529 Overloaded"
      },
      fields
    )
  end

  defp session_opts(ctl, extra \\ []),
    do: Keyword.merge([backend: {Mock, mock: ctl}, executable: "claude", timeout: 10_000], extra)

  defp prompts(ctl), do: for(%{"type" => "user", "uuid" => uuid} <- writes(ctl), do: uuid)
  defp writes(ctl), do: Enum.map(Mock.writes(ctl), &JSON.decode!/1)

  # Waits for prompt number `n` and answers it with `result` (plus `frames`
  # before it), echoing its uuid as the CLI does.
  defp answer(ctl, n, result, frames \\ []) do
    TestHelpers.wait_until(fn -> length(prompts(ctl)) >= n end)
    uuid = Enum.at(prompts(ctl), n - 1)
    lines = Enum.map(frames, &line/1) ++ [line(Map.put(result, "user_message_uuid", uuid))]
    Mock.push_events(ctl, Enum.map(lines, &{:stdout_data, &1}))
  end

  defp provisions(ctl), do: Enum.count(Mock.calls(ctl), &(&1 == :provision))

  describe "run/2 :retry" do
    test "an overloaded result is re-sent into the same session, then succeeds" do
      ctl = start_supervised!({Mock, events: []})

      run =
        Task.async(fn ->
          CrowdControl.run("hi", session_opts(ctl, retry: [base_delay_ms: 10]))
        end)

      answer(ctl, 1, overloaded())
      answer(ctl, 2, ok(%{"result" => "second time lucky"}))

      assert {:result, "success", %{"result" => "second time lucky", "turn" => 2}} =
               Task.await(run)

      assert length(prompts(ctl)) == 2
      assert provisions(ctl) == 1
    end

    test "a turn that ran tools is not re-sent" do
      ctl = start_supervised!({Mock, events: []})

      run =
        Task.async(fn ->
          CrowdControl.run("hi", session_opts(ctl, retry: [base_delay_ms: 10]))
        end)

      answer(ctl, 1, overloaded(%{"num_turns" => 3}))

      assert {:result, _, %{"num_turns" => 3}} = Task.await(run)
      assert length(prompts(ctl)) == 1
    end

    test "a rejected rate limit resetting beyond max_delay_ms is not waited for" do
      ctl = start_supervised!({Mock, events: []})

      run =
        Task.async(fn ->
          CrowdControl.run(
            "hi",
            session_opts(ctl, retry: [base_delay_ms: 10, max_delay_ms: 5_000])
          )
        end)

      rate_limit = %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => "rejected",
          "resetsAt" => System.os_time(:second) + 3_600
        }
      }

      answer(ctl, 1, overloaded(%{"api_error_status" => 429}), [rate_limit])

      assert {:result, _, %{"api_error_status" => 429}} = Task.await(run)
      assert length(prompts(ctl)) == 1
    end

    test "retry_on opts in to results the default rule leaves alone" do
      ctl = start_supervised!({Mock, events: []})
      retry = [base_delay_ms: 10, retry_on: {__MODULE__, :retry_execution_errors, []}]
      run = Task.async(fn -> CrowdControl.run("hi", session_opts(ctl, retry: retry)) end)

      answer(ctl, 1, %{
        "type" => "result",
        "subtype" => "error_during_execution",
        "errors" => ["boom"]
      })

      answer(ctl, 2, ok())

      assert {:result, "success", _} = Task.await(run)
    end

    test "max_retries bounds the re-sends and the last result is returned" do
      ctl = start_supervised!({Mock, events: []})

      run =
        Task.async(fn ->
          CrowdControl.run("hi", session_opts(ctl, retry: [base_delay_ms: 10, max_retries: 2]))
        end)

      for n <- 1..3, do: answer(ctl, n, overloaded(%{"result" => "API Error: 529 try #{n}"}))

      assert {:result, _, %{"result" => "API Error: 529 try 3", "turn" => 3}} = Task.await(run)
      assert length(prompts(ctl)) == 3
    end

    test "without :retry nothing is re-sent" do
      ctl = start_supervised!({Mock, events: []})
      run = Task.async(fn -> CrowdControl.run("hi", session_opts(ctl)) end)

      answer(ctl, 1, overloaded())
      assert {:result, _, %{"api_error_status" => 529}} = Task.await(run)
      assert length(prompts(ctl)) == 1
    end

    test "a bad :retry, or a retry_on that does not exist, raises before any session starts" do
      ctl = start_supervised!({Mock, events: []})

      for retry <- [:often, [retry_on: {__MODULE__, :no_such_function, []}]] do
        assert_raise ArgumentError, ~r/:retry/, fn ->
          CrowdControl.run("hi", session_opts(ctl, retry: retry))
        end
      end

      assert Mock.calls(ctl) == []
    end

    test "a retry_on that raises still stops the session" do
      ctl = start_supervised!({Mock, events: []})
      retry = [base_delay_ms: 10, retry_on: {__MODULE__, :explode, []}]

      run =
        Task.async(fn -> catch_error(CrowdControl.run("hi", session_opts(ctl, retry: retry))) end)

      answer(ctl, 1, ok())
      assert %RuntimeError{message: "policy bug"} = Task.await(run)
      assert Mock.destroy_count(ctl) == 1
    end
  end

  describe "run_many/3 :retry" do
    test "re-sends only the failing session and keeps the input order" do
      [a, b] = for _ <- 1..2, do: start_supervised!({Mock, events: []})

      run =
        Task.async(fn ->
          CrowdControl.run_many("hi", [session_opts(a), session_opts(b)],
            retry: [base_delay_ms: 10]
          )
        end)

      answer(b, 1, ok(%{"result" => "b"}))
      answer(a, 1, overloaded())
      answer(a, 2, ok(%{"result" => "a"}))

      assert [{_, {:result, _, %{"result" => "a"}}}, {_, {:result, _, %{"result" => "b"}}}] =
               Task.await(run)

      assert length(prompts(a)) == 2
      assert length(prompts(b)) == 1
    end

    test "the third argument takes only :retry and :budget_usd" do
      assert_raise ArgumentError, fn -> CrowdControl.run_many("hi", [], timeout: 5) end

      assert_raise ArgumentError, ~r/:budget_usd/, fn ->
        CrowdControl.run_many("hi", [], budget_usd: 0)
      end
    end
  end

  describe ":budget_usd" do
    defp started(n) do
      for _ <- 1..n do
        ctl = start_supervised!({Mock, events: []})
        {:ok, pid} = Session.start_link(session_opts(ctl, prompt: "go"))
        {ctl, pid}
      end
    end

    test "collect/3 returns what it has once the sessions together cross the cap" do
      [{c1, p1}, {c2, p2}, {_c3, p3}] = started(3)
      collect = Task.async(fn -> CrowdControl.collect([p1, p2, p3], 5_000, budget_usd: 1.0) end)

      answer(c1, 1, ok(%{"total_cost_usd" => 0.4}))
      answer(c2, 1, ok(%{"total_cost_usd" => 0.7}))

      assert {:budget_exceeded, [{^p1, _}, {^p2, _}]} = Task.await(collect, 10_000)
      # collect/3 never stops the sessions it was handed.
      assert Process.alive?(p3)
      Enum.each([p1, p2, p3], &TestHelpers.stop_session/1)
    end

    test "a session's cumulative total is counted once, not per result" do
      [{c1, p1}, {c2, p2}, {_c3, p3}] = started(3)
      answer(c1, 1, ok(%{"total_cost_usd" => 0.5}))
      Session.subscribe(p1)
      assert_receive {:crowd_control, ^p1, {:result, _, _}}, 2_000
      :ok = Session.send_prompt(p1, "again")

      collect =
        Task.async(fn -> CrowdControl.collect([p1, p2, p3], 1_000, budget_usd: 1.0) end)

      answer(c1, 2, ok(%{"total_cost_usd" => 0.6}))
      answer(c2, 1, ok(%{"total_cost_usd" => 0.3}))

      # 0.6 + 0.3 stays under the cap, so the wait for p3 runs out; counting
      # 0.5 + 0.6 + 0.3 would have cut it short.
      assert {:timeout, [{^p1, {:result, _, %{"turn" => 2}}}, {^p2, _}]} =
               Task.await(collect, 10_000)

      Enum.each([p1, p2, p3], &TestHelpers.stop_session/1)
    end

    test "a forged negative cost cannot offset the others' spend" do
      [{c1, p1}, {c2, p2}, {_c3, p3}] = started(3)

      # p1's forged result is in its history before collect/3 starts, and
      # collect/3 subscribes to p1 before p2, so it is counted first: the two
      # mock readers are separate processes, and their order is not guaranteed.
      answer(c1, 1, ok(%{"total_cost_usd" => -1.0e12}))
      Session.subscribe(p1)
      assert_receive {:crowd_control, ^p1, {:result, _, _}}, 2_000

      collect = Task.async(fn -> CrowdControl.collect([p1, p2, p3], 5_000, budget_usd: 1.0) end)
      answer(c2, 1, ok(%{"total_cost_usd" => 1.2}))

      assert {:budget_exceeded, [{^p1, _}, {^p2, _}]} = Task.await(collect, 10_000)
      Enum.each([p1, p2, p3], &TestHelpers.stop_session/1)
    end

    test "a complete set is returned as such even when it crosses the cap" do
      [{c1, p1}, {c2, p2}] = started(2)
      collect = Task.async(fn -> CrowdControl.collect([p1, p2], 5_000, budget_usd: 0.5) end)

      answer(c1, 1, ok(%{"total_cost_usd" => 0.4}))
      answer(c2, 1, ok(%{"total_cost_usd" => 0.4}))

      assert [{^p1, _}, {^p2, _}] = Task.await(collect, 10_000)
      Enum.each([p1, p2], &TestHelpers.stop_session/1)
    end

    # omp's total_cost_usd is that turn's own cost, not the process's; a
    # forged zero-cost agent_end for the same turn cannot lower it.
    test "omp turns are summed, not maxed, and a forged zero cannot lower one" do
      [{c1, p1}, {_c2, p2}] =
        for _ <- 1..2 do
          ctl = start_supervised!({Mock, events: []})

          {:ok, pid} =
            Session.start_link(session_opts(ctl, agent: :omp, executable: "omp", prompt: "go"))

          {ctl, pid}
        end

      agent_end = fn cost ->
        line(%{
          "type" => "agent_end",
          "messages" => [%{"role" => "assistant", "usage" => %{"cost" => %{"total" => cost}}}]
        })
      end

      Mock.push_events(c1, [
        {:stdout_data, agent_end.(0.6)},
        {:stdout_data, line(%{"type" => "agent_end", "messages" => []})}
      ])

      Session.subscribe(p1)

      for _ <- 1..2,
          do: assert_receive({:crowd_control, ^p1, {:result, _, %{"turn" => 1}}}, 2_000)

      :ok = Session.send_prompt(p1, "again")

      collect = Task.async(fn -> CrowdControl.collect([p1, p2], 5_000, budget_usd: 1.0) end)
      Mock.push_events(c1, [{:stdout_data, agent_end.(0.5)}])

      assert {:budget_exceeded, [{^p1, {:result, _, %{"turn" => 2}}}]} =
               Task.await(collect, 10_000)

      Enum.each([p1, p2], &TestHelpers.stop_session/1)
    end

    test "run_many/3 stops the sessions and starts no retry round over budget" do
      [a, b] = for _ <- 1..2, do: start_supervised!({Mock, events: []})

      run =
        Task.async(fn ->
          CrowdControl.run_many("hi", [session_opts(a), session_opts(b)],
            budget_usd: 0.5,
            retry: [base_delay_ms: 10]
          )
        end)

      answer(a, 1, overloaded(%{"total_cost_usd" => 0.6}))

      assert {:budget_exceeded, [{_, {:result, _, %{"api_error_status" => 529}}}]} =
               Task.await(run)

      assert length(prompts(a)) == 1
      assert Mock.destroy_count(a) == 1 and Mock.destroy_count(b) == 1
    end

    test "run_many/3 starts no retry round once a retry has crossed the cap" do
      [a, b] = for _ <- 1..2, do: start_supervised!({Mock, events: []})

      run =
        Task.async(fn ->
          CrowdControl.run_many("hi", [session_opts(a), session_opts(b)],
            budget_usd: 0.5,
            retry: [base_delay_ms: 10, max_retries: 5]
          )
        end)

      answer(b, 1, ok(%{"total_cost_usd" => 0.1}))
      answer(a, 1, overloaded(%{"total_cost_usd" => 0.2}))
      answer(a, 2, overloaded(%{"total_cost_usd" => 0.45}))

      assert {:budget_exceeded, [{_, {:result, _, %{"total_cost_usd" => 0.45}}}, {_, _}]} =
               Task.await(run, 10_000)

      assert length(prompts(a)) == 2
    end

    test "a non-positive or non-numeric budget raises" do
      for bad <- [0, -1, "1"] do
        assert_raise ArgumentError, ~r/:budget_usd/, fn ->
          CrowdControl.collect([], 10, budget_usd: bad)
        end
      end

      assert_raise ArgumentError, fn -> CrowdControl.collect([], 10, timeout: 5) end
    end
  end
end
