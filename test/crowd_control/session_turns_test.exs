defmodule CrowdControl.SessionTurnsTest do
  # Turn attribution by prompt uuid, rate-limit frames and the idle timeout,
  # driven through Backend.Mock: every frame the CLI "sends" is scripted and
  # every frame the session writes is recorded.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Mock
  alias CrowdControl.{Protocol, RateLimit, Session, Store, TestHelpers}

  def defer(_request, _context), do: :defer

  defp line(map), do: JSON.encode!(map) <> "\n"

  defp result(extra) do
    line(Map.merge(%{"type" => "result", "subtype" => "success", "is_error" => false}, extra))
  end

  defp keep_alive, do: line(%{"type" => "keep_alive"})

  defp start(ctl, opts) do
    Session.start_link(
      Keyword.merge([backend: {Mock, mock: ctl}, executable: "claude", timeout: 60_000], opts)
    )
  end

  defp decoded_writes(ctl), do: Enum.map(Mock.writes(ctl), &JSON.decode!/1)

  defp prompt_uuids(ctl),
    do: for(%{"type" => "user", "uuid" => uuid} <- decoded_writes(ctl), do: uuid)

  defp interrupts(ctl) do
    for %{"type" => "control_request", "request" => %{"subtype" => "interrupt"}} = frame <-
          decoded_writes(ctl),
        do: frame
  end

  # Two prompts written, neither answered yet.
  defp two_prompts(opts \\ []) do
    ctl = start_supervised!({Mock, events: []})
    {:ok, pid} = start(ctl, Keyword.put(opts, :prompt, "one"))
    :ok = Session.send_prompt(pid, "two")
    :ok = Session.subscribe(pid)
    [u1, u2] = prompt_uuids(ctl)
    {ctl, pid, u1, u2}
  end

  describe "turn attribution" do
    test "each prompt carries the deterministic uuid of its turn" do
      {_ctl, pid, u1, u2} = two_prompts()
      key = :sys.get_state(pid).store_key

      assert u1 == Protocol.prompt_uuid(key, 1)
      assert u2 == Protocol.prompt_uuid(key, 2)
      TestHelpers.stop_session(pid)
    end

    test "a result that arrives after a later prompt keeps its own turn" do
      {ctl, pid, u1, u2} = two_prompts()

      Mock.push_events(ctl, [{:stdout_data, result(%{"user_message_uuid" => u1})}])
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 1, "turns" => [1]}}}, 2_000

      Mock.push_events(ctl, [{:stdout_data, result(%{"user_message_uuid" => u2})}])
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 2, "turns" => [2]}}}, 2_000

      TestHelpers.stop_session(pid)
    end

    test "a coalesced result is stamped with its newest turn and lists them all" do
      {ctl, pid, u1, u2} = two_prompts()

      Mock.push_events(ctl, [{:stdout_data, result(%{"user_message_uuids" => [u2, u1, 7]})}])

      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 2, "turns" => [1, 2]}}},
                     2_000

      TestHelpers.stop_session(pid)
    end

    test "without an echo, or with an unknown uuid, the newest prompt is the turn" do
      {ctl, pid, _u1, _u2} = two_prompts()

      Mock.push_events(ctl, [
        {:stdout_data, result(%{})},
        {:stdout_data, result(%{"user_message_uuid" => "not-ours"})}
      ])

      for _ <- 1..2 do
        assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 2} = map}}, 2_000
        refute Map.has_key?(map, "turns")
      end

      TestHelpers.stop_session(pid)
    end

    # The output capture is writable from inside the sandbox, so a result line
    # may carry any "turn"/"turns" it likes; the session's own values replace them.
    test "a forged turn or turns on the result line is replaced, not trusted" do
      {ctl, pid, _u1, _u2} = two_prompts()

      Mock.push_events(ctl, [
        {:stdout_data, result(%{"turns" => nil, "turn" => 99})},
        {:stdout_data,
         result(%{"turns" => "x", "user_message_uuids" => List.duplicate("y", 10_000)})}
      ])

      for _ <- 1..2 do
        assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 2} = map}}, 2_000
        refute Map.has_key?(map, "turns")
      end

      assert Process.alive?(pid)
      TestHelpers.stop_session(pid)
    end

    # 2.1.292 omits the echo on some interrupted results. The turn after it
    # still echoes its uuid, and must keep its own number even once a newer
    # prompt has been written.
    test "an echo arriving after an echo-less result keeps its own turn" do
      {ctl, pid, _u1, u2} = two_prompts()

      Mock.push_events(ctl, [{:stdout_data, result(%{"subtype" => "error_during_execution"})}])
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 2}}}, 2_000

      :ok = Session.send_prompt(pid, "three")
      Mock.push_events(ctl, [{:stdout_data, result(%{"user_message_uuid" => u2})}])
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 2, "turns" => [2]}}}, 2_000

      TestHelpers.stop_session(pid)
    end

    test "the singular and list echoes are read together" do
      {ctl, pid, u1, _u2} = two_prompts()

      Mock.push_events(ctl, [
        {:stdout_data, result(%{"user_message_uuids" => [], "user_message_uuid" => u1})}
      ])

      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 1, "turns" => [1]}}}, 2_000
      TestHelpers.stop_session(pid)
    end

    test "command_lifecycle frames are not passed on" do
      {ctl, pid, u1, _u2} = two_prompts()
      lifecycle = %{"type" => "command_lifecycle", "command_uuid" => u1, "state" => "started"}

      Mock.push_events(ctl, [
        {:stdout_data, line(lifecycle)},
        {:stdout_data, result(%{"user_message_uuid" => u1})}
      ])

      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 2_000
      refute_received {:crowd_control, ^pid, {:unknown, _}}
      refute Enum.any?(Session.get_messages(pid), &match?({:unknown, _}, &1))
      TestHelpers.stop_session(pid)
    end

    test "collect/2 started after the second prompt ignores the first prompt's result" do
      {ctl, pid, u1, u2} = two_prompts()
      # collect/3 reads the turn before subscribing, so whenever it attaches,
      # result 1 is older than what it waits for.
      collector = Task.async(fn -> CrowdControl.collect([pid], 5_000) end)

      Mock.push_events(ctl, [
        {:stdout_data, result(%{"user_message_uuid" => u1, "result" => "first"})}
      ])

      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 1}}}, 2_000

      Mock.push_events(ctl, [
        {:stdout_data, result(%{"user_message_uuid" => u2, "result" => "second"})}
      ])

      assert [{^pid, {:result, _, %{"turn" => 2, "result" => "second"}}}] =
               Task.await(collector, 10_000)

      TestHelpers.stop_session(pid)
    end

    test "a reattached session keeps its turns and attributes the pending result" do
      Process.flag(:trap_exit, true)
      {ctl, pid, u1, u2} = two_prompts()
      key = :sys.get_state(pid).store_key

      Mock.push_events(ctl, [{:stdout_data, result(%{"user_message_uuid" => u1})}])
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 1}}}, 2_000

      TestHelpers.wait_until(fn ->
        match?({:ok, %{control: %{turns: %{attributed: 1}}}}, Store.get(key))
      end)

      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      {:ok, record} = Store.get(key)
      assert record.control.turns == %{prompt_seq: 2, attributed: 1}

      {:ok, pid} = Session.start_reattached(record)
      assert Session.current_turn(pid) == 2
      :ok = Session.subscribe(pid)

      Mock.push_events(ctl, [{:stdout_data, result(%{"user_message_uuid" => u2})}])
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 2, "turns" => [2]}}}, 2_000

      TestHelpers.stop_session(pid)
    end

    test "a record without turns reattaches at turn 0, as before" do
      key = "turns-" <> Store.new_key()

      ctl =
        start_supervised!({Mock, events: [{:stdout_data, result(%{"user_message_uuid" => "x"})}]})

      record =
        Store.build(
          key: key,
          backend: Mock,
          handle: Mock.handle(ctl, key),
          opts: [executable: "claude", timeout: 60_000],
          control: %{pending: %{}, turn_deadline_at: nil, paused_remaining_ms: nil}
        )

      {:ok, pid} = Session.start_reattached(record)
      :ok = Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 0}}}, 2_000
      TestHelpers.stop_session(pid)
    end
  end

  describe "rate_limit_event" do
    test "is broadcast as {:rate_limit, frame} and kept in history" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, prompt: "one")
      :ok = Session.subscribe(pid)

      frame = %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{"status" => "rejected", "resetsAt" => 1_762_800_000}
      }

      Mock.push_events(ctl, [{:stdout_data, line(frame)}])
      assert_receive {:crowd_control, ^pid, {:rate_limit, ^frame} = event}, 2_000

      assert {:ok, %RateLimit{status: :rejected, resets_at: 1_762_800_000}} =
               RateLimit.from_event(event)

      assert {:rate_limit, frame} in Session.get_messages(pid)

      TestHelpers.stop_session(pid)
    end
  end

  describe ":idle_timeout" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "fires on a silent turn and broadcasts {:timeout, :idle_expired}" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, prompt: "one", idle_timeout: 100, interrupt_grace: 0)
      :ok = Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:timeout, :idle_expired}}, 1_000
      assert Mock.destroy_count(ctl) == 1
    end

    test "is reset by any output, keep_alive included" do
      heartbeats = List.duplicate([{:stdout_data, keep_alive()}, {:sleep, 100}], 10)

      ctl =
        start_supervised!(
          {Mock, events: List.flatten(heartbeats) ++ [{:stdout_data, result(%{})}]}
        )

      {:ok, pid} = start(ctl, prompt: "one", idle_timeout: 500, interrupt_grace: 0)
      :ok = Session.subscribe(pid)

      # ~1 s of heartbeats, twice the idle timeout, then the result.
      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 3_000
      refute_received {:crowd_control, ^pid, {:timeout, _}}
      TestHelpers.stop_session(pid)
    end

    test "is not armed between turns" do
      ctl = start_supervised!({Mock, events: [{:stdout_data, result(%{})}]})
      {:ok, pid} = start(ctl, prompt: "one", idle_timeout: 100, interrupt_grace: 0)
      :ok = Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 2_000
      refute_receive {:crowd_control, ^pid, {:timeout, _}}, 300

      # The next prompt arms it again.
      :ok = Session.send_prompt(pid, "two")
      assert_receive {:crowd_control, ^pid, {:timeout, :idle_expired}}, 1_000
    end

    test "stops while a permission request is pending and restarts in full once answered" do
      request = %{
        "type" => "control_request",
        "request_id" => "p1",
        "request" => %{"subtype" => "can_use_tool", "tool_name" => "Bash", "input" => %{}}
      }

      ctl = start_supervised!({Mock, events: [{:stdout_data, line(request)}]})

      {:ok, pid} =
        start(ctl,
          prompt: "one",
          idle_timeout: 300,
          interrupt_grace: 0,
          can_use_tool: {__MODULE__, :defer, []}
        )

      :ok = Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:control_request, "p1", _, _}}, 2_000
      refute_receive {:crowd_control, ^pid, {:timeout, _}}, 700

      # A full window again from the answer, not what was left before it.
      :ok = Session.respond(pid, "p1", {:allow, %{}})
      refute_receive {:crowd_control, ^pid, {:timeout, _}}, 200
      assert_receive {:crowd_control, ^pid, {:timeout, :idle_expired}}, 1_000
    end

    test "interrupts first, and a result within the grace keeps the session" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, prompt: "one", idle_timeout: 100, interrupt_grace: 2_000)
      :ok = Session.subscribe(pid)

      TestHelpers.wait_until(fn -> interrupts(ctl) != [] end)
      Mock.push_events(ctl, [{:stdout_data, result(%{"subtype" => "error_during_execution"})}])

      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 2_000
      refute_receive {:crowd_control, ^pid, {:timeout, _}}, 300
      assert Process.alive?(pid)
      assert Mock.destroy_count(ctl) == 0
      TestHelpers.stop_session(pid)
    end

    test "no result within the grace expires with :idle_expired" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, prompt: "one", idle_timeout: 100, interrupt_grace: 200)
      :ok = Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:timeout, :idle_expired}}, 2_000
      assert [_interrupt] = interrupts(ctl)
    end

    test "starts a fresh window after a reattach when a prompt is still waiting" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, idle_timeout: 600, interrupt_grace: 0)
      :ok = Session.send_prompt(pid, "one")
      key = :sys.get_state(pid).store_key

      TestHelpers.wait_until(fn ->
        match?({:ok, %{control: %{turns: %{prompt_seq: 1}}}}, Store.get(key))
      end)

      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      {:ok, record} = Store.get(key)
      {:ok, pid} = Session.start_reattached(record)
      :ok = Session.subscribe(pid)

      refute_receive {:crowd_control, ^pid, {:timeout, _}}, 300
      assert_receive {:crowd_control, ^pid, {:timeout, :idle_expired}}, 2_000
    end

    test "must be a positive integer" do
      ctl = start_supervised!({Mock, events: []})

      for bad <- [0, -5, 1.5, :infinity] do
        assert {:error, {%ArgumentError{message: message}, _}} = start(ctl, idle_timeout: bad)
        assert message =~ ":idle_timeout must be a positive integer"
      end

      assert Mock.calls(ctl) == []
    end
  end
end
