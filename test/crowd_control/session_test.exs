defmodule CrowdControl.SessionTest do
  use ExUnit.Case, async: true

  alias CrowdControl.Agent.Omp
  alias CrowdControl.Backend.Local
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

    test "rejects a prompt once the subprocess has exited" do
      # The `:completed when not state.exited` gate is what makes multi-turn
      # possible; `exited` is the half that keeps it honest. Without it the
      # session happily writes prompts into a dead process forever.
      Process.flag(:trap_exit, true)
      {:ok, pid} = start_fake_session()
      Session.subscribe(pid)

      # fake_cli.sh exits after one prompt cycle, like `claude --print`.
      :ok = Session.send_prompt(pid, "hi")
      assert_receive {:crowd_control, ^pid, {:exit, _}}, 5_000

      assert {:error, :completed} = Session.send_prompt(pid, "again")

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

    test "a steadily streaming turn still expires -- the timer is not refreshed by output" do
      # :timeout is a per-turn deadline, not an idle timer: schedule_timeout/1
      # runs on init and send_prompt/2 and nowhere else. This pins the
      # documented semantics, because "inactivity ceiling" reads like output
      # would keep the session alive -- it does not, and a long autonomous turn
      # against a slow model is exactly where that bites.
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        start_fake_session(
          timeout: 300,
          # 100 assistant messages, 50ms apart: ~5s of uninterrupted output,
          # far longer than the 300ms deadline, and never a result.
          env: %{"FAKE_CLI_STREAM_NORESULT" => "100"}
        )

      Session.subscribe(pid)
      :ok = Session.send_prompt(pid, "stream")

      assert_receive {:crowd_control, ^pid, {:assistant, _}}, 2_000
      assert_receive {:crowd_control, ^pid, {:timeout, :session_expired}}, 3_000
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

  describe "agent handshake" do
    alias CrowdControl.Backend.Mock

    test "a failed handshake write stops the session instead of hanging it" do
      # For omp the handshake IS the get_state that produces the session id.
      # Swallowing the write error left the session sitting in :starting until
      # its inactivity timeout, with no id and no way to know why.
      Process.flag(:trap_exit, true)
      ctl = start_supervised!({Mock, events: [], fail: %{write: :pipe_closed}})

      assert {:error, {:handshake_failed, :pipe_closed}} =
               Session.start_link(
                 backend: {Mock, mock: ctl},
                 agent: :omp,
                 executable: "omp",
                 timeout: 5_000
               )
    end

    test "a Claude session has no handshake to fail" do
      # ClaudeCode.init_frames/1 returns [], so a broken pipe cannot be
      # misreported as a handshake failure before the CLI has said anything.
      ctl = start_supervised!({Mock, events: [], fail: %{write: :pipe_closed}})

      assert {:ok, pid} =
               Session.start_link(
                 backend: {Mock, mock: ctl},
                 executable: "claude",
                 timeout: 5_000
               )

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
      #
      # The gap between the two chunks is deliberate. It forces them into
      # separate casts, so a wait that stops at "some output arrived" sees
      # byte_offset 16 and fails the 24 below. That is exactly how this test
      # failed on one CI leg while every faster machine got lucky.
      ctl =
        start_supervised!(
          {Mock,
           events: [
             {:stdout_data, ~s|:2}\n|},
             {:sleep, 25},
             {:stdout_data, ~s|{"n":3}\n|}
           ]}
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

      # The rejoin is what this test is named for, so assert it: the seeded
      # `{"n"` and the sandbox's `:2}\n` arrive as one valid message.
      assert_receive {:crowd_control, ^pid, {:unknown, %{"n" => 2}}}, 2_000
      assert_receive {:crowd_control, ^pid, {:unknown, %{"n" => 3}}}, 2_000

      # Both chunks are accounted for now: byte_offset is updated in the same
      # handle_cast that broadcasts, and this call is queued behind it.
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

      assert_receive {:crowd_control, ^pid, {:result, "success", result}}, 5_000
      assert result["result"] == "done:hi"
      assert result["total_cost_usd"] == 0.75

      # Ordering is asserted from the accumulated history, not from
      # assert_receive: assert_receive is a *selective* receive, so it matches
      # a system_init that arrived after the result just as happily. The whole
      # point of write_init_frames/1 is that the handshake precedes the prompt.
      messages = Session.get_messages(pid)
      init_at = Enum.find_index(messages, &match?({:system_init, _}, &1))
      turn_at = Enum.find_index(messages, &match?({:assistant, _}, &1))
      result_at = Enum.find_index(messages, &match?({:result, _, _}, &1))

      assert init_at < turn_at and turn_at < result_at,
             "expected handshake before the turn, got #{inspect(Enum.map(messages, &elem(&1, 0)))}"

      assert {:system_init, init} = Enum.at(messages, init_at)
      assert init["session_id"] == "omp-fixed-id"
      assert init["tools"] == ["read", "write"]

      assert Session.get_session_id(pid) == "omp-fixed-id"

      TestHelpers.stop_session(pid)
    end

    test "a type-drifted get_state payload does not kill the session" do
      # decode_line/1 runs inside handle_cast/2. A frame whose "model" is a
      # string and whose "dumpTools" is a string -- the shape a future omp
      # schema change would produce -- used to raise FunctionClauseError and
      # take the whole session down with it.
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Session.start_link(
          agent: :omp,
          executable: TestHelpers.fake_omp_path(),
          env: %{"FAKE_OMP_BAD_STATE" => "1"},
          timeout: 10_000,
          prompt: "hi"
        )

      Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:result, "success", %{"result" => "done:hi"}}}, 5_000
      refute_received {:EXIT, ^pid, _}
      assert Process.alive?(pid)
      # The unusable session id is clamped, not propagated as a map.
      assert Session.get_session_id(pid) == nil

      TestHelpers.stop_session(pid)
    end

    test "a local-only prompt completes instead of hanging until the deadline" do
      # A slash command omp answers itself emits no agent_end; its only
      # completion signal is agentInvoked: false.
      {:ok, pid} =
        Session.start_link(
          agent: :omp,
          executable: TestHelpers.fake_omp_path(),
          env: %{"FAKE_OMP_LOCAL_ONLY" => "1"},
          timeout: 10_000,
          prompt: "/tools"
        )

      Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:result, "success", result}}, 5_000
      assert result["local_only"] == true

      TestHelpers.stop_session(pid)
    end

    test "a non-terminal agent_end does not end the turn early" do
      {:ok, pid} =
        Session.start_link(
          agent: :omp,
          executable: TestHelpers.fake_omp_path(),
          env: %{"FAKE_OMP_NONTERMINAL" => "1"},
          timeout: 10_000,
          prompt: "hi"
        )

      Session.subscribe(pid)

      # The isTerminal:false frame is broadcast as a stream event; only the
      # terminal one that follows completes the turn.
      assert_receive {:crowd_control, ^pid, {:result, "success", %{"result" => "done:hi"}}}, 5_000

      assert Enum.count(Session.get_messages(pid), &match?({:result, _, _}, &1)) == 1

      TestHelpers.stop_session(pid)
    end

    test "an option set inside a backend config tuple reaches the framing callbacks" do
      # build_command/1 has always seen the backend-merged opts; encode_prompt/3
      # saw the raw ones, so :streaming_behavior written here was silently inert.
      {:ok, pid} =
        Session.start_link(
          backend: {Local, streaming_behavior: "steer"},
          agent: :omp,
          executable: TestHelpers.fake_omp_path(),
          timeout: 10_000
        )

      assert :sys.get_state(pid).agent_opts[:streaming_behavior] == "steer"

      assert %{"streamingBehavior" => "steer"} =
               JSON.decode!(Omp.encode_prompt("x", 0, :sys.get_state(pid).agent_opts))

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

    test "each result is stamped with the turn it belongs to" do
      {:ok, pid} =
        Session.start_link(
          agent: :omp,
          executable: TestHelpers.fake_omp_path(),
          timeout: 10_000,
          prompt: "one"
        )

      Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 1}}}, 5_000
      assert Session.current_turn(pid) == 1

      :ok = Session.send_prompt(pid, "two")
      assert Session.current_turn(pid) == 2
      assert_receive {:crowd_control, ^pid, {:result, _, %{"turn" => 2}}}, 5_000

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
