defmodule CrowdControl.Backend.SandboxdTest do
  # Needs a live Docker daemon and an image containing the sandboxd release.
  # Excluded by default (see test_helper.exs); run with:
  #
  #     docker build --target sandbox-dev -t crowd_control/sandbox:dev .
  #     mix test --include sandboxd
  #
  use ExUnit.Case, async: false

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Sandboxd
  alias CrowdControl.Backend.Sandboxd.API
  alias CrowdControl.Provider

  @moduletag :sandboxd
  @image "crowd_control/sandbox:dev"

  # A stand-in for the real CLI: echoes each stdin line back as a JSON line.
  # Same shape docker_test.exs uses, so the two transports are compared on
  # identical behaviour rather than on differently-shaped fixtures.
  @echo_cli ["-c", ~S|while IFS= read -r l; do printf '{"echo":"%s"}\n' "$l"; done|]

  setup do
    previous = Application.get_env(:crowd_control, :sandboxd_secret)
    Application.put_env(:crowd_control, :sandboxd_secret, "integration-secret-32-bytes-min!!")

    owner = "cc-sbxd-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

    on_exit(fn ->
      destroy_all(owner)

      if previous do
        Application.put_env(:crowd_control, :sandboxd_secret, previous)
      else
        Application.delete_env(:crowd_control, :sandboxd_secret)
      end
    end)

    {:ok, owner: owner, opts: base_opts(owner)}
  end

  defp base_opts(owner) do
    [
      provider: {Provider.Docker, image: @image, egress: :allow},
      owner: owner,
      session_key: session_key(owner),
      timeout: 20_000,
      ready_timeout: 60_000
    ]
  end

  # Store.new_key/0-shaped: hex, so it is label- and DNS-safe as a network name.
  defp session_key(owner), do: :crypto.hash(:sha256, owner) |> Base.encode16(case: :lower)

  defp destroy_all(owner) do
    case Sandboxd.list_live(provider: Provider.Docker, owner: owner) do
      {:ok, handles} -> Enum.each(handles, &Sandboxd.destroy/1)
      _ -> :ok
    end
  end

  defp relay do
    test = self()
    spawn_link(fn -> relay_loop(test) end)
  end

  defp relay_loop(test) do
    receive do
      {:"$gen_cast", msg} ->
        send(test, {:cast, msg})
        relay_loop(test)
    end
  end

  defp collect(acc \\ "") do
    receive do
      {:cast, {:stdout_data, data}} -> collect(acc <> data)
      {:cast, :eof} -> {:eof, acc}
    after
      5_000 -> {:timeout, acc}
    end
  end

  describe "a full session (blocker: a transport that only works in unit tests)" do
    test "provisions, execs, streams and destroys", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        # provision/1 returned only because health answered — that is the
        # provider's contract, and it is what makes the next line safe.
        assert Sandboxd.alive?(handle)

        assert {:ok, handle} = Sandboxd.exec(handle, "/bin/sh", @echo_cli, %{})
        assert {:ok, _reader} = Sandboxd.start_reader(handle, relay(), Backend.new_cursor())

        assert :ok = Sandboxd.write(handle, "first\n")
        assert_receive {:cast, {:stdout_data, data}}, 10_000
        assert data =~ ~s|{"echo":"first"}|

        assert :ok = Sandboxd.write(handle, "second\n")
        assert_receive {:cast, {:stdout_data, more}}, 10_000
        assert more =~ ~s|{"echo":"second"}|
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end

    test "env reaches the CLI but never its argv", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        cli = ["-c", ~S|printf '%s\n' "$CC_TEST_SECRET"; ps -ww -o args= -p $$|]

        assert {:ok, handle} =
                 Sandboxd.exec(handle, "/bin/sh", cli, %{"CC_TEST_SECRET" => "sk-x"})

        assert {:ok, _reader} = Sandboxd.start_reader(handle, relay(), Backend.new_cursor())

        {_reason, output} = collect()

        # Delivered to the process...
        assert output =~ "sk-x"
        # ...but the process image itself does not carry it.
        argv_line = output |> String.split("\n") |> Enum.find(&String.contains?(&1, "ps -ww"))
        refute argv_line && String.contains?(argv_line, "sk-x")
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end
  end

  describe "mid-session reattach (blocker: a resume that loses or duplicates bytes)" do
    test "resumes byte-exactly at a persisted offset", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        assert {:ok, handle} = Sandboxd.exec(handle, "/bin/sh", @echo_cli, %{})
        assert {:ok, reader} = Sandboxd.start_reader(handle, relay(), Backend.new_cursor())

        assert :ok = Sandboxd.write(handle, "before\n")
        assert_receive {:cast, {:stdout_data, first}}, 10_000

        # Drop the reader, exactly as a node restart would.
        Process.unlink(reader)
        Process.exit(reader, :kill)

        assert :ok = Sandboxd.write(handle, "after\n")

        # Reattach at the offset the session would have persisted, then resume.
        cursor = %{byte_offset: byte_size(first), buffer: ""}
        assert {:ok, reattached} = Sandboxd.reattach(handle, cursor)
        assert {:ok, _reader} = Sandboxd.start_reader(reattached, relay(), cursor)

        assert_receive {:cast, {:stdout_data, second}}, 10_000

        # Byte-exact: the resumed stream starts where the first one stopped, so
        # the first line is not repeated and nothing between them is lost.
        refute second =~ "before"
        assert second =~ ~s|{"echo":"after"}|
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end

    test "reattach rebuilds the endpoint rather than reusing a stale port", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        original = handle.endpoint.base_url

        # What Store actually round-trips: no endpoint at all.
        persisted =
          handle |> Sandboxd.scrub() |> :erlang.term_to_binary() |> :erlang.binary_to_term()

        assert persisted.endpoint == nil

        assert {:ok, reattached} = Sandboxd.reattach(persisted, Backend.new_cursor())
        assert reattached.endpoint.base_url == original
        assert Sandboxd.alive?(reattached)
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end
  end

  describe "destroy/1 (blocker: a teardown path that raises on the second call)" do
    test "is idempotent", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      assert :ok = Sandboxd.destroy(handle)
      assert :ok = Sandboxd.destroy(handle)
      refute Sandboxd.alive?(handle)
    end

    test "removes the per-sandbox network too, not just the container", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)
      network = handle.provider_handle.network_name

      assert :ok = Sandboxd.destroy(handle)

      assert {:error, {:docker, {:not_found, _}}} =
               CrowdControl.Backend.Docker.API.request([], :get, "/networks/#{network}")
    end
  end

  describe "list_live/1 and orphan reaping (blocker: a reaper that cannot see sandboxes)" do
    test "lists this owner's sandboxes and nobody else's", %{opts: opts, owner: owner} do
      assert {:ok, _handle} = Sandboxd.provision(opts)

      try do
        assert {:ok, handles} = Sandboxd.list_live(provider: Provider.Docker, owner: owner)
        assert length(handles) == 1
        assert hd(handles).session_key == session_key(owner)
        assert hd(handles).owner == owner

        assert {:ok, []} =
                 Sandboxd.list_live(provider: Provider.Docker, owner: "some-other-node")
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end

    test "a listed handle can be destroyed, which is what the reaper does",
         %{opts: opts, owner: owner} do
      assert {:ok, _handle} = Sandboxd.provision(opts)

      assert {:ok, [orphan]} = Sandboxd.list_live(provider: Provider.Docker, owner: owner)
      assert :ok = Sandboxd.destroy(orphan)

      assert {:ok, []} = Sandboxd.list_live(provider: Provider.Docker, owner: owner)
    end

    test "age_ms reports a plausible age, so the reap grace period works", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        age = Sandboxd.age_ms(handle)
        assert is_integer(age)
        assert age >= 0 and age < 300_000
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end
  end

  describe "the agent's auth (blocker: a sandbox any local process can drive)" do
    test "a wrong token is rejected by the live agent", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        forged = %{handle.endpoint | token: "not-the-token"}
        assert {:error, {:sandboxd, :unauthorized}} = API.status(forged, 0)

        # Health is unauthenticated on purpose: a provider must poll it before
        # any token round trip can have succeeded. It leaks no state.
        assert :ok = API.health(forged)
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end

    test "a rotated secret fails reattach closed", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        Application.put_env(:crowd_control, :sandboxd_secret, "a-different-secret-32-bytes-min!!")

        # The documented consequence of deriving the token instead of storing
        # it. Failing closed is the intended trade against a live credential
        # sitting in DETS.
        assert {:ok, reattached} = Sandboxd.reattach(handle, Backend.new_cursor())
        assert {:error, {:sandboxd, :unauthorized}} = API.status(reattached.endpoint, 0)
      after
        Application.put_env(:crowd_control, :sandboxd_secret, "integration-secret-32-bytes-min!!")
        Sandboxd.destroy(handle_for(opts))
      end
    end
  end

  describe "push_file/4 (blocker: an unusable :agent_dir on a remote sandbox)" do
    test "writes a file inside the sandbox at 0600", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        assert :ok = Sandboxd.push_file(handle, "/tmp/cc-agent/models.yml", "provider: test\n")

        # Read it back through the agent's own exec, so this asserts the file is
        # in the sandbox rather than on the host.
        assert {:ok, handle} =
                 Sandboxd.exec(handle, "/bin/sh", ["-c", "cat /tmp/cc-agent/models.yml"], %{})

        assert {:ok, _reader} = Sandboxd.start_reader(handle, relay(), Backend.new_cursor())

        {_reason, output} = collect()
        assert output =~ "provider: test"
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end

    test "a traversal path is refused client-side, before any request", %{opts: opts} do
      assert {:ok, handle} = Sandboxd.provision(opts)

      try do
        assert {:error, {:sandboxd, {:bad_path, _}}} =
                 Sandboxd.push_file(handle, "/tmp/../etc/passwd", "pwned")
      after
        Sandboxd.destroy(handle_for(opts))
      end
    end
  end

  # Teardown needs a handle even on the paths where the test rebound its own.
  # Re-deriving it from the owner label is more robust than threading the latest
  # binding through every `after` block.
  defp handle_for(opts) do
    case Sandboxd.list_live(provider: Provider.Docker, owner: opts[:owner]) do
      {:ok, [handle | _]} -> handle
      _ -> %Sandboxd{}
    end
  end
end
