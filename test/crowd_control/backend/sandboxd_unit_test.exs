defmodule CrowdControl.Backend.SandboxdUnitTest do
  # Hermetic: every agent call is answered by a stub adapter carried in the
  # endpoint's :req_options, so no daemon, container or socket is involved.
  # Everything needing a live agent lives in sandboxd_test.exs.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend
  alias CrowdControl.Backend.Sandboxd
  alias CrowdControl.Backend.Sandboxd.API
  alias CrowdControl.Provider.Endpoint
  alias CrowdControl.Store

  @session "0123456789abcdef0123456789abcdef"
  @token "a-derived-token"

  describe "reattachable?/0" do
    test "is true, which is what makes Session persist a cursor" do
      assert Backend.reattachable?(Sandboxd)
    end
  end

  describe "scrub/1 (blocker: an ephemeral endpoint persisted as if it were stable)" do
    # These assert on `:erlang.term_to_binary/1` rather than on `inspect/1`.
    # Endpoint's Inspect implementation redacts the token, so an inspect-based
    # check passes whether or not the token is actually there — it would have
    # proved nothing about what Store writes to disk. The persisted bytes are
    # the thing under test.
    test "drops the endpoint wholesale" do
      handle = handle()
      assert handle.endpoint

      # Wholesale rather than field-by-field: a future field on Endpoint would
      # otherwise leak by omission, and every field on it is ephemeral anyway.
      assert Sandboxd.scrub(handle).endpoint == nil
    end

    test "the token is absent from the scrubbed handle's persisted bytes" do
      refute persists?(Sandboxd.scrub(handle()), @token)
    end

    test "the base_url is absent, because the port is reassigned on every start" do
      refute persists?(Sandboxd.scrub(handle()), "127.0.0.1:32768")
    end

    test "drops every secret-bearing config key" do
      handle =
        handle(
          config: [
            api_key: "sk-real",
            session_token: "sess",
            env: %{"ANTHROPIC_API_KEY" => "sk-also-real"},
            auth_token: "auth"
          ]
        )

      scrubbed = Sandboxd.scrub(handle)

      for key <- Store.secret_keys() do
        refute Keyword.has_key?(scrubbed.config, key), "#{key} survived scrubbing"
      end

      refute persists?(scrubbed, "sk-real")
      refute persists?(scrubbed, "sk-also-real")
    end

    test "delegates to the provider's own scrub" do
      handle =
        handle(provider: __MODULE__.ScrubbingProvider, provider_handle: %{keep: 1, drop: 2})

      assert Sandboxd.scrub(handle).provider_handle == %{keep: 1}
    end

    test "the scrubbed handle survives term_to_binary, which is what Store requires" do
      round_tripped =
        handle() |> Sandboxd.scrub() |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert round_tripped.session_key == @session
      assert round_tripped.endpoint == nil
    end

    test "an UNSCRUBBED handle really would persist the token" do
      # Stated as an assertion so the reason scrub/1 exists is not merely a
      # comment: this is the leak, and Session.persist/2 is what prevents it.
      assert persists?(handle(), @token)
    end
  end

  describe "reader :eof contract (blocker: a session hanging on a dead stream)" do
    test "casts :eof exactly once when the stream cannot even be opened" do
      endpoint = endpoint(fn req -> {req, %Req.TransportError{reason: :econnrefused}} end)

      {:ok, _reader} =
        Sandboxd.start_reader(handle(endpoint: endpoint), self(), Backend.new_cursor())

      assert_receive {:"$gen_cast", :eof}, 1_000
      refute_receive {:"$gen_cast", :eof}, 100
    end

    test "casts :eof exactly once when the agent rejects the token" do
      endpoint = endpoint(fn req -> {req, Req.Response.new(status: 401, body: "")} end)

      {:ok, _reader} =
        Sandboxd.start_reader(handle(endpoint: endpoint), self(), Backend.new_cursor())

      assert_receive {:"$gen_cast", :eof}, 1_000
      refute_receive {:"$gen_cast", :eof}, 100
    end

    test "casts no :eof and delivers nothing before the stream is opened" do
      # A reader whose endpoint is missing must not be startable at all, rather
      # than starting and immediately reporting a phantom EOF.
      assert {:error, {:sandboxd, :not_provisioned}} =
               Sandboxd.start_reader(handle(endpoint: nil), self(), Backend.new_cursor())
    end

    test "an abnormal exit from the stream task still produces exactly one :eof" do
      # Finch spawn_links its worker to the reader, so without trap_exit an
      # abnormal task exit kills the reader before it can cast :eof — and
      # Session never monitors the reader, so the session would die with no
      # end-of-stream at all. Asserted through the contract rather than by
      # inspecting the flag, because the flag is set asynchronously.
      endpoint = endpoint(fn req -> {req, Req.Response.new(status: 200, body: "")} end)

      {:ok, reader} =
        Sandboxd.start_reader(handle(endpoint: endpoint), self(), Backend.new_cursor())

      # From a third process, not from the test: the test process *is* the
      # session here, and the session exiting is deliberately not an error.
      spawn(fn -> Process.exit(reader, :boom) end)

      assert_receive {:"$gen_cast", :eof}, 1_000
      refute_receive {:"$gen_cast", :eof}, 100
    end

    test "the session's own exit stops the reader without a pointless :eof" do
      endpoint = endpoint(fn req -> {req, Req.Response.new(status: 200, body: "")} end)
      test = self()

      # start_reader/3 must be called *from* the session, as Session.init/1 does,
      # or the spawn_link lands on the wrong process and the link under test does
      # not exist at all.
      session =
        spawn(fn ->
          {:ok, reader} =
            Sandboxd.start_reader(handle(endpoint: endpoint), self(), Backend.new_cursor())

          send(test, {:reader, reader})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:reader, reader}
      ref = Process.monitor(reader)

      send(session, :stop)

      # Once trapping exits the reader no longer dies *with* the session, so it
      # has to stop on that signal or readers outlive their sessions forever.
      assert_receive {:DOWN, ^ref, :process, ^reader, _reason}, 1_000
    end
  end

  describe "provisioning guards" do
    test "exec is refused before provisioning rather than crashing" do
      assert {:error, {:sandboxd, :not_provisioned}} =
               Sandboxd.exec(handle(endpoint: nil), "/bin/echo", [], %{})
    end

    test "write is refused before provisioning" do
      assert {:error, {:sandboxd, :not_provisioned}} = Sandboxd.write(handle(endpoint: nil), "hi")
    end

    test "push_file is refused before provisioning" do
      assert {:error, {:sandboxd, :not_provisioned}} =
               Sandboxd.push_file(handle(endpoint: nil), "/tmp/x", "body")
    end

    test "alive? is false rather than raising" do
      refute Sandboxd.alive?(handle(endpoint: nil))
    end

    test "await_exit times out rather than raising" do
      assert :timeout = Sandboxd.await_exit(handle(endpoint: nil), 10)
    end

    test "destroy is a no-op with no provider, since Session calls it on every path" do
      assert :ok = Sandboxd.destroy(%Sandboxd{})
    end

    test "age_ms is nil with no provider" do
      assert Sandboxd.age_ms(%Sandboxd{}) == nil
    end
  end

  describe "await_exit/2 (blocker: waiting out a full timeout on a dead sandbox)" do
    test "returns the exit status once the CLI has finished" do
      endpoint =
        endpoint(fn req ->
          {req,
           Req.Response.new(
             status: 200,
             body: %{"alive" => false, "started" => true, "exit_status" => 3, "bytes" => 12}
           )}
        end)

      assert {:ok, 3} = Sandboxd.await_exit(handle(endpoint: endpoint), 1_000)
    end

    test "an unreachable agent is exited-but-unknown, not a timeout" do
      # {:ok, nil} is the behaviour's spelling for that. Reporting :timeout would
      # make Session wait out its full timeout on a sandbox that is already gone.
      endpoint = endpoint(fn req -> {req, %Req.TransportError{reason: :econnrefused}} end)

      assert {:ok, nil} = Sandboxd.await_exit(handle(endpoint: endpoint), 1_000)
    end

    test "a still-running CLI times out" do
      endpoint =
        endpoint(fn req ->
          {req,
           Req.Response.new(
             status: 200,
             body: %{"alive" => true, "started" => true, "exit_status" => nil, "bytes" => 0}
           )}
        end)

      assert :timeout = Sandboxd.await_exit(handle(endpoint: endpoint), 60)
    end
  end

  describe "list_live/1 (blocker: a reaper that cannot see the owner)" do
    test "lifts session_key and owner onto the backend handle" do
      opts = [provider: {__MODULE__.ListingProvider, []}, owner: "node-a"]

      assert {:ok, [handle]} = Sandboxd.list_live(opts)
      assert handle.session_key == @session
      assert handle.owner == "node-a"
      assert handle.provider == __MODULE__.ListingProvider
      # No endpoint: the reaper only needs identity, and building one would mean
      # opening a tunnel per listed sandbox on every sweep.
      assert handle.endpoint == nil
    end

    test "propagates a provider list error so the reaper can fail open" do
      opts = [provider: {__MODULE__.FailingProvider, []}]
      assert {:error, :boom} = Sandboxd.list_live(opts)
    end
  end

  describe "reattach/2 (blocker: reattaching to a stale port)" do
    test "rebuilds the endpoint from the provider" do
      handle = handle(provider: __MODULE__.ReconnectingProvider, endpoint: nil)

      assert {:ok, reattached} = Sandboxd.reattach(handle, Backend.new_cursor())
      assert reattached.endpoint.base_url == "http://127.0.0.1:49999"
    end

    test "propagates a reconnect failure" do
      handle = handle(provider: __MODULE__.FailingProvider, endpoint: nil)
      assert {:error, :boom} = Sandboxd.reattach(handle, Backend.new_cursor())
    end

    test "is refused with no provider" do
      assert {:error, {:sandboxd, :not_provisioned}} =
               Sandboxd.reattach(%Sandboxd{}, Backend.new_cursor())
    end
  end

  describe "API error normalization (blocker: a raw struct reaching Session)" do
    test "401 is :unauthorized, which is how a rotated secret surfaces" do
      assert {:error, {:sandboxd, :unauthorized}} =
               API.health(endpoint(status(401, "")))
    end

    test "404 is :not_found" do
      assert {:error, {:sandboxd, :not_found}} = API.health(endpoint(status(404, "")))
    end

    test "409 already_executed is distinguished from 409 not_started" do
      assert {:error, {:sandboxd, :already_executed}} =
               API.exec(
                 endpoint(status(409, %{"error" => "already_executed"})),
                 "/bin/x",
                 [],
                 %{}
               )

      assert {:error, {:sandboxd, :not_started}} =
               API.write(endpoint(status(409, %{"error" => "not_started"})), "hi")
    end

    test "an unrecognized 409 keeps its message rather than becoming a generic error" do
      assert {:error, {:sandboxd, {:conflict, "something else"}}} =
               API.exec(endpoint(status(409, %{"error" => "something else"})), "/bin/x", [], %{})
    end

    test "other non-2xx keeps the status and a truncated message" do
      assert {:error, {:sandboxd, {:http_status, 500, "boom"}}} =
               API.health(endpoint(status(500, %{"error" => "boom"})))
    end

    test "a connect-phase Req.TransportError folds into :transport" do
      endpoint = endpoint(fn req -> {req, %Req.TransportError{reason: :econnrefused}} end)
      assert {:error, {:sandboxd, {:transport, :econnrefused}}} = API.health(endpoint)
    end

    test "a mid-stream Finch.TransportError folds into the same :transport shape" do
      # Different struct, same vocabulary. A caller that folded only the Req one
      # would leak a raw struct out of the backend the moment a sandbox died
      # mid-session.
      endpoint = endpoint(fn req -> {req, %Finch.TransportError{reason: :closed}} end)
      assert {:error, {:sandboxd, {:transport, :closed}}} = API.health(endpoint)
    end

    test "a 200 with the wrong shape is an error, not a silent success" do
      assert {:error, {:sandboxd, {:unexpected_body, _}}} =
               API.health(endpoint(status(200, %{"ok" => "yes"})))
    end

    test "error messages are truncated so a payload cannot land in a crash report" do
      long = String.duplicate("x", 5_000)

      assert {:error, {:sandboxd, {:http_status, 500, message}}} =
               API.health(endpoint(status(500, %{"error" => long})))

      assert byte_size(message) == 200
    end
  end

  describe "API request shape (blocker: a secret in a query string or a log)" do
    test "exec sends env in the JSON body, never in the URL" do
      {endpoint, agent} = recording_endpoint()

      API.exec(endpoint, "/bin/sh", ["-c", "run"], %{"ANTHROPIC_API_KEY" => "sk-secret"})

      req = Agent.get(agent, & &1)
      refute to_string(req.url) =~ "sk-secret"
      assert req.options.json["env"] == %{"ANTHROPIC_API_KEY" => "sk-secret"}
    end

    test "stdin is base64 so arbitrary bytes survive JSON" do
      {endpoint, agent} = recording_endpoint()

      API.write(endpoint, <<0, 1, 2, 255>>)

      req = Agent.get(agent, & &1)
      assert req.options.json["data"] == Base.encode64(<<0, 1, 2, 255>>)
    end

    test "the token rides in the authorization header" do
      {endpoint, agent} = recording_endpoint()

      API.health(endpoint)

      req = Agent.get(agent, & &1)
      assert req.headers["authorization"] == ["Bearer " <> @token]
    end

    test "a per-request header does not displace the authorization header" do
      # Regression. PUT /v1/files passes a content-type, and Keyword.merge/2
      # replaces a key wholesale rather than merging it — so every file write
      # went out with no credential and came back 401. Caught by the live
      # integration test, pinned here.
      {endpoint, agent} = recording_endpoint()

      API.put_file(endpoint, "/tmp/agent/models.yml", "provider: test\n")

      req = Agent.get(agent, & &1)
      assert req.headers["authorization"] == ["Bearer " <> @token]
      assert req.headers["content-type"] == ["application/octet-stream"]
    end

    test "put_file sends the mode as octal text and the body verbatim" do
      {endpoint, agent} = recording_endpoint()

      API.put_file(endpoint, "/tmp/x", "raw bytes", 0o755)

      req = Agent.get(agent, & &1)
      assert to_string(req.url) =~ "mode=0755"
      assert req.body == "raw bytes"
    end

    test "endpoint headers override the derived authorization header" do
      # The Kubernetes pod-proxy case: the transport claims `authorization` for
      # its own credential, so the agent token moves carrier.
      {endpoint, agent} = recording_endpoint()

      endpoint = %{
        endpoint
        | headers: [
            {"authorization", "Bearer apiserver-credential"},
            {"x-cc-authorization", "Bearer " <> @token}
          ]
      }

      API.health(endpoint)

      req = Agent.get(agent, & &1)
      assert req.headers["authorization"] == ["Bearer apiserver-credential"]
      assert req.headers["x-cc-authorization"] == ["Bearer " <> @token]
    end

    test "stream offsets are sent as given, 0-indexed" do
      {endpoint, agent} = recording_endpoint()

      API.stream(endpoint, 0)
      assert to_string(Agent.get(agent, & &1).url) =~ "offset=0"

      API.stream(endpoint, 4_096)
      assert to_string(Agent.get(agent, & &1).url) =~ "offset=4096"
    end

    test "retries are off, so one refused connection is not three seconds of backoff" do
      {endpoint, agent} = recording_endpoint()

      API.health(endpoint)
      assert Agent.get(agent, & &1).options.retry == false
    end
  end

  describe "API.safe_path/1 (blocker: writing outside the intended directory)" do
    test "accepts an absolute path" do
      assert {:ok, "/tmp/agent/models.yml"} = API.safe_path("/tmp/agent/models.yml")
    end

    test "normalizes repeated separators without resolving anything" do
      assert {:ok, "/tmp/x"} = API.safe_path("/tmp//x")
    end

    test "rejects .. rather than resolving it" do
      assert {:error, {:sandboxd, {:bad_path, _}}} = API.safe_path("/tmp/../etc/passwd")
      assert {:error, {:sandboxd, {:bad_path, _}}} = API.safe_path("/../etc/passwd")
    end

    test "rejects a single-dot segment" do
      assert {:error, {:sandboxd, {:bad_path, _}}} = API.safe_path("/tmp/./x")
    end

    test "rejects a relative path" do
      assert {:error, {:sandboxd, {:bad_path, _}}} = API.safe_path("tmp/x")
    end

    test "rejects an empty path" do
      assert {:error, {:sandboxd, {:bad_path, _}}} = API.safe_path("/")
    end

    test "rejects a null byte" do
      assert {:error, {:sandboxd, {:bad_path, _}}} = API.safe_path("/tmp/x\0y")
    end

    test "put_file rejects a bad path before issuing any request" do
      adapter = fn _req -> raise "must not be called" end

      assert {:error, {:sandboxd, {:bad_path, _}}} =
               API.put_file(endpoint(adapter), "/tmp/../etc/passwd", "pwned")
    end
  end

  describe "API.await_health/2 (blocker: provisioning that reports success too early)" do
    test "returns as soon as health answers" do
      assert :ok = API.await_health(endpoint(status(200, %{"ok" => true})), 1_000)
    end

    test "carries the last failure into the timeout, so the cause is not lost" do
      assert {:error, {:sandboxd, {:ready_timeout, {:sandboxd, :unauthorized}}}} =
               API.await_health(endpoint(status(401, "")), 150)
    end

    test "distinguishes a wrong token from a slow boot" do
      unauthorized = API.await_health(endpoint(status(401, "")), 150)

      refused =
        API.await_health(
          endpoint(fn req -> {req, %Req.TransportError{reason: :econnrefused}} end),
          150
        )

      refute unauthorized == refused
    end
  end

  describe "exec/4 staging (blocker: a CLI started before its config exists)" do
    test "an adapter that declares no sandbox files issues only the exec POST" do
      # Agent.ClaudeCode is the default resolution and defines no
      # sandbox_files/1, so the seam has to be entirely invisible to it.
      {endpoint, trace} = tracing_endpoint(fn _req -> {200, %{"ok" => true}} end)

      assert {:ok, %Sandboxd{}} =
               Sandboxd.exec(handle(endpoint: endpoint), "claude", [], %{})

      assert [{:post, "/v1/exec"}] = trace.()
    end

    test "every declared file is PUT before the exec POST, in declaration order" do
      {endpoint, trace} = tracing_endpoint(fn _req -> {200, %{"ok" => true}} end)
      handle = handle(endpoint: endpoint, config: [agent: __MODULE__.StagingAgent])

      assert {:ok, %Sandboxd{}} = Sandboxd.exec(handle, "cli", [], %{})

      assert [
               {:put, "/v1/files/etc/first.conf"},
               {:put, "/v1/files/etc/second.conf"},
               {:post, "/v1/exec"}
             ] = trace.()
    end

    test "a staging failure aborts exec/4 in the backend's own error vocabulary" do
      # Not logged-and-continued: a CLI launched without its config does not
      # fail, it quietly does the wrong thing. Session's exec_or_destroy/5 turns
      # this into a torn-down sandbox, which is the only safe outcome.
      {endpoint, trace} =
        tracing_endpoint(fn
          %{method: :put} -> {500, %{"error" => "write_failed"}}
          _req -> {200, %{"ok" => true}}
        end)

      handle = handle(endpoint: endpoint, config: [agent: __MODULE__.StagingAgent])

      assert {:error, {:sandboxd, {:http_status, 500, _}}} =
               Sandboxd.exec(handle, "cli", [], %{})

      # Halted on the first failure, and the CLI was never started.
      assert [{:put, "/v1/files/etc/first.conf"}] = trace.()
    end

    test "the not_provisioned guard still precedes staging" do
      handle = handle(endpoint: nil, config: [agent: __MODULE__.StagingAgent])

      assert {:error, {:sandboxd, :not_provisioned}} = Sandboxd.exec(handle, "cli", [], %{})
    end

    # Records {method, path} per request, so a test can assert on order rather
    # than only on the last request recording_endpoint/0 keeps.
    defp tracing_endpoint(responder) do
      {:ok, recorder} = Agent.start_link(fn -> [] end)

      adapter = fn req ->
        Agent.update(recorder, &(&1 ++ [{req.method, URI.parse(to_string(req.url)).path}]))
        {status, body} = responder.(req)
        {req, Req.Response.new(status: status, body: body)}
      end

      {endpoint(adapter), fn -> Agent.get(recorder, & &1) end}
    end
  end

  # --- Helpers ---

  # What Store would actually write. inspect/1 is useless for this: Endpoint's
  # Inspect implementation redacts the token, so an inspect-based check reports
  # "no secret" for a handle that carries one.
  defp persists?(term, secret) do
    :erlang.term_to_binary(term) |> :binary.match(secret) != :nomatch
  end

  defp handle(overrides \\ []) do
    defaults = [
      provider: __MODULE__.ScrubbingProvider,
      provider_handle: %{keep: 1},
      endpoint: endpoint(status(200, %{"ok" => true})),
      session_key: @session,
      owner: "node-a",
      config: []
    ]

    struct!(Sandboxd, Keyword.merge(defaults, overrides))
  end

  defp endpoint(adapter) do
    %Endpoint{
      base_url: "http://127.0.0.1:32768",
      token: @token,
      req_options: [adapter: adapter]
    }
  end

  defp status(code, body), do: fn req -> {req, Req.Response.new(status: code, body: body)} end

  defp recording_endpoint do
    {:ok, agent} = Agent.start_link(fn -> nil end)

    adapter = fn req ->
      Agent.update(agent, fn _ -> req end)
      {req, Req.Response.new(status: 200, body: %{"ok" => true})}
    end

    {endpoint(adapter), agent}
  end

  defmodule ScrubbingProvider do
    @moduledoc false
    @behaviour CrowdControl.Provider

    @impl true
    def acquire(_opts), do: {:error, :not_implemented}
    @impl true
    def reconnect(_handle), do: {:error, :not_implemented}
    @impl true
    def release(_handle), do: :ok
    @impl true
    def list_live(_opts), do: {:ok, []}
    @impl true
    def scrub(handle), do: Map.take(handle, [:keep])
  end

  defmodule ListingProvider do
    @moduledoc false
    @behaviour CrowdControl.Provider

    @impl true
    def acquire(_opts), do: {:error, :not_implemented}
    @impl true
    def reconnect(_handle), do: {:error, :not_implemented}
    @impl true
    def release(_handle), do: :ok

    @impl true
    def list_live(_opts) do
      {:ok, [%{session_key: "0123456789abcdef0123456789abcdef", owner: "node-a"}]}
    end
  end

  defmodule ReconnectingProvider do
    @moduledoc false
    @behaviour CrowdControl.Provider

    @impl true
    def acquire(_opts), do: {:error, :not_implemented}

    @impl true
    def reconnect(handle) do
      {:ok, handle,
       %CrowdControl.Provider.Endpoint{base_url: "http://127.0.0.1:49999", token: "fresh"}}
    end

    @impl true
    def release(_handle), do: :ok
    @impl true
    def list_live(_opts), do: {:ok, []}
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
    def list_live(_opts), do: {:error, :boom}
  end

  # A minimal CrowdControl.Agent that declares two sandbox files, so the seam is
  # tested without depending on Agent.Omp's rendering.
  defmodule StagingAgent do
    @moduledoc false
    @behaviour CrowdControl.Agent

    @impl true
    def build_command(_opts), do: {"cli", [], %{}}
    @impl true
    def init_frames(_opts), do: []
    @impl true
    def encode_prompt(prompt, _seq, _opts), do: prompt
    @impl true
    def decode_line(line), do: {:unknown, line}

    @impl true
    def sandbox_files(_opts) do
      [{"/etc/first.conf", "one", 0o600}, {"/etc/second.conf", "two", 0o640}]
    end
  end
end
