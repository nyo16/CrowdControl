defmodule CrowdControl.ApplicationTest do
  use ExUnit.Case, async: true

  alias CrowdControl.{Session, TestHelpers}

  test "session supervisor is registered and alive at startup" do
    pid = Process.whereis(CrowdControl.SessionSupervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "healthy?/0 returns true when supervisor is up" do
    assert CrowdControl.healthy?() == true
  end

  test "DynamicSupervisor honors max_children" do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 2)

    {:ok, p1} =
      DynamicSupervisor.start_child(
        sup,
        {Session, executable: TestHelpers.fake_cli_path(), timeout: 5_000}
      )

    {:ok, p2} =
      DynamicSupervisor.start_child(
        sup,
        {Session, executable: TestHelpers.fake_cli_path(), timeout: 5_000}
      )

    assert {:error, :max_children} =
             DynamicSupervisor.start_child(
               sup,
               {Session, executable: TestHelpers.fake_cli_path(), timeout: 5_000}
             )

    TestHelpers.stop_session(p1)
    TestHelpers.stop_session(p2)
    DynamicSupervisor.stop(sup)
  end
end
