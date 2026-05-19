defmodule CrowdControl.SessionTest do
  use ExUnit.Case, async: true

  alias CrowdControl.{Session, TestHelpers}

  describe "init/1" do
    test "fails to start with a nonexistent executable" do
      Process.flag(:trap_exit, true)

      result =
        Session.start_link(executable: "/nonexistent/binary/that/does/not/exist", timeout: 1_000)

      case result do
        {:error, _reason} -> :ok
        {:ok, pid} -> assert_receive {:EXIT, ^pid, _}, 2_000
      end
    end

    test "cleans up env dir when subprocess exits with EOF" do
      Process.flag(:trap_exit, true)
      before = MapSet.new(list_cc_env_dirs())

      {:ok, pid} =
        Session.start_link(
          executable: "/nonexistent/binary",
          env: %{"FOO" => "bar"},
          timeout: 5_000
        )

      Session.subscribe(pid)

      # The subprocess fails fast; wait for the :exit broadcast which fires
      # after env-dir cleanup in handle_cast(:eof, ...).
      assert_receive {:crowd_control, ^pid, {:exit, _}}, 2_000

      after_ = MapSet.new(list_cc_env_dirs())
      new_dirs = MapSet.difference(after_, before)

      assert MapSet.size(new_dirs) == 0,
             "expected our env dir cleaned, leftover: #{inspect(MapSet.to_list(new_dirs))}"
    end
  end

  describe "send_prompt validation" do
    test "rejects non-binary prompt" do
      {:ok, pid} = start_fake_session()
      assert {:error, :invalid_prompt} = Session.send_prompt(pid, :not_a_string)
      Session.stop(pid)
    end

    test "rejects prompt with null byte" do
      {:ok, pid} = start_fake_session()
      assert {:error, :invalid_prompt} = Session.send_prompt(pid, "hi\0there")
      Session.stop(pid)
    end

    test "rejects prompt with invalid UTF-8" do
      {:ok, pid} = start_fake_session()
      assert {:error, :invalid_prompt} = Session.send_prompt(pid, <<0xFF, 0xFE>>)
      Session.stop(pid)
    end

    test "rejects prompt exceeding max_prompt_size" do
      {:ok, pid} = start_fake_session(max_prompt_size: 5)
      assert {:error, :prompt_too_large} = Session.send_prompt(pid, "abcdef")
      Session.stop(pid)
    end

    test "accepts prompt exactly at max_prompt_size" do
      {:ok, pid} = start_fake_session(max_prompt_size: 5)
      Session.subscribe(pid)
      assert :ok = Session.send_prompt(pid, "abcde")
      Session.stop(pid)
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

      Session.stop(pid)
    end

    test "get_session_id returns the id from system/init" do
      {:ok, pid} = start_fake_session(env: %{"FAKE_CLI_SESSION_ID" => "custom-sid"})
      Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:system_init, _}}, 3_000
      assert Session.get_session_id(pid) == "custom-sid"
      Session.stop(pid)
    end

    test "get_messages returns accumulated messages in chronological order" do
      {:ok, pid} = start_fake_session()
      Session.subscribe(pid)
      :ok = Session.send_prompt(pid, "x")
      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 3_000

      messages = Session.get_messages(pid)
      assert [{:system_init, _} | _] = messages
      assert match?({:result, _, _}, List.last(messages))
      Session.stop(pid)
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
      Session.stop(pid)
    end
  end

  describe "env file cleanup" do
    test "removes its own env dir after session stops" do
      before = MapSet.new(list_cc_env_dirs())

      {:ok, pid} =
        start_fake_session(env: %{"FAKE_CLI_ECHO_ENV" => "MY_TEST_KEY", "MY_TEST_KEY" => "ok"})

      Session.subscribe(pid)

      # Catch the dir that was created for THIS session while it is still running.
      Process.sleep(50)
      during = MapSet.new(list_cc_env_dirs())
      ours = MapSet.difference(during, before)

      :ok = Session.send_prompt(pid, "hi")
      assert_receive {:crowd_control, ^pid, {:result, _, %{"result" => "MY_TEST_KEY=ok"}}}, 3_000
      Session.stop(pid)
      Process.sleep(100)

      after_ = MapSet.new(list_cc_env_dirs())
      leftover = MapSet.intersection(ours, after_)

      assert MapSet.size(leftover) == 0,
             "expected our env dir to be removed, leftover: #{inspect(MapSet.to_list(leftover))}"
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

  defp list_cc_env_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "cc_env_"))
  end
end
