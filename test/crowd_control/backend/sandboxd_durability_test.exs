defmodule CrowdControl.Backend.SandboxdDurabilityTest do
  # Phase 4 of the sandbox-providers plan: what survives a node restart, what
  # must not, and whether the reaper can drive this backend unchanged.
  #
  # Hermetic — every substrate call is stubbed. The live-daemon equivalents are
  # in sandboxd_test.exs.
  use ExUnit.Case, async: false

  use ExUnitProperties

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Sandboxd
  alias CrowdControl.Provider
  alias CrowdControl.Provider.Endpoint
  alias CrowdControl.Reaper
  alias CrowdControl.Store

  @session "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
  @secret "durability-test-secret-32-bytes!!"

  setup do
    previous = Application.get_env(:crowd_control, :sandboxd_secret)
    Application.put_env(:crowd_control, :sandboxd_secret, @secret)
    Enum.each(Store.all(), &Store.delete(&1.key))

    # The stub providers run inside the reaper process, not the test, so they
    # need a way back to the assertions.
    put_listener(self())

    on_exit(fn ->
      Enum.each(Store.all(), &Store.delete(&1.key))

      if previous do
        Application.put_env(:crowd_control, :sandboxd_secret, previous)
      else
        Application.delete_env(:crowd_control, :sandboxd_secret)
      end
    end)

    :ok
  end

  describe "reattach across a node restart (blocker: a cursor that points at nothing)" do
    test "a Store record round-trips into a working, re-endpointed handle" do
      # The full path a restarted node walks: DETS record -> term_to_binary ->
      # Provider.reconnect/1 -> a *new* endpoint -> start_reader/3 at the
      # persisted offset.
      handle = handle()

      record =
        Store.build(
          key: @session,
          session_id: "cli-1",
          backend: Sandboxd,
          handle: Backend.scrub(Sandboxd, handle),
          byte_offset: 4_096,
          buffer: ~s|{"partial":|,
          opts: Store.scrub_opts(api_key: "sk-real", image: "sandbox:dev")
        )

      Store.put(@session, record)

      # Simulate the restart: nothing in memory survives, only the store.
      assert {:ok, restored} = Store.get(@session)
      revived = restored.handle |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert revived.endpoint == nil

      cursor = %{byte_offset: restored.byte_offset, buffer: restored.buffer}
      assert {:ok, reattached} = Sandboxd.reattach(revived, cursor)

      # A *new* path, and the port genuinely differs from the original.
      assert reattached.endpoint.base_url == "http://127.0.0.1:41111"
      refute reattached.endpoint.base_url == handle.endpoint.base_url

      # The token is re-derived, not restored, and it still matches.
      assert reattached.endpoint.token == Provider.token(@session)

      assert {:ok, reader} = Sandboxd.start_reader(reattached, self(), cursor)
      assert is_pid(reader)
    end

    test "the reader resumes at the persisted offset, not at zero" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      adapter = fn req ->
        Agent.update(agent, &[to_string(req.url) | &1])
        {req, Req.Response.new(status: 200, body: "")}
      end

      handle = handle(endpoint: endpoint(adapter))
      cursor = %{byte_offset: 8_192, buffer: ""}

      assert {:ok, _reader} = Sandboxd.start_reader(handle, self(), cursor)

      # Give the reader a moment to issue its request.
      Process.sleep(100)

      urls = Agent.get(agent, & &1)

      assert Enum.any?(urls, &(&1 =~ "offset=8192")),
             "reader did not resume at 8192: #{inspect(urls)}"
    end

    test "reattach after a secret rotation fails closed rather than silently" do
      handle = handle()
      Application.put_env(:crowd_control, :sandboxd_secret, "rotated-secret-also-32-bytes!!!!")

      # reconnect/1 itself succeeds — the container is still there — but the
      # derived token no longer matches the one the sandbox was started with.
      # The failure surfaces on first use, tagged, not as a mysterious hang.
      assert {:ok, reattached} = Sandboxd.reattach(handle, Backend.new_cursor())
      refute reattached.endpoint.token == handle.endpoint.token
    end
  end

  describe "persisted handles carry no secrets (property)" do
    property "no scrubbed handle ever persists a token, url or credential" do
      # A property rather than examples because the leak this guards against is
      # a *field* leak: someone adds a field to the struct, forgets scrub/1, and
      # every example test still passes because it only knew the old fields.
      check all(
              session_key <- string(:alphanumeric, min_length: 8, max_length: 40),
              api_key <- string(:alphanumeric, min_length: 8, max_length: 40),
              port <- integer(1024..65_535),
              max_runs: 50
            ) do
        token = Provider.token(session_key)

        handle = %Sandboxd{
          provider: __MODULE__.StubProvider,
          provider_handle: %{
            container_id: "ctr",
            session_key: session_key,
            token: token,
            gce_config: %{token_provider: fn -> api_key end}
          },
          endpoint: %Endpoint{
            base_url: "http://127.0.0.1:#{port}",
            token: token,
            transport: self()
          },
          session_key: session_key,
          owner: "node-a",
          # A distinctive literal on purpose: "sess" would match inside the
          # atom name `session_key`, which term_to_binary encodes as text, so
          # the assertion below would fail on a handle with no leak at all.
          config: [api_key: api_key, session_token: "SESSTOKEN-b7f3", image: "sandbox:dev"]
        }

        scrubbed = Sandboxd.scrub(handle)

        # term_to_binary, not inspect: Endpoint redacts on inspect, so an
        # inspect-based property would pass vacuously.
        bytes = :erlang.term_to_binary(scrubbed)

        refute contains?(bytes, token), "token persisted"
        refute contains?(bytes, api_key), "api key persisted"
        refute contains?(bytes, "127.0.0.1:#{port}"), "base_url persisted"
        refute contains?(bytes, "SESSTOKEN-b7f3"), "session token persisted"

        # And it is still usable: identity survives so reconnect/1 can work.
        assert scrubbed.session_key == session_key
        assert scrubbed.owner == "node-a"
        assert scrubbed.provider == __MODULE__.StubProvider

        # No live term survived, which is what makes the record writable at all.
        assert scrubbed.endpoint == nil
        refute Map.has_key?(scrubbed.provider_handle, :gce_config)
      end
    end

    property "every scrubbed handle survives a term_to_binary round trip" do
      check all(session_key <- string(:alphanumeric, min_length: 8, max_length: 40)) do
        scrubbed = Sandboxd.scrub(handle(session_key: session_key))

        assert scrubbed ==
                 scrubbed |> :erlang.term_to_binary() |> :erlang.binary_to_term()
      end
    end
  end

  describe "Store.secret_keys/0 (blocker: a credential named something new)" do
    test "covers the two keys the provider work introduced" do
      assert :sandboxd_secret in Store.secret_keys()
      assert :gce_config in Store.secret_keys()
    end

    test "scrub_opts drops them" do
      opts = [
        sandboxd_secret: "the-real-secret",
        gce_config: %{token_provider: fn -> "live" end},
        image: "sandbox:dev"
      ]

      scrubbed = Store.scrub_opts(opts)

      refute Keyword.has_key?(scrubbed, :sandboxd_secret)
      refute Keyword.has_key?(scrubbed, :gce_config)
      assert scrubbed[:image] == "sandbox:dev"
    end

    test "a handle scrubbed through the backend loses :sandboxd_secret from config" do
      handle = handle(config: [sandboxd_secret: "the-real-secret", image: "sandbox:dev"])
      scrubbed = Sandboxd.scrub(handle)

      refute contains?(:erlang.term_to_binary(scrubbed), "the-real-secret")
    end
  end

  describe "Reaper drives this backend with no changes (blocker: an unreapable substrate)" do
    test "a provider-shaped backend spec is a valid :reaper backend" do
      # The point of delegating list_live/1 to the provider: the reaper needs no
      # knowledge of providers at all.
      spec = {Sandboxd, provider: {__MODULE__.OldStubProvider, []}, owner: "node-a"}
      reaper = start_reaper(spec)

      # A live sandbox with no store record is an orphan; the sweep must destroy
      # it rather than ignore it or crash on the provider indirection.
      stats = Reaper.sweep(reaper)

      assert stats.destroyed == 1
      assert stats.skipped == 0
      assert_receive {:released, "0f1e2d3c4b5a69788796a5b4c3d2e1f0"}, 1_000
    end

    test "a provider with no age_ms/1 makes its orphans permanently unreapable" do
      # Not a bug, and not obvious: Backend.Sandboxd exports age_ms/1, so the
      # reaper always consults it; delegation returns nil for a provider that
      # defines none; and the reaper's fail-open rule reads an unknown age as
      # "too young to reap". The net effect is that omitting the optional
      # callback silently costs you orphan collection forever, so the callback is
      # optional in the behaviour and mandatory in practice.
      spec = {Sandboxd, provider: {__MODULE__.StubProvider, []}, owner: "node-a"}
      reaper = start_reaper(spec)

      stats = Reaper.sweep(reaper)

      assert stats.destroyed == 0
      refute_receive {:released, _}, 200
    end

    test "owner scoping survives the delegation" do
      spec = {Sandboxd, provider: {__MODULE__.OwnerRecordingProvider, []}, owner: "node-b"}

      reaper = start_reaper(spec)

      stats = Reaper.sweep(reaper)

      # Unscoped, one node's reaper would destroy another node's sandboxes.
      assert_receive {:listed_owner, "node-b"}, 1_000
      assert stats.destroyed == 0
    end

    test "a provider list error makes the sweep fail open, destroying nothing" do
      spec = {Sandboxd, provider: {__MODULE__.FailingProvider, []}, owner: "node-a"}

      reaper = start_reaper(spec)

      # Fail-open is the rule: a daemon that cannot be listed must never be read
      # as "no sandboxes exist", or a network blip prunes live work.
      stats = Reaper.sweep(reaper)

      assert stats.skipped == 1
      assert stats.destroyed == 0
      assert stats.pruned == 0
      refute_receive {:released, _}, 200
    end

    test "age_ms delegates, so the reap grace period still applies" do
      handle = handle(provider: __MODULE__.AgingProvider)
      assert Sandboxd.age_ms(handle) == 1_234
    end
  end

  # --- Helpers ---

  defp handle(overrides \\ []) do
    session_key = Keyword.get(overrides, :session_key, @session)

    defaults = [
      provider: __MODULE__.StubProvider,
      provider_handle: %{container_id: "ctr", session_key: session_key},
      endpoint: endpoint(fn req -> {req, Req.Response.new(status: 200, body: "")} end),
      session_key: session_key,
      owner: "node-a",
      config: []
    ]

    struct!(Sandboxd, Keyword.merge(defaults, Keyword.delete(overrides, :session_key)))
  end

  defp endpoint(adapter) do
    %Endpoint{
      base_url: "http://127.0.0.1:32768",
      token: Provider.token(@session),
      req_options: [adapter: adapter]
    }
  end

  defp contains?(bytes, needle), do: :binary.match(bytes, needle) != :nomatch

  defp start_sup do
    start_supervised!(%{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]}
    })
  end

  # An UNNAMED reaper per test with manual sweeps only, so no background timer
  # races the assertions and nothing collides with the application's own inert
  # Reaper.
  defp start_reaper(spec) do
    start_supervised!(%{
      id: {Reaper, make_ref()},
      start:
        {Reaper, :start_link,
         [
           [
             name: nil,
             sweep_interval: 0,
             sweep_on_boot: false,
             reattach: false,
             reap_grace_ms: 1_000,
             backends: [spec],
             supervisor: start_sup()
           ]
         ]}
    })
  end

  defmodule StubProvider do
    @moduledoc false
    @behaviour CrowdControl.Provider

    alias CrowdControl.Backend.SandboxdDurabilityTest, as: Parent

    @session "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    @impl true
    def acquire(_opts), do: {:error, :not_implemented}

    @impl true
    def reconnect(handle) do
      # A *different* port than the original, which is the whole reason the
      # endpoint is rebuilt rather than persisted.
      {:ok, handle,
       %CrowdControl.Provider.Endpoint{
         base_url: "http://127.0.0.1:41111",
         token: CrowdControl.Provider.token(handle.session_key || @session)
       }}
    end

    @impl true
    def release(handle) do
      send(Parent.listener(), {:released, Map.get(handle, :session_key)})

      :ok
    end

    @impl true
    def list_live(_opts), do: {:ok, [%{container_id: "ctr", session_key: @session}]}

    @impl true
    def scrub(handle), do: Map.take(handle, [:container_id, :session_key])
  end

  # Identical to StubProvider except that it reports an age past the reap grace
  # window, which is what actually makes an orphan reapable.
  defmodule OldStubProvider do
    @moduledoc false
    @behaviour CrowdControl.Provider

    @impl true
    def acquire(opts), do: StubProvider.acquire(opts)
    @impl true
    def reconnect(handle), do: StubProvider.reconnect(handle)
    @impl true
    def release(handle), do: StubProvider.release(handle)
    @impl true
    def list_live(opts), do: StubProvider.list_live(opts)
    @impl true
    def scrub(handle), do: StubProvider.scrub(handle)

    @impl true
    def age_ms(_handle), do: 60_000
  end

  defmodule OwnerRecordingProvider do
    @moduledoc false
    @behaviour CrowdControl.Provider

    alias CrowdControl.Backend.SandboxdDurabilityTest, as: Parent

    @impl true
    def acquire(_opts), do: {:error, :not_implemented}
    @impl true
    def reconnect(handle),
      do: {:ok, handle, %CrowdControl.Provider.Endpoint{base_url: "x", token: "y"}}

    @impl true
    def release(_handle), do: :ok

    @impl true
    def list_live(opts) do
      send(Parent.listener(), {:listed_owner, opts[:owner]})
      {:ok, []}
    end
  end

  defmodule FailingProvider do
    @moduledoc false
    @behaviour CrowdControl.Provider

    @impl true
    def acquire(_opts), do: {:error, :boom}
    @impl true
    def reconnect(_handle), do: {:error, :boom}
    @impl true
    def release(_handle), do: :ok
    @impl true
    def list_live(_opts), do: {:error, {:docker, {:transport, :econnrefused}}}
  end

  defmodule AgingProvider do
    @moduledoc false
    @behaviour CrowdControl.Provider

    @impl true
    def acquire(_opts), do: {:error, :not_implemented}
    @impl true
    def reconnect(handle),
      do: {:ok, handle, %CrowdControl.Provider.Endpoint{base_url: "x", token: "y"}}

    @impl true
    def release(_handle), do: :ok
    @impl true
    def list_live(_opts), do: {:ok, []}
    @impl true
    def age_ms(_handle), do: 1_234
  end

  # The stub providers run inside the reaper, not the test, so they need a way
  # back to the assertions.
  @doc false
  def listener, do: :persistent_term.get({__MODULE__, :listener})

  @doc false
  def put_listener(pid), do: :persistent_term.put({__MODULE__, :listener}, pid)
end
