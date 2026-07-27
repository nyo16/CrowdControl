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

  test "a transient session that exits normally frees its max_children slot" do
    # Session moved from restart: :temporary to :transient so a crashed session
    # can be restarted and its surviving remote sandbox reattached. The risk
    # that introduces is a transient child respawning forever and permanently
    # occupying a slot. Normal exits must NOT be restarted.
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 1)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        sup,
        {Session, executable: TestHelpers.fake_cli_path(), timeout: 5_000}
      )

    ref = Process.monitor(pid)
    :ok = Session.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

    # The slot must be free again: a :normal exit is not restarted.
    assert %{active: 0} = DynamicSupervisor.count_children(sup)

    assert {:ok, pid2} =
             DynamicSupervisor.start_child(
               sup,
               {Session, executable: TestHelpers.fake_cli_path(), timeout: 5_000}
             )

    TestHelpers.stop_session(pid2)
    DynamicSupervisor.stop(sup)
  end

  test "Session declares restart: :transient" do
    assert %{restart: :transient} = Session.child_spec([])
  end

  test "the reaper is supervised and starts after the store and session supervisor" do
    assert is_pid(Process.whereis(CrowdControl.Reaper))
    assert is_pid(Process.whereis(CrowdControl.Store.ETS))

    children = Supervisor.which_children(CrowdControl.Supervisor)
    order = Enum.map(children, fn {id, _, _, _} -> id end) |> Enum.reverse()

    assert Enum.find_index(order, &(&1 == CrowdControl.Store.ETS)) <
             Enum.find_index(order, &(&1 == CrowdControl.Reaper))
  end
end
