defmodule CrowdControl.Backend.LocalTest do
  use ExUnit.Case, async: true

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Local
  alias CrowdControl.TestHelpers

  # Backend.Local.destroy/1 merges two things Session used to do separately:
  # cleanup_env_dir/1 (which ran in handle_cast(:eof, _)) and the reap/kill
  # escalation (which ran in terminate/2). Calling the merged function at both
  # sites is only safe if it is genuinely idempotent -- that equivalence is what
  # these tests pin down.
  describe "destroy/1 idempotency" do
    test "is safe to call twice and does not re-run the kill escalation" do
      handle = exec_fake_cli(env: %{"FOO" => "bar"})
      env_dir = handle.env_dir
      assert File.dir?(env_dir)

      # fake_cli runs exactly one prompt cycle then exits, so driving a prompt
      # is what makes the subprocess finish on its own. That puts the first
      # destroy/1 on the already-exited path rather than the kill path.
      Local.write(handle, ~s({"type":"user","message":{"role":"user","content":"hi"}}\n))
      assert {:ok, _status} = Local.await_exit(handle, 5_000)

      assert :ok = Local.destroy(handle)
      refute File.dir?(env_dir), "first destroy/1 must remove the env dir"

      # A second destroy/1 must not block on the kill escalation. That path
      # costs up to @kill_wait_timeout (1s) twice; the reap probe short-circuits
      # for an exited process, so this has to come back promptly.
      {elapsed_us, :ok} = :timer.tc(fn -> Local.destroy(handle) end)

      assert elapsed_us < 500_000,
             "second destroy/1 took #{div(elapsed_us, 1000)}ms — it re-ran the kill escalation"

      refute File.dir?(env_dir)
    end

    test "destroy/1 on a live subprocess escalates, and a repeat is still cheap" do
      handle = exec_fake_cli(env: %{"FAKE_CLI_SLEEP" => "30"})
      env_dir = handle.env_dir

      assert Local.alive?(handle)
      assert :ok = Local.destroy(handle)
      refute File.dir?(env_dir)

      TestHelpers.wait_until(fn -> not Local.alive?(handle) end)

      {elapsed_us, :ok} = :timer.tc(fn -> Local.destroy(handle) end)

      assert elapsed_us < 500_000,
             "repeat destroy/1 after a kill took #{div(elapsed_us, 1000)}ms"
    end

    test "destroy/1 on a provisioned-but-never-exec'd handle is a no-op" do
      {:ok, handle} = Local.provision([])
      assert handle.proc == nil
      assert handle.env_dir == nil

      assert :ok = Local.destroy(handle)
      assert :ok = Local.destroy(handle)
    end
  end

  describe "env file mechanism" do
    test "no env means no env dir and no shell wrapper" do
      handle = exec_fake_cli([])

      assert handle.env_dir == nil
      assert handle.env_file == nil

      Local.destroy(handle)
    end

    test "env dir is 0700 and env file is 0600" do
      handle = exec_fake_cli(env: %{"SECRET" => "hunter2"})

      assert {:ok, %File.Stat{mode: dir_mode}} = File.stat(handle.env_dir)
      assert Bitwise.band(dir_mode, 0o777) == 0o700

      # The wrapper rm's the env file after sourcing it, so it may already be
      # gone; if it is still there it must not be group/world readable.
      case File.stat(handle.env_file) do
        {:ok, %File.Stat{mode: file_mode}} -> assert Bitwise.band(file_mode, 0o077) == 0
        {:error, :enoent} -> :ok
      end

      Local.destroy(handle)
    end
  end

  describe "reattach contract" do
    test "reports itself as non-reattachable" do
      refute Local.reattachable?()
      refute Backend.reattachable?(Local)
    end

    test "list_live/1 is always empty — a dead local subprocess is not recoverable" do
      assert {:ok, []} = Local.list_live([])
      assert {:ok, []} = Local.list_live(owner: "anything")
    end

    test "reattach/2 is unsupported" do
      {:ok, handle} = Local.provision([])
      assert {:error, :not_supported} = Local.reattach(handle, Backend.new_cursor())
    end
  end

  describe "reader contract" do
    test "start_reader/3 links to the caller and casts stdout then :eof" do
      handle = exec_fake_cli([])

      # Stand in for the Session: start_reader/3 casts to whatever pid it is
      # given, so a plain GenServer-less receive loop cannot be used -- collect
      # via a relay process that forwards casts back to the test.
      test_pid = self()
      relay = spawn_link(fn -> relay_loop(test_pid) end)

      assert {:ok, reader} = Local.start_reader(handle, relay, Backend.new_cursor())
      assert is_pid(reader)

      Local.write(handle, ~s({"type":"user","message":{"role":"user","content":"hi"}}\n))

      assert_receive {:cast, {:stdout_data, data}}, 5_000
      assert is_binary(data)

      assert_receive {:cast, :eof}, 5_000

      Local.destroy(handle)
    end
  end

  defp exec_fake_cli(opts) do
    {:ok, handle} = Local.provision(opts)
    env = CrowdControl.CLI.build_env(opts)
    {:ok, handle} = Local.exec(handle, TestHelpers.fake_cli_path(), [], env)
    handle
  end

  # GenServer.cast/2 to a plain pid delivers {:"$gen_cast", msg}.
  defp relay_loop(test_pid) do
    receive do
      {:"$gen_cast", msg} ->
        send(test_pid, {:cast, msg})
        relay_loop(test_pid)
    end
  end
end
