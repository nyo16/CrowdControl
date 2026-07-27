defmodule CrowdControl.StoreTest do
  # async: false — both stores are process-named singletons backed by a
  # globally-named table, and the DETS cases stop and restart that process.
  use ExUnit.Case, async: false

  alias CrowdControl.{Session, Store, TestHelpers}
  alias CrowdControl.Store.{DETS, ETS}

  # Overrides go first: Keyword.get/3 takes the leftmost match, so appending
  # them would let the defaults silently win.
  defp record(key, overrides \\ []) do
    Store.build(
      overrides ++
        [
          key: key,
          session_id: "cli-#{key}",
          backend: CrowdControl.Backend.Mock,
          handle: %{container: "c-#{key}"},
          byte_offset: 0,
          buffer: "",
          opts: [image: "alpine"]
        ]
    )
  end

  # One suite, both implementations. A store that passes here is substitutable;
  # that substitutability is the entire point of the behaviour.
  for store <- [ETS, DETS] do
    describe "#{inspect(store)}" do
      @store store

      setup do
        if @store == DETS do
          path =
            Path.join(
              System.tmp_dir!(),
              "cc_store_test_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}.dets"
            )

          start_supervised!({DETS, path: path})
          on_exit(fn -> File.rm(path) end)
          {:ok, path: path}
        else
          :ok
        end
      end

      setup do
        keys = Enum.map(@store.all(), & &1.key)
        on_exit(fn -> Enum.each(keys, &@store.delete/1) end)
        :ok
      end

      test "put/1 then get/1 round-trips the record" do
        rec = record("a1")
        assert :ok = @store.put("a1", rec)
        assert {:ok, ^rec} = @store.get("a1")
      end

      test "get/1 returns :error for an unknown key" do
        assert :error = @store.get("does-not-exist")
      end

      test "put/1 replaces an existing record" do
        assert :ok = @store.put("a2", record("a2", byte_offset: 10))
        assert :ok = @store.put("a2", record("a2", byte_offset: 99))

        assert {:ok, %{byte_offset: 99}} = @store.get("a2")
        assert Enum.count(@store.all(), &(&1.key == "a2")) == 1
      end

      test "delete/1 removes the record and is safe on an absent key" do
        assert :ok = @store.put("a3", record("a3"))
        assert :ok = @store.delete("a3")
        assert :error = @store.get("a3")

        assert :ok = @store.delete("a3")
        assert :ok = @store.delete("never-existed")
      end

      test "all/0 returns every record" do
        for k <- ~w(b1 b2 b3), do: @store.put(k, record(k))

        keys = @store.all() |> Enum.map(& &1.key) |> Enum.sort()
        assert ~w(b1 b2 b3) -- keys == []
      end

      test "round-trips a cursor that splits a line mid-token" do
        # The reason the store exists: byte_offset and buffer must come back
        # exactly, or resume duplicates or drops bytes.
        rec = record("cursor", byte_offset: 14, buffer: "GOT:")
        assert :ok = @store.put("cursor", rec)

        assert {:ok, %{byte_offset: 14, buffer: "GOT:"}} = @store.get("cursor")
      end

      test "handle survives a term_to_binary round-trip" do
        # Backends may store arbitrary terms, and DETS serializes them. A handle
        # that cannot round-trip is unreattachable after a node restart.
        rec = record("handle", [])
        assert :ok = @store.put("handle", rec)
        {:ok, got} = @store.get("handle")

        assert got.handle == :erlang.binary_to_term(:erlang.term_to_binary(got.handle))
      end

      test "build/1 stamps owner and updated_at" do
        rec = record("stamp")
        assert rec.owner == Store.owner_id()
        assert is_integer(rec.updated_at)
      end
    end
  end

  describe "Store.DETS durability" do
    test "records survive a close and reopen cycle" do
      path =
        Path.join(
          System.tmp_dir!(),
          "cc_dets_reopen_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}.dets"
        )

      on_exit(fn -> File.rm(path) end)

      pid = start_supervised!({DETS, path: path})
      assert :ok = DETS.put("survivor", record("survivor", byte_offset: 4_096, buffer: "half-"))
      assert {:ok, _} = DETS.get("survivor")

      # Stop the owning process, which closes the table -- the node-restart
      # analogue.
      :ok = stop_supervised(:"Elixir.CrowdControl.Store.DETS")
      refute Process.alive?(pid)

      start_supervised!({DETS, path: path})

      assert {:ok, %{byte_offset: 4_096, buffer: "half-"}} = DETS.get("survivor")
      assert :ok = DETS.delete("survivor")
    end

    test "writes are synced, so the file is non-empty immediately after put/2" do
      path =
        Path.join(
          System.tmp_dir!(),
          "cc_dets_sync_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}.dets"
        )

      on_exit(fn -> File.rm(path) end)

      start_supervised!({DETS, path: path})
      :ok = DETS.put("synced", record("synced"))

      assert {:ok, %File.Stat{size: size}} = File.stat(path)
      assert size > 0
      DETS.delete("synced")
    end
  end

  describe "Backend.Local writes nothing" do
    test "a full local session lifecycle leaves zero records" do
      before = length(Store.all())

      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          timeout: 10_000
        )

      Session.subscribe(pid)
      :ok = Session.send_prompt(pid, "hi")
      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 5_000

      # Local is not reattachable, so Session skips persistence entirely rather
      # than writing a record per stdout chunk.
      assert length(Store.all()) == before

      TestHelpers.stop_session(pid)
    end

    test "Session marks itself non-persisting for Backend.Local" do
      {:ok, pid} =
        Session.start_link(executable: TestHelpers.fake_cli_path(), timeout: 10_000)

      state = :sys.get_state(pid)
      refute state.persist?
      assert is_binary(state.store_key)

      TestHelpers.stop_session(pid)
    end
  end

  describe "resolve/0" do
    test "defaults to Store.ETS" do
      assert {ETS, []} = Store.resolve()
    end

    test "accepts a {module, opts} tuple" do
      Application.put_env(:crowd_control, :store, {DETS, path: "/tmp/x.dets"})
      on_exit(fn -> Application.delete_env(:crowd_control, :store) end)

      assert {DETS, [path: "/tmp/x.dets"]} = Store.resolve()
    end

    test "rejects a non-module" do
      Application.put_env(:crowd_control, :store, "nope")
      on_exit(fn -> Application.delete_env(:crowd_control, :store) end)

      assert_raise ArgumentError, ~r/must be a module/, fn -> Store.resolve() end
    end
  end

  describe "owner_id/0" do
    test "defaults to the node name" do
      assert Store.owner_id() == to_string(node())
    end

    test "is configurable" do
      Application.put_env(:crowd_control, :owner_id, "prod-worker-1")
      on_exit(fn -> Application.delete_env(:crowd_control, :owner_id) end)

      assert Store.owner_id() == "prod-worker-1"
    end

    test "rejects a non-binary" do
      Application.put_env(:crowd_control, :owner_id, :atom_id)
      on_exit(fn -> Application.delete_env(:crowd_control, :owner_id) end)

      assert_raise ArgumentError, ~r/must be a binary/, fn -> Store.owner_id() end
    end
  end

  describe "new_key/0" do
    test "mints distinct hex keys" do
      keys = for _ <- 1..100, do: Store.new_key()

      assert length(Enum.uniq(keys)) == 100
      assert Enum.all?(keys, &(&1 =~ ~r/\A[0-9a-f]{32}\z/))
    end
  end
end
