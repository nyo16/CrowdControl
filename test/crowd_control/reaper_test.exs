defmodule CrowdControl.ReaperTest do
  # async: false — exercises the global store.
  use ExUnit.Case, async: false

  alias CrowdControl.Backend.Mock
  alias CrowdControl.{Reaper, Store, TestHelpers}

  setup do
    # Isolate each test: clear anything a previous one left behind.
    Enum.each(Store.all(), &Store.delete(&1.key))
    on_exit(fn -> Enum.each(Store.all(), &Store.delete(&1.key)) end)

    owner = Store.owner_id()
    {:ok, owner: owner}
  end

  defp handle(ctl, key), do: %Mock{ctl: ctl, id: key, session_key: key}

  defp store_record(key, opts \\ []) do
    record =
      Store.build(
        opts ++
          [
            key: key,
            session_id: "cli-#{key}",
            backend: Mock,
            handle: %Mock{ctl: nil, id: key, session_key: key},
            byte_offset: 0,
            buffer: "",
            opts: []
          ]
      )

    Store.put(key, record)
    record
  end

  # A private supervisor and an UNNAMED reaper per test, so these never collide
  # with the application-started Reaper (which has no backends configured and is
  # therefore inert).
  defp start_sup do
    start_supervised!(%{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]}
    })
  end

  defp start_reaper(opts) do
    start_supervised!(%{
      id: {Reaper, make_ref()},
      # Manual sweeps only; sweep_interval: 0 means no background timer races
      # the assertions.
      start: {
        Reaper,
        :start_link,
        # sweep_on_boot: false — otherwise the boot reconciliation races (and
        # usually wins against) the explicit Reaper.sweep/1 the test asserts on.
        [[name: nil, sweep_interval: 0, sweep_on_boot: false] ++ opts]
      }
    })
  end

  # `extra` goes FIRST: Keyword.get/3 takes the leftmost match, so appending it
  # would let these defaults silently override the caller's overrides.
  defp start_mock_reaper(ctl, extra \\ []) do
    start_reaper(
      extra ++ [backends: [{Mock, mock: ctl}], reattach: true, supervisor: start_sup()]
    )
  end

  describe "reconciliation branches" do
    test "live + stored -> reattaches a session" do
      ctl = start_supervised!({Mock, events: []})
      store_record("k-live-stored")
      Mock.set_live(ctl, [handle(ctl, "k-live-stored")])

      reaper = start_mock_reaper(ctl)
      assert %{reattached: 1, destroyed: 0, pruned: 0, skipped: 0} = Reaper.sweep(reaper)

      assert :reattach in Mock.calls(ctl)
      assert Mock.destroy_count(ctl) == 0
      assert {:ok, _} = Store.get("k-live-stored")
    end

    test "live + not stored -> destroys the orphan" do
      ctl = start_supervised!({Mock, events: []})
      Mock.set_live(ctl, [handle(ctl, "k-orphan")])

      reaper = start_mock_reaper(ctl)

      assert %{reattached: 0, destroyed: 1, pruned: 0, skipped: 0} = Reaper.sweep(reaper)
      assert Mock.destroyed(ctl) == ["k-orphan"]
    end

    test "stored + not live -> prunes the stale record" do
      ctl = start_supervised!({Mock, events: []})
      store_record("k-stale")
      Mock.set_live(ctl, [])

      reaper = start_mock_reaper(ctl)

      assert %{reattached: 0, destroyed: 0, pruned: 1, skipped: 0} = Reaper.sweep(reaper)
      assert :error = Store.get("k-stale")
      assert Mock.destroy_count(ctl) == 0
    end

    test "handles all three branches in one sweep" do
      ctl = start_supervised!({Mock, events: []})

      store_record("k-both")
      store_record("k-only-stored")
      Mock.set_live(ctl, [handle(ctl, "k-both"), handle(ctl, "k-only-live")])

      reaper = start_mock_reaper(ctl)

      assert %{reattached: 1, destroyed: 1, pruned: 1, skipped: 0} = Reaper.sweep(reaper)
      assert Mock.destroyed(ctl) == ["k-only-live"]
      assert :error = Store.get("k-only-stored")
      assert {:ok, _} = Store.get("k-both")
    end
  end

  describe "fail-open on list_live error" do
    test "a list_live error destroys NOTHING and prunes NOTHING" do
      # The single most dangerous bug available in this phase: an errored
      # listing misread as "nothing is live" would destroy every live sandbox
      # and delete every record. It must skip the backend entirely instead.
      ctl = start_supervised!({Mock, events: [], fail: %{list_live: :daemon_unreachable}})

      store_record("k-must-survive-1")
      store_record("k-must-survive-2")

      reaper = start_mock_reaper(ctl)

      assert %{reattached: 0, destroyed: 0, pruned: 0, skipped: 1} = Reaper.sweep(reaper)

      assert Mock.destroy_count(ctl) == 0, "fail-open violated: destroyed a sandbox"
      assert {:ok, _} = Store.get("k-must-survive-1")
      assert {:ok, _} = Store.get("k-must-survive-2")
    end

    test "a backend that raises is skipped, not treated as empty" do
      ctl = start_supervised!({Mock, events: [], fail: %{list_live: :boom}})
      store_record("k-survives-raise")

      reaper = start_mock_reaper(ctl)

      assert %{skipped: 1, destroyed: 0, pruned: 0} = Reaper.sweep(reaper)
      assert {:ok, _} = Store.get("k-survives-raise")
    end
  end

  defmodule StubListBackend do
    @moduledoc false
    # Returns real Docker handles (which DO carry :owner) so the local owner
    # re-check in destroy_orphans/5 can be exercised without a daemon.
    # Defined BEFORE its use: a nested defmodule only creates its implicit alias
    # from the definition point onward, and referencing it earlier resolves to a
    # missing top-level module — which the reaper's fail-open path would swallow,
    # making the test pass without ever running.
    @behaviour CrowdControl.Backend

    def reattachable?, do: true
    def provision(_), do: {:ok, %{}}
    def exec(h, _, _, _), do: {:ok, h}
    def start_reader(_, _, _), do: {:ok, spawn(fn -> :ok end)}
    def write(_, _), do: :ok
    def await_exit(_, _), do: {:ok, 0}
    def alive?(_), do: true
    def reattach(h, _), do: {:ok, h}
    def destroy(_), do: raise("destroy/1 must not be called for a foreign-owned handle")
    def list_live(opts), do: {:ok, Keyword.get(opts, :live, [])}
  end

  describe "owner alignment between label, record, and filter" do
    alias CrowdControl.Session

    test "a record written by a real Session carries the backend's owner, not the node name" do
      # THE regression test for the reaper-destroys-live-sandboxes blocker.
      #
      # The original tests built store records by hand and set :owner explicitly,
      # so they never exercised the path that was broken: Session.persist/1 did
      # not pass an owner at all, so records always carried Store.owner_id()
      # while the sandbox label carried backend config's :owner. The reaper then
      # found zero matching records for every live sandbox and destroyed them all.
      custom = "worker-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
      refute custom == Store.owner_id()

      ctl = start_supervised!({Mock, events: [{:stdout_data, ~s({"type":"x"}\n)}]})

      {:ok, pid} =
        Session.start_link(
          backend: {Mock, mock: ctl, owner: custom},
          timeout: 10_000
        )

      state = :sys.get_state(pid)
      assert state.persist?, "Mock is reattachable, so the session must persist"
      assert state.owner == custom

      TestHelpers.wait_until(fn -> match?({:ok, _}, Store.get(state.store_key)) end)
      {:ok, record} = Store.get(state.store_key)

      assert record.owner == custom,
             "record owner #{inspect(record.owner)} does not match the sandbox label owner " <>
               "#{inspect(custom)} — the reaper would classify this live session as an orphan"

      TestHelpers.stop_session(pid)
    end

    test "a live session under a custom owner is reattached, never destroyed" do
      # End-to-end proof of the same bug: drive a real Session, then sweep with a
      # reaper configured for the same custom owner and assert the sandbox
      # survives.
      custom = "worker-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
      ctl = start_supervised!({Mock, events: [{:stdout_data, ~s({"type":"x"}\n)}]})

      {:ok, pid} = Session.start_link(backend: {Mock, mock: ctl, owner: custom}, timeout: 10_000)
      key = :sys.get_state(pid).store_key
      TestHelpers.wait_until(fn -> match?({:ok, _}, Store.get(key)) end)

      # The sandbox is live and labelled with the custom owner.
      Mock.set_live(ctl, [handle(ctl, key)])

      reaper =
        start_reaper(
          backends: [{Mock, mock: ctl, owner: custom}],
          reattach: false,
          reap_grace_ms: 0,
          supervisor: start_sup()
        )

      assert %{destroyed: 0, pruned: 0} = Reaper.sweep(reaper)

      assert Mock.destroy_count(ctl) == 0,
             "the reaper destroyed a live session's sandbox"

      assert {:ok, _} = Store.get(key)

      TestHelpers.stop_session(pid)
    end

    test "destroy_orphans refuses a handle whose owner does not match" do
      # Defense in depth: list_live/1 filters daemon-side, but destruction is
      # irreversible, so the last gate re-checks locally.
      ctl = start_supervised!({Mock, events: []})

      foreign = %CrowdControl.Backend.Docker{
        container_id: "c-foreign",
        session_key: "k-foreign",
        owner: "someone-else"
      }

      reaper =
        start_reaper(
          backends: [{StubListBackend, live: [foreign]}],
          reap_grace_ms: 0,
          supervisor: start_sup()
        )

      # skipped: 0 is load-bearing — it proves list_live actually ran and the
      # handle reached the owner check, rather than the backend erroring out and
      # being skipped by the fail-open path.
      assert %{destroyed: 0, skipped: 0} = Reaper.sweep(reaper)
      assert Mock.destroy_count(ctl) == 0
    end
  end

  describe "owner scoping" do
    test "records owned by another node are neither reattached nor pruned" do
      ctl = start_supervised!({Mock, events: []})

      store_record("k-mine")
      store_record("k-theirs", owner: "some-other-node@host")

      Mock.set_live(ctl, [handle(ctl, "k-mine")])

      reaper = start_mock_reaper(ctl)
      assert %{reattached: 1, pruned: 0, destroyed: 0} = Reaper.sweep(reaper)

      # k-theirs is not live from our listing, but it is NOT ours to prune.
      assert {:ok, _} = Store.get("k-theirs"),
             "pruned another owner's record"
    end

    test "a sandbox whose key matches another owner's record is still an orphan to us" do
      ctl = start_supervised!({Mock, events: []})
      store_record("k-foreign", owner: "other-node@host")
      Mock.set_live(ctl, [handle(ctl, "k-foreign")])

      reaper = start_mock_reaper(ctl)

      # We only consider our own records, so from our perspective this live
      # sandbox is unstored — and our list_live only ever returns our own
      # owner's containers, so destroying it is correct.
      assert %{destroyed: 1} = Reaper.sweep(reaper)
    end
  end

  describe "grace period" do
    defmodule YoungBackend do
      @moduledoc false
      @behaviour CrowdControl.Backend

      defstruct [:session_key, :age]

      def reattachable?, do: true
      def provision(_), do: {:ok, %__MODULE__{}}
      def exec(h, _, _, _), do: {:ok, h}
      def start_reader(_, _, _), do: {:ok, spawn(fn -> :ok end)}
      def write(_, _), do: :ok
      def await_exit(_, _), do: {:ok, 0}
      def alive?(_), do: true
      def reattach(h, _), do: {:ok, h}

      def destroy(%__MODULE__{session_key: key}) do
        send(:reaper_grace_test, {:destroyed, key})
        :ok
      end

      def list_live(opts), do: {:ok, Keyword.get(opts, :live, [])}

      # Age comes straight off the struct so the test controls it exactly.
      def age_ms(%__MODULE__{age: age}), do: age
    end

    setup do
      # No on_exit unregister: the name is released automatically when the test
      # process dies, and on_exit runs in a different process by which point
      # unregistering would raise.
      Process.register(self(), :reaper_grace_test)
      :ok
    end

    test "a container younger than the grace window is left alone" do
      young = %YoungBackend{session_key: "k-young", age: 5_000}

      reaper =
        start_reaper(
          backends: [{YoungBackend, live: [young]}],
          reap_grace_ms: 60_000,
          supervisor: start_sup()
        )

      assert %{destroyed: 0} = Reaper.sweep(reaper)
      refute_receive {:destroyed, "k-young"}, 200
    end

    test "a container older than the grace window is reaped" do
      old = %YoungBackend{session_key: "k-old", age: 120_000}

      reaper =
        start_reaper(
          backends: [{YoungBackend, live: [old]}],
          reap_grace_ms: 60_000,
          supervisor: start_sup()
        )

      assert %{destroyed: 1} = Reaper.sweep(reaper)
      assert_receive {:destroyed, "k-old"}, 500
    end

    test "an unknown age is treated as young — fail-open" do
      unknown = %YoungBackend{session_key: "k-unknown", age: nil}

      reaper =
        start_reaper(
          backends: [{YoungBackend, live: [unknown]}],
          reap_grace_ms: 60_000,
          supervisor: start_sup()
        )

      assert %{destroyed: 0} = Reaper.sweep(reaper)
    end
  end

  describe "end-to-end against Docker" do
    @describetag :docker

    alias CrowdControl.Backend.Docker

    @image "alpine:latest"

    test "destroys a container whose session died without running terminate/2" do
      # The cost leak this whole component exists to prevent. A SIGKILLed node
      # never runs terminate/2, and with the default ETS store its records die
      # with the VM — so on restart the containers are alive and unrecorded.
      # That is exactly the state constructed here.
      owner = "cc-reap-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
      opts = [image: @image, owner: owner, session_key: "orphan-key"]

      {:ok, handle} = Docker.provision(opts)
      on_exit(fn -> Docker.destroy(handle) end)

      assert Docker.alive?(handle)
      assert {:ok, [_]} = Docker.list_live(owner: owner)

      reaper =
        start_reaper(
          backends: [{Docker, image: @image, owner: owner}],
          # The container was just created, so without this the grace window
          # would (correctly) protect it.
          reap_grace_ms: 0,
          supervisor: start_sup()
        )

      assert %{destroyed: 1, skipped: 0} = Reaper.sweep(reaper)

      assert eventually(fn ->
               match?({:ok, []}, Docker.list_live(owner: owner))
             end),
             "reaper did not actually destroy the orphaned container"

      refute Docker.alive?(handle)
    end

    test "leaves a container inside the grace window alone" do
      owner = "cc-grace-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

      {:ok, handle} = Docker.provision(image: @image, owner: owner, session_key: "young-key")
      on_exit(fn -> Docker.destroy(handle) end)

      reaper =
        start_reaper(
          backends: [{Docker, image: @image, owner: owner}],
          reap_grace_ms: 120_000,
          supervisor: start_sup()
        )

      assert %{destroyed: 0} = Reaper.sweep(reaper)
      assert Docker.alive?(handle), "reaped a container mid-provision"
    end

    test "never touches another owner's containers" do
      mine = "cc-mine-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
      theirs = "cc-theirs-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

      {:ok, my_handle} = Docker.provision(image: @image, owner: mine, session_key: "k1")
      {:ok, their_handle} = Docker.provision(image: @image, owner: theirs, session_key: "k2")

      on_exit(fn ->
        Docker.destroy(my_handle)
        Docker.destroy(their_handle)
      end)

      reaper =
        start_reaper(
          backends: [{Docker, image: @image, owner: mine}],
          reap_grace_ms: 0,
          supervisor: start_sup()
        )

      assert %{destroyed: 1} = Reaper.sweep(reaper)

      assert eventually(fn -> match?({:ok, []}, Docker.list_live(owner: mine)) end)

      # The other node's container must be untouched.
      assert Docker.alive?(their_handle), "reaped another owner's container"
      assert {:ok, [_]} = Docker.list_live(owner: theirs)
    end

    test "an unreachable daemon destroys nothing" do
      owner = "cc-failopen-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

      {:ok, handle} = Docker.provision(image: @image, owner: owner, session_key: "safe-key")
      on_exit(fn -> Docker.destroy(handle) end)

      reaper =
        start_reaper(
          backends: [
            {Docker, image: @image, owner: owner, docker_host: "unix:///nonexistent/docker.sock"}
          ],
          reap_grace_ms: 0,
          supervisor: start_sup()
        )

      assert %{skipped: 1, destroyed: 0, pruned: 0} = Reaper.sweep(reaper)
      assert Docker.alive?(handle), "fail-open violated against a real daemon outage"
    end

    defp eventually(fun, timeout \\ 10_000) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_eventually(fun, deadline)
    end

    defp do_eventually(fun, deadline) do
      cond do
        fun.() ->
          true

        System.monotonic_time(:millisecond) >= deadline ->
          false

        true ->
          Process.sleep(100)
          do_eventually(fun, deadline)
      end
    end
  end

  describe "configuration" do
    test "with no backends configured it starts and does nothing" do
      reaper = start_reaper(backends: [], supervisor: start_sup())

      assert %{reattached: 0, destroyed: 0, pruned: 0, skipped: 0} = Reaper.sweep(reaper)
    end

    test "reattach: false skips reattaching but still reaps and prunes" do
      ctl = start_supervised!({Mock, events: []})
      store_record("k-no-reattach")
      Mock.set_live(ctl, [handle(ctl, "k-no-reattach"), handle(ctl, "k-orphan2")])

      reaper = start_mock_reaper(ctl, reattach: false)

      assert %{reattached: 0, destroyed: 1} = Reaper.sweep(reaper)
      assert Mock.destroyed(ctl) == ["k-orphan2"]
    end
  end
end
