defmodule CrowdControl.AgentTest do
  use ExUnit.Case, async: true

  doctest CrowdControl.Agent
  doctest CrowdControl.Agent.ClaudeCode

  alias CrowdControl.Agent
  alias CrowdControl.Agent.{ClaudeCode, Omp}

  describe "resolve/1" do
    test "defaults to Claude Code" do
      assert Agent.resolve([]) == ClaudeCode
    end

    test "resolves built-in aliases" do
      assert Agent.resolve(agent: :claude) == ClaudeCode
      assert Agent.resolve(agent: :claude_code) == ClaudeCode
      assert Agent.resolve(agent: :open_code) == ClaudeCode
      assert Agent.resolve(agent: :opencode) == ClaudeCode
      assert Agent.resolve(agent: :omp) == Omp
    end

    test "accepts a module implementing the behaviour" do
      assert Agent.resolve(agent: Omp) == Omp
    end

    test "infers omp from the executable basename" do
      assert Agent.resolve(executable: "omp") == Omp
      assert Agent.resolve(executable: "/opt/homebrew/bin/omp") == Omp
    end

    test "an unrecognized executable stays on Claude Code" do
      assert Agent.resolve(executable: "open-code") == ClaudeCode
      assert Agent.resolve(executable: "/usr/local/bin/claude") == ClaudeCode
    end

    test "explicit :agent wins over the executable" do
      assert Agent.resolve(agent: :claude, executable: "omp") == ClaudeCode
    end

    test "rejects an unknown atom rather than failing later inside init" do
      assert_raise ArgumentError, ~r/:agent must be one of/, fn ->
        Agent.resolve(agent: :codex)
      end
    end

    test "rejects a module that does not implement the behaviour" do
      assert_raise ArgumentError, ~r/:agent must be one of/, fn ->
        Agent.resolve(agent: CrowdControl.Store)
      end
    end

    test "rejects a non-atom" do
      assert_raise ArgumentError, ~r/:agent must be an atom or module/, fn ->
        Agent.resolve(agent: "omp")
      end
    end
  end

  describe "ClaudeCode adapter" do
    test "build_command/1 matches CrowdControl.CLI" do
      assert ClaudeCode.build_command(model: "opus") ==
               CrowdControl.CLI.build_command(model: "opus")
    end

    test "needs no handshake frames without control features" do
      assert ClaudeCode.init_frames([]) == []
      assert ClaudeCode.init_frames(model: "opus", permission_prompt_tool: "stdio") == []
      assert ClaudeCode.reattach_frames([]) == []
    end

    test "encode_prompt/3 ignores the sequence number" do
      assert ClaudeCode.encode_prompt("hi", 0, []) == ClaudeCode.encode_prompt("hi", 7, [])

      assert {:user, _} =
               ClaudeCode.decode_line(String.trim(ClaudeCode.encode_prompt("hi", 0, [])))
    end

    test ":oauth_token carries a Claude subscription via CLAUDE_CODE_OAUTH_TOKEN" do
      # `claude setup-token` mints this; it is the headless way to bill a
      # session to a Pro/Max/Team plan instead of an API key. A different
      # variable from omp's, which is why the adapters own the mapping.
      {_exe, args, env} = ClaudeCode.build_command(oauth_token: "sk-ant-oat-123")

      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat-123"
      refute Map.has_key?(env, "ANTHROPIC_API_KEY")
      refute Enum.any?(args, &String.contains?(&1, "sk-ant-oat-123"))
    end

    test "an explicit :env entry still wins over :oauth_token" do
      {_exe, _args, env} =
        ClaudeCode.build_command(
          oauth_token: "generated",
          env: %{"CLAUDE_CODE_OAUTH_TOKEN" => "caller-wins"}
        )

      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "caller-wins"
    end

    test "rejects a non-binary :oauth_token" do
      assert_raise ArgumentError, ~r/:oauth_token must be a binary/, fn ->
        ClaudeCode.build_command(oauth_token: :secret)
      end
    end

    test ":auth_token sends a bearer credential for a self-hosted endpoint" do
      # ANTHROPIC_AUTH_TOKEN => `Authorization: Bearer`, which is what a vLLM or
      # LiteLLM front end expects; :api_key would send `x-api-key` instead.
      {_exe, args, env} =
        ClaudeCode.build_command(auth_token: "vllm-secret", api_url: "http://10.0.0.5:8000")

      assert env["ANTHROPIC_AUTH_TOKEN"] == "vllm-secret"
      assert env["ANTHROPIC_BASE_URL"] == "http://10.0.0.5:8000"
      refute Enum.any?(args, &String.contains?(&1, "vllm-secret"))
    end

    test ":auth_token and :oauth_token are independent" do
      {_exe, _args, env} = ClaudeCode.build_command(auth_token: "bearer", oauth_token: "sub")

      assert env["ANTHROPIC_AUTH_TOKEN"] == "bearer"
      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "sub"
    end
  end

  describe "control seams" do
    @hooks %{
      "PreToolUse" => [
        %{matcher: "Bash", hooks: [{M, :pre_bash, []}, {M, :audit, [:x]}], timeout: 30},
        %{hooks: [{M, :any_tool, []}]}
      ],
      Stop: [%{hooks: [{M, :stop, []}]}]
    }

    @control_opts [
      can_use_tool: {M, :approve, []},
      hooks: @hooks,
      sdk_mcp_servers: %{"tools" => :spec, "app" => :spec}
    ]

    test "the same opts give a byte-identical initialize, also on reattach" do
      assert [frame] = ClaudeCode.init_frames(@control_opts)
      assert ClaudeCode.init_frames(Enum.reverse(@control_opts)) == [frame]
      assert ClaudeCode.reattach_frames(@control_opts) == [frame]
      assert Agent.reattach_frames(ClaudeCode, @control_opts) == [frame]
      assert String.ends_with?(frame, "\n")
    end

    test "initialize names the sdk servers and registers hooks under deterministic ids" do
      [frame] = ClaudeCode.init_frames(@control_opts)
      init_id = ClaudeCode.init_request_id()

      assert {:control_request, ^init_id, "initialize", request} =
               ClaudeCode.decode_line(String.trim(frame))

      assert request["sdkMcpServers"] == ["app", "tools"]

      assert request["hooks"] == %{
               "PreToolUse" => [
                 %{
                   "matcher" => "Bash",
                   "timeout" => 30,
                   "hookCallbackIds" => ["hook_PreToolUse_0_0", "hook_PreToolUse_0_1"]
                 },
                 %{"hookCallbackIds" => ["hook_PreToolUse_1_0"]}
               ],
               "Stop" => [%{"hookCallbackIds" => ["hook_Stop_0_0"]}]
             }
    end

    test "hook_callbacks/1 maps every registered id to its callback" do
      assert ClaudeCode.hook_callbacks(@control_opts) == %{
               "hook_PreToolUse_0_0" => {M, :pre_bash, []},
               "hook_PreToolUse_0_1" => {M, :audit, [:x]},
               "hook_PreToolUse_1_0" => {M, :any_tool, []},
               "hook_Stop_0_0" => {M, :stop, []}
             }
    end

    test "any one control option is enough for an initialize" do
      for opt <- @control_opts do
        assert [frame] = ClaudeCode.init_frames([opt])
        assert frame =~ ~s("subtype":"initialize")
      end

      [frame] = ClaudeCode.init_frames(can_use_tool: {M, :approve, []})
      {:control_request, _id, "initialize", request} = ClaudeCode.decode_line(frame)
      assert request == %{"subtype" => "initialize"}
    end

    test "malformed :hooks raise before anything starts" do
      for hooks <- [
            [{"PreToolUse", []}],
            %{"PreToolUse" => []},
            %{"Pre Tool" => [%{hooks: [{M, :f, []}]}]},
            %{"PreToolUse" => [%{matcher: "Bash"}]},
            %{"PreToolUse" => [%{hooks: [{M, :f, []}], timeout: "30"}]}
          ] do
        assert_raise ArgumentError, fn -> ClaudeCode.init_frames(hooks: hooks) end
      end
    end

    test "ClaudeCode declares every capability, omp none" do
      for capability <- [:control, :interrupt, :sdk_mcp] do
        assert Agent.capable?(ClaudeCode, capability)
        refute Agent.capable?(Omp, capability)
      end
    end

    test "omp writes nothing on reattach" do
      assert Agent.reattach_frames(Omp, @control_opts) == []
    end

    test "encode_control/2 frames requests, responses and permissions" do
      assert ClaudeCode.encode_control({:request, "req_1", %{"subtype" => "interrupt"}}, []) ==
               CrowdControl.Protocol.encode_control_request("req_1", %{"subtype" => "interrupt"})

      assert {:control_response, "a", {:error, "no"}, _} =
               ClaudeCode.decode_line(
                 ClaudeCode.encode_control({:response, "a", {:error, "no"}}, [])
               )

      assert {:control_response, "b", {:ok, %{"behavior" => "allow", "updatedInput" => %{}}}, _} =
               ClaudeCode.decode_line(
                 ClaudeCode.encode_control({:permission, "b", {:allow, %{}}}, [])
               )
    end

    test "omp refuses every control option" do
      for opt <- [
            can_use_tool: {M, :approve, []},
            hooks: @hooks,
            sdk_mcp_servers: %{"app" => :spec},
            permission_prompt_tool: "stdio",
            permission_prompts: "none"
          ] do
        assert_raise ArgumentError, ~r/no omp equivalent/, fn -> Omp.build_command([opt]) end
      end
    end

    test "omp keeps its own path-valued :hooks" do
      {_exe, args, _env} = Omp.build_command(hooks: "/hooks/a.ts")
      assert "--hook" in args
    end
  end
end
