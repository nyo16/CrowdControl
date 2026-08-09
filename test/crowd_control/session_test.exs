defmodule CrowdControl.SessionTest do
  use ExUnit.Case, async: true

  alias CrowdControl.{Session, TestHelpers}

  describe "init/1" do
    test "fails to start with a nonexistent executable" do
      Process.flag(:trap_exit, true)

      result =
        Session.start_link(executable: "/nonexistent/binary/that/does/not/exist", timeout: 1_000)

      case result do
        {:error, _reason} ->
          :ok

        {:ok, pid} ->
          # NetRunner forked successfully and the exec failed in the child, so
          # the failure surfaces as the subprocess exiting non-zero. Assert on
          # that directly: waiting for the session process itself to die would
          # be waiting on the unrelated :timeout, whose shutdown path can take
          # seconds when NetRunner is slow to report the exit.
          Session.subscribe(pid)
          assert_receive {:crowd_control, ^pid, {:exit, status}}, 5_000
          refute status == 0

          TestHelpers.stop_session(pid)
      end
    end

    test "a subscriber that attaches after the subprocess finished still gets its messages" do
      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          timeout: 5_000,
          prompt: "hi"
        )

      # Subscribe strictly after the session has already broadcast everything.
      TestHelpers.wait_until(fn -> Session.get_status(pid) == :completed end)

      Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:system_init, _}}, 2_000
      assert_receive {:crowd_control, ^pid, {:result, "success", _}}, 2_000

      TestHelpers.stop_session(pid)
    end

    # The env-file mechanism is Backend.Local's alone -- remote backends inject
    # env through their own API and must never touch it. These three tests reach
    # into backend_state.env_dir directly, so they are tagged local-only rather
    # than deleted: they are the oracle proving secrets never reach argv.
    @tag backend: :local
    test "cleans up env dir when subprocess exits via EOF (not via Session.stop)" do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          env: %{"FOO" => "bar"},
          timeout: 10_000
        )

      Session.subscribe(pid)

      # Pin THIS session's own env dir straight from its state. Diffing the
      # shared tmp dir before/after was racy: a concurrent async test creating
      # its own cc_env_* dir in the window landed in the "ours" set.
      our_dir = :sys.get_state(pid).backend_state.env_dir
      assert is_binary(our_dir) and File.dir?(our_dir)

      # Drive a single prompt so fake_cli emits result and exits 0 → EOF path.
      :ok = Session.send_prompt(pid, "x")
      assert_receive {:crowd_control, ^pid, {:exit, _}}, 5_000

      # cleanup_env_dir/1 runs in handle_cast(:eof) *before* the {:exit, _}
      # broadcast, so the dir must be gone by the time we receive it.
      refute File.dir?(our_dir), "expected our env dir cleaned via EOF path: #{our_dir}"
    end
  end

  describe "resource bounds" do
    test "nil bounds fall back to defaults rather than disabling the guard" do
      # Term ordering puts numbers below atoms, so a nil that reached the guard
      # would make `byte_size(x) > nil` always false -- silently unbounded.
      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          max_line_bytes: nil,
          max_messages: nil,
          timeout: 5_000
        )

      state = :sys.get_state(pid)
      assert is_integer(state.max_line_bytes) and state.max_line_bytes > 0
      assert is_integer(state.max_messages) and state.max_messages > 0

      TestHelpers.stop_session(pid)
    end

    test "a non-integer bound is rejected loudly" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _}} =
               Session.start_link(
                 executable: TestHelpers.fake_cli_path(),
                 max_messages: :unlimited,
                 timeout: 5_000
               )
    end
  end

  describe "send_prompt validation" do
    test "rejects non-binary prompt" do
      {:ok, pid} = start_fake_session()
      assert {:error, :invalid_prompt} = Session.send_prompt(pid, :not_a_string)
      TestHelpers.stop_session(pid)
    end

    test "rejects prompt with null byte" do
      {:ok, pid} = start_fake_session()
      assert {:error, :invalid_prompt} = Session.send_prompt(pid, "hi\0there")
      TestHelpers.stop_session(pid)
    end

    test "rejects prompt with invalid UTF-8" do
      {:ok, pid} = start_fake_session()
      assert {:error, :invalid_prompt} = Session.send_prompt(pid, <<0xFF, 0xFE>>)
      TestHelpers.stop_session(pid)
    end

    test "rejects prompt exceeding max_prompt_size" do
      {:ok, pid} = start_fake_session(max_prompt_size: 5)
      assert {:error, :prompt_too_large} = Session.send_prompt(pid, "abcdef")
      TestHelpers.stop_session(pid)
    end

    test "accepts prompt exactly at max_prompt_size" do
      {:ok, pid} = start_fake_session(max_prompt_size: 5)
      Session.subscribe(pid)
      assert :ok = Session.send_prompt(pid, "abcde")
      TestHelpers.stop_session(pid)
    end
  end

  describe "subscribe + message flow" do
    test "subscriber receives init, assistant, and result messages" do
      {:ok, pid} = start_fake_session()
      Session.subscribe(pid)

      assert :ok = Session.send_prompt(pid, "hello")

      assert_receive {:crowd_control, ^pid, {:system_init, %{"session_id" => _}}}, 3_000
      assert_receive {:crowd_control, ^pid, {:assistant, _}}, 3_000
      assert_receive {:crowd_control, ^pid, {:result, "success", _}}, 3_000

      TestHelpers.stop_session(pid)
    end

    test "get_session_id returns the id from system/init" do
      {:ok, pid} = start_fake_session(env: %{"FAKE_CLI_SESSION_ID" => "custom-sid"})
      Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:system_init, _}}, 3_000
      assert Session.get_session_id(pid) == "custom-sid"
      TestHelpers.stop_session(pid)
    end

    test "get_messages returns accumulated messages in chronological order" do
      {:ok, pid} = start_fake_session()
      Session.subscribe(pid)
      :ok = Session.send_prompt(pid, "x")
      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 3_000

      messages = Session.get_messages(pid)
      assert [{:system_init, _} | _] = messages
      assert match?({:result, _, _}, List.last(messages))
      TestHelpers.stop_session(pid)
    end
  end

  describe "timeout handling" do
    test "broadcasts {:timeout, :session_expired} when session times out" do
      {:ok, pid} = start_fake_session(timeout: 100, env: %{"FAKE_CLI_SLEEP" => "5"})
      Session.subscribe(pid)
      Process.flag(:trap_exit, true)
      :ok = Session.send_prompt(pid, "slow")

      assert_receive {:crowd_control, ^pid, {:timeout, :session_expired}}, 2_000
    end
  end

  describe "non-JSON output" do
    test "session survives malformed JSON lines from subprocess" do
      {:ok, pid} = start_fake_session(env: %{"FAKE_CLI_GARBAGE" => "1"})
      Session.subscribe(pid)
      :ok = Session.send_prompt(pid, "hi")

      assert_receive {:crowd_control, ^pid, {:system_init, _}}, 3_000
      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 3_000
      assert Process.alive?(pid)
      TestHelpers.stop_session(pid)
    end
  end

  describe "env file cleanup" do
    @tag backend: :local
    test "removes its own env dir after session stops" do
      {:ok, pid} =
        start_fake_session(env: %{"FAKE_CLI_ECHO_ENV" => "MY_TEST_KEY", "MY_TEST_KEY" => "ok"})

      Session.subscribe(pid)

      # Pin THIS session's own env dir from its state instead of diffing the
      # shared tmp dir (which races with concurrent async tests).
      our_dir = :sys.get_state(pid).backend_state.env_dir
      assert is_binary(our_dir) and File.dir?(our_dir)

      :ok = Session.send_prompt(pid, "hi")
      assert_receive {:crowd_control, ^pid, {:result, _, %{"result" => "MY_TEST_KEY=ok"}}}, 3_000

      # Cleanup runs in terminate/2; wait for the process to actually go DOWN so
      # terminate has completed before asserting the dir is gone.
      ref = Process.monitor(pid)
      TestHelpers.stop_session(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      refute File.dir?(our_dir), "expected our env dir to be removed: #{our_dir}"
    end
  end

  describe "max_line_bytes guard" do
    @tag backend: :local
    test "oversized newline-free output kills the session and cleans its env dir" do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          env: %{"FOO" => "bar"},
          max_line_bytes: 32,
          timeout: 10_000
        )

      Session.subscribe(pid)
      our_dir = :sys.get_state(pid).backend_state.env_dir
      assert is_binary(our_dir) and File.dir?(our_dir)

      ref = Process.monitor(pid)

      # Casts directly to exercise the GenServer-level buffer guard (bypasses
      # the real Port -> reader-loop -> cast path). A newline-free chunk larger
      # than max_line_bytes can never complete a line, so the buffered remainder
      # must be capped instead of growing unbounded — the session stops
      # gracefully and broadcasts the error.
      GenServer.cast(pid, {:stdout_data, String.duplicate("x", 64)})

      assert_receive {:crowd_control, ^pid, {:error, :line_too_large}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute File.dir?(our_dir), "expected env dir cleaned on line_too_large: #{our_dir}"
    end
  end

  describe "max_messages retention cap" do
    test "get_messages is bounded at max_messages and retains the newest" do
      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          max_messages: 5,
          timeout: 10_000
        )

      # Wait for the init message so it is accumulated before we feed our own
      # lines; this makes the cap-eviction order deterministic.
      Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:system_init, _}}, 3_000

      for i <- 1..20 do
        line =
          JSON.encode!(%{
            "type" => "assistant",
            "message" => %{"role" => "assistant", "content" => []},
            "n" => i
          })

        GenServer.cast(pid, {:stdout_data, line <> "\n"})
      end

      # Eviction math: 1 init + 20 assistant = 21 accumulated, cap 5 -> the init
      # and a1..a15 are evicted, leaving a16..a20. get_messages/1 returns
      # chronological order, so the window is exactly [a16, .., a20].
      messages = Session.get_messages(pid)
      assert length(messages) == 5
      assert Enum.all?(messages, &match?({:assistant, _}, &1))
      assert {:assistant, %{"n" => 16}} = List.first(messages)
      assert {:assistant, %{"n" => 20}} = List.last(messages)

      TestHelpers.stop_session(pid)
    end
  end

  describe "reattach mode" do
    alias CrowdControl.Backend.Mock
    alias CrowdControl.Store

    test "seeds the cursor before the reader delivers, so a split line rejoins exactly" do
      # The session died holding the partial line `{"n"`; the sandbox kept
      # running and its output continues `:2}\n`. Reattaching must rejoin them
      # into one valid message, with no duplicated or lost bytes.
      ctl =
        start_supervised!(
          {Mock, events: [{:stdout_data, ~s|:2}\n|}, {:stdout_data, ~s|{"n":3}\n|}]}
        )

      record =
        Store.build(
          key: "resume-key",
          session_id: "cli-abc",
          backend: Mock,
          handle: Mock.handle(ctl, "resume-key"),
          byte_offset: 12,
          buffer: ~s|{"n"|,
          opts: [timeout: 5_000]
        )

      {:ok, pid} = Session.start_reattached(record)
      Session.subscribe(pid)

      state = :sys.get_state(pid)
      assert state.session_id == "cli-abc"
      assert state.status == :running
      assert state.subscribers == [self()]

      TestHelpers.wait_until(fn -> :sys.get_state(pid).byte_offset > 12 end)

      after_state = :sys.get_state(pid)

      # 12 seeded + 4 (`:2}\n`) + 8 (`{"n":3}\n`) = 24
      assert after_state.byte_offset == 24
      assert after_state.buffer == ""

      # The reattach was asked for exactly the persisted cursor.
      assert Mock.reattach_cursor(ctl) == %{byte_offset: 12, buffer: ~s|{"n"|}

      TestHelpers.stop_session(pid)
    end

    test "restores opts-derived settings from the record" do
      ctl = start_supervised!({Mock, events: []})

      record =
        Store.build(
          key: "opts-key",
          session_id: nil,
          backend: Mock,
          handle: Mock.handle(ctl, "opts-key"),
          byte_offset: 0,
          buffer: "",
          opts: [timeout: 9_999, max_messages: 7, max_line_bytes: 512, max_prompt_size: 64]
        )

      {:ok, pid} = Session.start_reattached(record)
      state = :sys.get_state(pid)

      assert state.timeout == 9_999
      assert state.max_messages == 7
      assert state.max_line_bytes == 512
      assert state.max_prompt_size == 64
      assert state.store_key == "opts-key"

      TestHelpers.stop_session(pid)
    end

    test "stops when the backend cannot reattach" do
      Process.flag(:trap_exit, true)
      ctl = start_supervised!({Mock, events: [], fail: %{reattach: :container_gone}})

      record =
        Store.build(
          key: "gone-key",
          session_id: nil,
          backend: Mock,
          handle: Mock.handle(ctl, "gone-key"),
          byte_offset: 0,
          buffer: "",
          opts: []
        )

      assert {:error, :container_gone} = Session.start_reattached(record)
    end
  end

  # End-to-end against a scripted `omp --mode rpc` stand-in: proves the adapter
  # boundary, not the model. The session must surface an omp session id, a
  # Claude-shaped result, and survive past the first turn.
  describe "omp agent" do
    test "handshake yields a session id and a turn yields a result" do
      {:ok, pid} =
        Session.start_link(
          agent: :omp,
          executable: TestHelpers.fake_omp_path(),
          env: %{"FAKE_OMP_SESSION_ID" => "omp-fixed-id"},
          timeout: 10_000,
          prompt: "hi"
        )

      Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:system_init, init}}, 5_000
      assert init["session_id"] == "omp-fixed-id"
      assert init["tools"] == ["read", "write"]

      assert_receive {:crowd_control, ^pid, {:assistant, _}}, 5_000
      assert_receive {:crowd_control, ^pid, {:result, "success", result}}, 5_000
      assert result["result"] == "done:hi"
      assert result["total_cost_usd"] == 0.75

      assert Session.get_session_id(pid) == "omp-fixed-id"

      TestHelpers.stop_session(pid)
    end

    test "a second prompt is accepted after the first turn completes" do
      {:ok, pid} =
        Session.start_link(
          agent: :omp,
          executable: TestHelpers.fake_omp_path(),
          timeout: 10_000,
          prompt: "one"
        )

      Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:result, "success", %{"result" => "done:one"}}},
                     5_000

      # The turn is over but `omp --mode rpc` is still reading stdin, so the
      # session must not have latched itself shut.
      assert :ok = Session.send_prompt(pid, "two")

      assert_receive {:crowd_control, ^pid, {:result, "success", %{"result" => "done:two"}}},
                     5_000

      TestHelpers.stop_session(pid)
    end

    test "a rejected prompt surfaces as an error result instead of hanging" do
      {:ok, pid} =
        Session.start_link(
          agent: :omp,
          executable: TestHelpers.fake_omp_path(),
          env: %{"FAKE_OMP_PROMPT_FAIL" => "1"},
          timeout: 10_000,
          prompt: "hi"
        )

      Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:result, "error_prompt_failed", result}}, 5_000
      assert result["is_error"] == true
      assert result["error_code"] == "session_busy"

      TestHelpers.stop_session(pid)
    end
  end

  defp start_fake_session(extra_opts \\ []) do
    opts =
      Keyword.merge(
        [executable: TestHelpers.fake_cli_path(), timeout: 10_000],
        extra_opts
      )

    Session.start_link(opts)
  end
end
