defmodule CrowdControl.Agent.OmpRemoteConfigTest do
  @moduledoc """
  omp resolves a custom provider's `baseUrl` out of `models.yml` under its agent
  directory. There is no flag for it, so on a remote substrate the file has to
  exist on the *sandbox's* filesystem — a host temp directory is not visible
  there, and a session pointed at one talks to omp's default provider while
  looking configured.

  Hermetic: every agent call is answered by a stub adapter carried in the
  endpoint's `:req_options`, so no daemon, container or socket is involved. The
  one test that proves omp actually reads the file it is handed lives in
  `omp_provider_integration_test.exs` behind `@moduletag :omp`.
  """

  use ExUnit.Case, async: true

  alias CrowdControl.Agent.Omp
  alias CrowdControl.Backend.Sandboxd
  alias CrowdControl.Provider.Endpoint

  @default_dir "/tmp/cc-omp-agent"
  @token "a-derived-token"

  describe "the rendered config reaches the sandbox (blocker: a CLI configured against a host path it cannot see)" do
    test "models.yml is PUT at the documented in-sandbox path, mode 0600" do
      spec = [base_url: url()]
      {handle, requests} = staging_handle(custom_provider: spec, sandbox_agent_dir: true)

      assert {:ok, %Sandboxd{}} = Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})

      assert [put | _] = requests.()
      assert put.method == :put

      url = URI.parse(to_string(put.url))
      assert url.path == "/v1/files" <> @default_dir <> "/models.yml"
      assert url.query == "mode=0600"

      # The bytes, not a shape: this is the artifact omp parses, and it must be
      # what the local path would have written.
      assert put.body == Omp.render_models_config!(spec)
    end

    test "the file is staged before the exec, not after it" do
      # Ordering is the whole point. omp opens models.yml during startup, so a
      # PUT that lands after POST /v1/exec is a race the sandbox loses silently.
      {handle, requests} =
        staging_handle(custom_provider: [base_url: url()], sandbox_agent_dir: true)

      assert {:ok, %Sandboxd{}} = Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})

      assert [:put, :post] = Enum.map(requests.(), & &1.method)
    end

    test "an explicit in-sandbox directory replaces the default" do
      {handle, requests} =
        staging_handle(
          custom_provider: [base_url: url()],
          sandbox_agent_dir: "/var/lib/cc/omp-agent"
        )

      assert {:ok, %Sandboxd{}} = Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})

      assert [put | _] = requests.()
      assert URI.parse(to_string(put.url)).path == "/v1/files/var/lib/cc/omp-agent/models.yml"
    end

    test "the provider api_key rides the environment, never the pushed bytes" do
      key = "vllm-secret-#{System.unique_integer([:positive])}"
      opts = [custom_provider: [base_url: url(), api_key: key], sandbox_agent_dir: true]

      {handle, requests} = staging_handle(opts)
      assert {:ok, %Sandboxd{}} = Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})

      assert [put | _] = requests.()
      refute String.contains?(put.body, key)

      # ...and it is still delivered, through the same validated env channel as
      # every other credential.
      {_exe, args, env} = Omp.build_command(opts)
      assert env["OMP_CUSTOM_PROVIDER_KEY"] == key
      refute Enum.any?(args, &String.contains?(&1, key))
    end
  end

  describe "PI_CODING_AGENT_DIR (blocker: an env var pointing where nothing was written)" do
    test "points at the in-sandbox directory when the files are shipped" do
      {_exe, _args, env} =
        Omp.build_command(custom_provider: [base_url: url()], sandbox_agent_dir: true)

      # Also pins the default the moduledoc names. If this constant moves, the
      # documented path moves with it or the docs are wrong.
      assert env["PI_CODING_AGENT_DIR"] == @default_dir
    end

    test "agrees with the directory sandbox_files/1 writes into" do
      opts = [custom_provider: [base_url: url()], sandbox_agent_dir: "/opt/cc/agent"]

      {_exe, _args, env} = Omp.build_command(opts)
      assert [{path, _body, _mode}] = Omp.sandbox_files(opts)

      assert Path.dirname(path) == env["PI_CODING_AGENT_DIR"]
    end

    test "shipping renders nothing on the host at all" do
      spec = [base_url: url()]

      {_exe, _args, env} = Omp.build_command(custom_provider: spec, sandbox_agent_dir: true)
      assert env["PI_CODING_AGENT_DIR"] == @default_dir

      # The directory name is a digest of the rendered config, and this spec's
      # base_url is unique to this test, so no cc_omp_ directory anywhere can
      # hold these bytes unless provider_dir!/1 was called.
      config = Omp.render_models_config!(spec)

      refute Enum.any?(
               Path.wildcard(Path.join(System.tmp_dir!(), "cc_omp_*/models.yml")),
               &(File.read(&1) == {:ok, config})
             )
    end
  end

  describe "a traversal-shaped target is refused client-side (blocker: writing outside the sandbox's config dir)" do
    test "build_command/1 raises before Session.init/1 has provisioned anything" do
      # Refused here rather than at PUT time on purpose: Session.init/1 calls
      # build_command/1 before provision/1, so a bad path costs nothing. The
      # same option reaching exec/4 would already have been billed a sandbox.
      for bad <- ["/tmp/../etc", "/tmp/cc/./x", "tmp/relative", "/tmp/cc\0/x", ""] do
        assert_raise ArgumentError, ~r/:sandbox_agent_dir/, fn ->
          Omp.build_command(custom_provider: [base_url: url()], sandbox_agent_dir: bad)
        end
      end
    end

    test "no request is issued for a traversal path, even driving exec/4 directly" do
      {handle, requests} =
        staging_handle(custom_provider: [base_url: url()], sandbox_agent_dir: "/tmp/../etc")

      assert_raise ArgumentError, ~r/must not contain \. or \.\. segments/, fn ->
        Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})
      end

      assert requests.() == []
    end

    test "a non-path value is refused rather than coerced" do
      assert_raise ArgumentError, ~r/must be true or an absolute in-sandbox path/, fn ->
        Omp.build_command(custom_provider: [base_url: url()], sandbox_agent_dir: 42)
      end
    end
  end

  describe "a push failure is not a launch (blocker: a silently misconfigured CLI)" do
    test "exec/4 returns the tagged error and never issues the exec POST" do
      opts = [agent: :omp, custom_provider: [base_url: url()], sandbox_agent_dir: true]
      {:ok, recorder} = Agent.start_link(fn -> [] end)

      adapter = fn req ->
        Agent.update(recorder, &(&1 ++ [req]))

        response =
          case req.method do
            :put -> Req.Response.new(status: 500, body: %{"error" => "write_failed"})
            _ -> Req.Response.new(status: 200, body: %{"ok" => true})
          end

        {req, response}
      end

      handle = handle(adapter, opts)

      assert {:error, {:sandboxd, {:http_status, 500, _}}} =
               Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})

      assert [%{method: :put}] = Agent.get(recorder, & &1)
    end

    test "a transport failure surfaces with the same vocabulary" do
      opts = [agent: :omp, custom_provider: [base_url: url()], sandbox_agent_dir: true]
      handle = handle(fn req -> {req, %Req.TransportError{reason: :econnrefused}} end, opts)

      assert {:error, {:sandboxd, {:transport, :econnrefused}}} =
               Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})
    end

    test "an unprovisioned handle still fails closed, before anything is rendered" do
      opts = [agent: :omp, custom_provider: [base_url: url()], sandbox_agent_dir: true]

      handle = struct!(Sandboxd, endpoint: nil, config: opts)

      assert {:error, {:sandboxd, :not_provisioned}} =
               Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})
    end
  end

  describe "the local path is untouched (blocker: a remote feature that changes local behaviour)" do
    test "a local session renders the same bytes to the same private directory" do
      spec = [base_url: url()]

      {_exe, _args, env} = Omp.build_command(custom_provider: spec)
      dir = env["PI_CODING_AGENT_DIR"]
      on_exit(fn -> Omp.remove_provider_dir(dir) end)

      # Same content-addressed directory provider_dir!/1 would hand a caller who
      # wants to own the lifecycle, and the same 0700/0600 posture as before.
      assert dir == Omp.provider_dir!(spec)
      assert File.read!(Path.join(dir, "models.yml")) == Omp.render_models_config!(spec)
      assert {:ok, %File.Stat{mode: 0o40700}} = File.stat(dir)
      assert {:ok, %File.Stat{mode: 0o100600}} = File.stat(Path.join(dir, "models.yml"))
    end

    test "a local session declares no sandbox files, so nothing is staged for it" do
      assert Omp.sandbox_files(custom_provider: [base_url: url()]) == []
      assert Omp.sandbox_files([]) == []
      assert Omp.sandbox_files(agent_dir: "/mnt/omp-agent") == []
    end

    test "a local Backend.Sandboxd session with :agent_dir stages nothing either" do
      # :agent_dir names a directory the image or a mount already provides, which
      # is still the answer for Backend.Docker and Backend.Kubernetes. Nothing to
      # ship, so no PUT.
      {handle, requests} = staging_handle(agent_dir: "/mnt/omp-agent")

      assert {:ok, %Sandboxd{}} = Sandboxd.exec(handle, "omp", ["--mode", "rpc"], %{})
      assert [:post] = Enum.map(requests.(), & &1.method)
    end
  end

  describe "contradictory directory options are refused (blocker: two sources of truth for one path)" do
    test ":custom_provider and :agent_dir are still mutually exclusive" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        Omp.build_command(agent_dir: "/tmp/x", custom_provider: [base_url: url()])
      end
    end

    test ":custom_provider and :agent_dir stay exclusive with :sandbox_agent_dir in play" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        Omp.build_command(
          agent_dir: "/tmp/x",
          custom_provider: [base_url: url()],
          sandbox_agent_dir: true
        )
      end
    end

    test ":sandbox_agent_dir has nothing to ship on its own" do
      assert_raise ArgumentError, ~r/nothing to ship without :custom_provider/, fn ->
        Omp.build_command(sandbox_agent_dir: true)
      end

      assert_raise ArgumentError, ~r/nothing to ship without :custom_provider/, fn ->
        Omp.build_command(agent_dir: "/mnt/omp-agent", sandbox_agent_dir: "/mnt/omp-agent")
      end
    end

    test ":inherit_auth cannot cross into a sandbox" do
      # Refused, not dropped: a symlink to the host's agent.db resolves to
      # nothing in the sandbox, and shipping the bytes would hand a live
      # subscription credential to the untrusted code the sandbox contains.
      opts = [
        custom_provider: [base_url: url(), inherit_auth: true],
        sandbox_agent_dir: true
      ]

      assert_raise ArgumentError, ~r/:inherit_auth cannot cross into a sandbox/, fn ->
        Omp.build_command(opts)
      end

      assert_raise ArgumentError, ~r/:inherit_auth cannot cross into a sandbox/, fn ->
        Omp.sandbox_files(opts)
      end
    end
  end

  # --- Helpers ---

  # Unique per test, so the content-addressed host directory a spec would map to
  # can never be shared with another test in this or any other file.
  defp url, do: "http://10.9.9.#{System.unique_integer([:positive]) |> rem(250)}:8000/v1"

  # A handle whose every agent call is recorded and answered `200 {"ok": true}`.
  # `requests` is a zero-arity reader so a test can assert on order.
  defp staging_handle(opts) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    adapter = fn req ->
      Agent.update(recorder, &(&1 ++ [req]))
      {req, Req.Response.new(status: 200, body: %{"ok" => true})}
    end

    {handle(adapter, Keyword.put(opts, :agent, :omp)), fn -> Agent.get(recorder, & &1) end}
  end

  defp handle(adapter, config) do
    struct!(Sandboxd,
      endpoint: %Endpoint{
        base_url: "http://127.0.0.1:32768",
        token: @token,
        req_options: [adapter: adapter]
      },
      session_key: "0123456789abcdef0123456789abcdef",
      owner: "node-a",
      config: config
    )
  end
end
