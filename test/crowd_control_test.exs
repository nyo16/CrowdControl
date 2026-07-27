defmodule CrowdControlTest do
  use ExUnit.Case, async: false

  alias CrowdControl.{Session, TestHelpers}

  describe "start_session/1" do
    test "returns {:ok, pid} for a valid session" do
      assert {:ok, pid} = CrowdControl.start_session(executable: TestHelpers.fake_cli_path())
      assert Process.alive?(pid)
      TestHelpers.stop_session(pid)
    end
  end

  describe "start_sessions/1" do
    test "returns {:ok, []} for empty list" do
      assert {:ok, []} = CrowdControl.start_sessions([])
    end

    test "starts multiple sessions in parallel" do
      opts_list =
        for _ <- 1..3, do: [executable: TestHelpers.fake_cli_path(), timeout: 10_000]

      assert {:ok, pids} = CrowdControl.start_sessions(opts_list)
      assert length(pids) == 3
      assert Enum.all?(pids, &Process.alive?/1)

      CrowdControl.stop_all(pids)
    end
  end

  describe "broadcast/2" do
    test "sends the same prompt to every session" do
      opts_list = for _ <- 1..2, do: [executable: TestHelpers.fake_cli_path(), timeout: 10_000]
      {:ok, pids} = CrowdControl.start_sessions(opts_list)
      Enum.each(pids, &Session.subscribe/1)

      :ok = CrowdControl.broadcast(pids, "hello")

      for pid <- pids do
        assert_receive {:crowd_control, ^pid, {:result, _, _}}, 5_000
      end

      CrowdControl.stop_all(pids)
    end
  end

  describe "collect/2" do
    test "returns {pid, result} tuples for every session" do
      opts_list = for _ <- 1..2, do: [executable: TestHelpers.fake_cli_path(), timeout: 10_000]
      {:ok, pids} = CrowdControl.start_sessions(opts_list)
      CrowdControl.broadcast(pids, "hello")

      results = CrowdControl.collect(pids, 5_000)
      assert length(results) == 2

      assert Enum.all?(results, fn {pid, msg} ->
               pid in pids and match?({:result, "success", _}, msg)
             end)

      CrowdControl.stop_all(pids)
    end

    test "returns {:timeout, partial} if any session does not produce a result in time" do
      opts_list = [
        [executable: TestHelpers.fake_cli_path(), timeout: 10_000],
        [
          executable: TestHelpers.fake_cli_path(),
          env: %{"FAKE_CLI_SLEEP" => "5"},
          timeout: 10_000
        ]
      ]

      {:ok, pids} = CrowdControl.start_sessions(opts_list)
      CrowdControl.broadcast(pids, "hello")

      assert {:timeout, _partial} = CrowdControl.collect(pids, 500)
      CrowdControl.stop_all(pids)
    end

    test "returns results for sessions that finished before collect subscribed" do
      # run_many/2 sends the prompt from init/1 and only subscribes afterwards,
      # so a fast CLI can emit its result before collect/2 attaches. The result
      # must still be delivered rather than lost.
      {:ok, pid} =
        CrowdControl.start_session(
          executable: TestHelpers.fake_cli_path(),
          timeout: 5_000,
          prompt: "hi"
        )

      TestHelpers.wait_until(fn ->
        CrowdControl.Session.get_status(pid) == :completed
      end)

      assert [{^pid, {:result, _, _}}] = CrowdControl.collect([pid], 2_000)

      CrowdControl.stop_all([pid])
    end
  end

  describe "run/2" do
    test "happy path returns a result tuple" do
      assert {:result, "success", %{"result" => "done:hi"}} =
               CrowdControl.run("hi", executable: TestHelpers.fake_cli_path(), timeout: 5_000)
    end

    test "returns {:error, :timeout} when the session takes too long" do
      assert {:error, :timeout} =
               CrowdControl.run("slow",
                 executable: TestHelpers.fake_cli_path(),
                 env: %{"FAKE_CLI_SLEEP" => "5"},
                 timeout: 300
               )
    end

    test "times out on an absolute deadline under a steady non-result stream" do
      # A continuous stream of assistant (non-result) messages must not keep
      # pushing the deadline out. Discrimination window:
      #   * fixed (absolute) deadline  -> returns at ~1000ms (1x the timeout)
      #   * regressed resetting window -> the session self-expires at 1000ms and
      #     stops the stream; the last timer reset is that expiry message, so the
      #     stale window fires ~1000ms later, i.e. ~2000ms (2x).
      # Both are real monotonic timers (no large drift), so the 1500ms midpoint
      # cleanly separates correct (<1500ms) from regressed (~2000ms).
      {elapsed_us, result} =
        :timer.tc(fn ->
          CrowdControl.run("go",
            executable: TestHelpers.fake_cli_path(),
            env: %{"FAKE_CLI_STREAM_NORESULT" => "100"},
            timeout: 1_000
          )
        end)

      assert result == {:error, :timeout}

      assert div(elapsed_us, 1_000) < 1_500,
             "expected timeout near the 1000ms deadline, took #{div(elapsed_us, 1_000)}ms"
    end
  end

  describe "run_many/2" do
    test "fans out the same prompt across configurations" do
      opts_list = for _ <- 1..2, do: [executable: TestHelpers.fake_cli_path(), timeout: 5_000]
      results = CrowdControl.run_many("hi", opts_list)

      assert length(results) == 2
      assert Enum.all?(results, fn {_pid, msg} -> match?({:result, _, _}, msg) end)
    end
  end

  describe "stop_all/1" do
    test "swallows :exit from already-dead sessions" do
      {:ok, pid} = CrowdControl.start_session(executable: TestHelpers.fake_cli_path())
      TestHelpers.stop_session(pid)
      Process.sleep(50)

      assert :ok = CrowdControl.stop_all([pid])
    end
  end

  describe "healthy?/0" do
    test "returns true while the supervisor is registered" do
      assert CrowdControl.healthy?() == true
    end
  end
end
