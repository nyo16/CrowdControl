defmodule CrowdControl.CLITest do
  use ExUnit.Case, async: true

  alias CrowdControl.Agent.ClaudeCode
  alias CrowdControl.CLI

  describe "build_command/1" do
    test "defaults to claude with base args and empty env" do
      {executable, args, env} = CLI.build_command()
      assert executable == "claude"
      assert "--print" in args
      assert "--verbose" in args
      assert args_contain_pair?(args, "--output-format", "stream-json")
      assert args_contain_pair?(args, "--input-format", "stream-json")
      assert env == %{}
    end

    test "overrides executable" do
      {executable, _args, _env} = CLI.build_command(executable: "open-code")
      assert executable == "open-code"
    end

    test "adds model flag" do
      {_exec, args, _env} = CLI.build_command(model: "opus")
      assert args_contain_pair?(args, "--model", "opus")
    end

    test "adds system prompt" do
      {_exec, args, _env} = CLI.build_command(system_prompt: "You are helpful")
      assert args_contain_pair?(args, "--system-prompt", "You are helpful")
    end

    test "adds allowed tools as comma-separated" do
      {_exec, args, _env} = CLI.build_command(allowed_tools: ["Read", "Edit", "Bash"])
      assert args_contain_pair?(args, "--allowed-tools", "Read,Edit,Bash")
    end

    test "adds permission mode" do
      {_exec, args, _env} = CLI.build_command(permission_mode: "bypassPermissions")
      assert args_contain_pair?(args, "--permission-mode", "bypassPermissions")
    end

    test "adds max budget" do
      {_exec, args, _env} = CLI.build_command(max_budget_usd: 1.5)
      assert args_contain_pair?(args, "--max-budget-usd", "1.5")
    end

    test "adds boolean flags" do
      {_exec, args, _env} = CLI.build_command(continue: true, include_partial_messages: true)
      assert "--continue" in args
      assert "--include-partial-messages" in args
    end

    test "skips false boolean flags" do
      {_exec, args, _env} = CLI.build_command(continue: false)
      refute "--continue" in args
    end

    test "expands and adds single add_dir" do
      {_exec, args, _env} = CLI.build_command(add_dir: "/path/to/project")
      assert args_contain_pair?(args, "--add-dir", "/path/to/project")
    end

    test "expands relative add_dir to absolute path" do
      {_exec, args, _env} = CLI.build_command(add_dir: "./relative")
      idx = Enum.find_index(args, &(&1 == "--add-dir"))
      assert Path.type(Enum.at(args, idx + 1)) == :absolute
    end

    test "adds multiple add_dirs as list" do
      {_exec, args, _env} = CLI.build_command(add_dir: ["/project/a", "/project/b", "/project/c"])
      idx = Enum.find_index(args, &(&1 == "--add-dir"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == "/project/a"
      assert Enum.at(args, idx + 2) == "/project/b"
      assert Enum.at(args, idx + 3) == "/project/c"
    end

    test "rejects add_dir with null bytes" do
      assert_raise ArgumentError, ~r/null byte/, fn ->
        CLI.build_command(add_dir: "/etc\0/passwd")
      end
    end

    test "rejects add_dir with control characters" do
      assert_raise ArgumentError, ~r/control/, fn ->
        CLI.build_command(add_dir: "/path\nwith-newline")
      end
    end

    test "adds extra args" do
      {_exec, args, _env} = CLI.build_command(extra_args: ["--dangerously-skip-permissions"])
      assert "--dangerously-skip-permissions" in args
    end

    test "rejects extra_args with control characters" do
      assert_raise ArgumentError, ~r/control/, fn ->
        CLI.build_command(extra_args: ["--ok", "--bad\n--injected"])
      end
    end

    test "combines multiple options" do
      {exec, args, _env} =
        CLI.build_command(
          executable: "/usr/local/bin/claude",
          model: "sonnet",
          permission_mode: "bypassPermissions",
          max_budget_usd: 2.0,
          continue: true
        )

      assert exec == "/usr/local/bin/claude"
      assert args_contain_pair?(args, "--model", "sonnet")
      assert args_contain_pair?(args, "--permission-mode", "bypassPermissions")
      assert args_contain_pair?(args, "--max-budget-usd", "2.0")
      assert "--continue" in args
    end
  end

  describe "settings options" do
    test "settings_file expands path" do
      {_exec, args, _env} = CLI.build_command(settings_file: "/config/settings.json")
      assert args_contain_pair?(args, "--settings", "/config/settings.json")
    end

    test "settings_file rejects null bytes" do
      assert_raise ArgumentError, fn ->
        CLI.build_command(settings_file: "/etc\0/passwd")
      end
    end

    test "settings_json passes inline JSON through" do
      json = ~s({"permissions":{"allow":["Read"]}})
      {_exec, args, _env} = CLI.build_command(settings_json: json)
      assert args_contain_pair?(args, "--settings", json)
    end

    test "settings_json encodes a map" do
      {_exec, args, _env} = CLI.build_command(settings_json: %{"foo" => "bar"})
      idx = Enum.find_index(args, &(&1 == "--settings"))
      assert JSON.decode!(Enum.at(args, idx + 1)) == %{"foo" => "bar"}
    end

    test "settings_json rejects invalid JSON" do
      assert_raise ArgumentError, ~r/invalid :settings_json/, fn ->
        CLI.build_command(settings_json: "{not json")
      end
    end

    test "deprecated :settings string starting with { is treated as JSON" do
      json = ~s({"permissions":{"allow":["Read"]}})
      {_exec, args, _env} = CLI.build_command(settings: json)
      assert args_contain_pair?(args, "--settings", json)
    end

    test "deprecated :settings non-brace string is treated as path" do
      {_exec, args, _env} = CLI.build_command(settings: "/config/settings.json")
      assert args_contain_pair?(args, "--settings", "/config/settings.json")
    end
  end

  describe "mcp/agents/plugin options" do
    test "adds setting sources" do
      {_exec, args, _env} = CLI.build_command(setting_sources: ["user", "project"])
      assert args_contain_pair?(args, "--setting-sources", "user,project")
    end

    test "adds single mcp config" do
      {_exec, args, _env} = CLI.build_command(mcp_config: "/config/mcp.json")
      assert args_contain_pair?(args, "--mcp-config", "/config/mcp.json")
    end

    test "rejects mcp_config with null bytes" do
      assert_raise ArgumentError, fn ->
        CLI.build_command(mcp_config: "/etc\0/passwd")
      end
    end

    test "adds multiple mcp configs" do
      {_exec, args, _env} = CLI.build_command(mcp_config: ["/config/a.json", "/config/b.json"])
      idx = Enum.find_index(args, &(&1 == "--mcp-config"))
      assert Enum.at(args, idx + 1) == "/config/a.json"
      assert Enum.at(args, idx + 2) == "/config/b.json"
    end

    test "adds strict mcp config flag" do
      {_exec, args, _env} = CLI.build_command(strict_mcp_config: true)
      assert "--strict-mcp-config" in args
    end

    test "adds agents as JSON string" do
      json = ~s({"reviewer":{"description":"Reviews code","prompt":"Review it"}})
      {_exec, args, _env} = CLI.build_command(agents: json)
      assert args_contain_pair?(args, "--agents", json)
    end

    test "adds agents as map (encodes to JSON)" do
      agents = %{"reviewer" => %{"description" => "Reviews code", "prompt" => "Review it"}}
      {_exec, args, _env} = CLI.build_command(agents: agents)
      idx = Enum.find_index(args, &(&1 == "--agents"))
      decoded = JSON.decode!(Enum.at(args, idx + 1))
      assert decoded["reviewer"]["description"] == "Reviews code"
    end

    test "expands plugin dir" do
      {_exec, args, _env} = CLI.build_command(plugin_dir: "/plugins")
      assert args_contain_pair?(args, "--plugin-dir", "/plugins")
    end

    test "rejects plugin_dir control characters" do
      assert_raise ArgumentError, fn ->
        CLI.build_command(plugin_dir: "/etc\n/foo")
      end
    end

    test "adds bare flag" do
      {_exec, args, _env} = CLI.build_command(bare: true)
      assert "--bare" in args
    end
  end

  describe "inline :mcp_config" do
    @sdk %{"mcpServers" => %{"app" => %{"type" => "sdk", "name" => "app"}}}

    test "an inline map becomes one JSON argv token" do
      {_exec, args, _env} = CLI.build_command(mcp_config: @sdk)
      idx = Enum.find_index(args, &(&1 == "--mcp-config"))
      assert JSON.decode!(Enum.at(args, idx + 1)) == @sdk
      assert length(args) == idx + 2
    end

    test "maps and paths can be mixed, in order, after one flag" do
      {_exec, args, _env} = CLI.build_command(mcp_config: ["/config/a.json", @sdk, "b.json"])
      idx = Enum.find_index(args, &(&1 == "--mcp-config"))
      assert [path_a, json, path_b] = Enum.slice(args, (idx + 1)..(idx + 3))
      assert path_a == "/config/a.json"
      assert JSON.decode!(json) == @sdk
      assert path_b == Path.expand("b.json")
      assert Enum.count(args, &(&1 == "--mcp-config")) == 1
    end

    test "a map is not treated as a path, so its JSON is not expanded" do
      {_exec, args, _env} = CLI.build_command(mcp_config: @sdk)
      refute Enum.any?(args, &String.starts_with?(&1, File.cwd!()))
    end

    test "atom keys are accepted" do
      config = %{mcpServers: %{web: %{type: "http", url: "http://browser:8931/mcp"}}}
      {_exec, args, _env} = CLI.build_command(mcp_config: config)

      assert %{"mcpServers" => %{"web" => %{"type" => "http"}}} =
               JSON.decode!(List.last(args))
    end

    test "a server without a type raises, naming it" do
      config = %{"mcpServers" => %{"web" => %{"url" => "http://browser:8931/mcp"}}}

      assert_raise ArgumentError, ~r/"web".*no "type"/, fn ->
        CLI.build_command(mcp_config: ["/config/a.json", config])
      end
    end

    test "a map without mcpServers raises" do
      assert_raise ArgumentError, ~r/mcpServers/, fn ->
        CLI.build_command(mcp_config: %{"app" => %{"type" => "sdk"}})
      end
    end

    test "an entry that is neither a path nor a map raises" do
      assert_raise ArgumentError, ~r/paths or maps/, fn ->
        CLI.build_command(mcp_config: [:nope])
      end
    end
  end

  describe "permission prompt options" do
    test "adds --permission-prompt-tool" do
      {_exec, args, _env} = CLI.build_command(permission_prompt_tool: "stdio")
      assert args_contain_pair?(args, "--permission-prompt-tool", "stdio")
    end

    test "rejects a control character in the prompt tool name" do
      assert_raise ArgumentError, fn ->
        CLI.build_command(permission_prompt_tool: "mcp__x\n--bare")
      end
    end

    test "adds --permission-prompts host or none" do
      for value <- ["host", "none"] do
        {_exec, args, _env} = CLI.build_command(permission_prompts: value)
        assert args_contain_pair?(args, "--permission-prompts", value)
      end
    end

    test "rejects any other --permission-prompts value" do
      assert_raise ArgumentError, ~r/permission_prompts/, fn ->
        CLI.build_command(permission_prompts: "ask")
      end
    end

    test ":can_use_tool sets the stdio prompt tool" do
      {_exec, args, _env} = ClaudeCode.build_command(can_use_tool: {M, :f, []})
      assert args_contain_pair?(args, "--permission-prompt-tool", "stdio")
      assert Enum.count(args, &(&1 == "--permission-prompt-tool")) == 1
    end

    test ":can_use_tool with an explicit stdio prompt tool is fine" do
      {_exec, args, _env} =
        ClaudeCode.build_command(can_use_tool: {M, :f, []}, permission_prompt_tool: "stdio")

      assert args_contain_pair?(args, "--permission-prompt-tool", "stdio")
    end

    test ":can_use_tool with a named prompt tool raises" do
      assert_raise ArgumentError, ~r/cannot be combined/, fn ->
        ClaudeCode.build_command(
          can_use_tool: {M, :f, []},
          permission_prompt_tool: "mcp__approver__ask"
        )
      end
    end

    test "a named prompt tool alone passes through" do
      {_exec, args, _env} = ClaudeCode.build_command(permission_prompt_tool: "mcp__approver__ask")
      assert args_contain_pair?(args, "--permission-prompt-tool", "mcp__approver__ask")
    end
  end

  describe ":sdk_mcp_servers" do
    test "adds an inline sdk entry per server after the caller's configs" do
      {_exec, args, _env} =
        ClaudeCode.build_command(
          mcp_config: "/config/a.json",
          sdk_mcp_servers: %{"tools" => :spec, "app" => :spec}
        )

      idx = Enum.find_index(args, &(&1 == "--mcp-config"))
      assert Enum.at(args, idx + 1) == "/config/a.json"

      assert JSON.decode!(Enum.at(args, idx + 2)) == %{
               "mcpServers" => %{
                 "app" => %{"type" => "sdk", "name" => "app"},
                 "tools" => %{"type" => "sdk", "name" => "tools"}
               }
             }
    end

    test "rejects a server name that is not a plain binary" do
      assert_raise ArgumentError, ~r/sdk_mcp_servers/, fn ->
        ClaudeCode.build_command(sdk_mcp_servers: %{app: :spec})
      end

      assert_raise ArgumentError, ~r/sdk_mcp_servers/, fn ->
        ClaudeCode.build_command(sdk_mcp_servers: %{"a b" => :spec})
      end
    end
  end

  describe "turn and prompt options" do
    test "emit one token per value" do
      {_exec, args, _env} =
        CLI.build_command(
          disallowed_tools: ["Bash(rm:*)", "WebFetch"],
          append_system_prompt: "Be terse.",
          max_turns: 4,
          effort: "xhigh",
          fallback_model: "sonnet",
          resume: "sess-1",
          fork_session: true,
          exclude_dynamic_system_prompt_sections: true
        )

      assert args_contain_pair?(args, "--disallowed-tools", "Bash(rm:*),WebFetch")
      assert args_contain_pair?(args, "--append-system-prompt", "Be terse.")
      assert args_contain_pair?(args, "--max-turns", "4")
      assert args_contain_pair?(args, "--effort", "xhigh")
      assert args_contain_pair?(args, "--fallback-model", "sonnet")
      assert "--fork-session" in args
      assert "--exclude-dynamic-system-prompt-sections" in args
    end

    test ":effort accepts each level as an atom and rejects anything else" do
      for level <- [:low, :medium, :high, :xhigh, :max] do
        {_exec, args, _env} = CLI.build_command(effort: level)
        assert args_contain_pair?(args, "--effort", Atom.to_string(level))
      end

      for bad <- ["extreme", :ultra, 3] do
        assert_raise ArgumentError, ~r/:effort must be one of/, fn ->
          CLI.build_command(effort: bad)
        end
      end
    end

    test ":max_turns must be a positive integer" do
      for bad <- [0, -1, 1.5, "3"] do
        assert_raise ArgumentError, ~r/:max_turns/, fn -> CLI.build_command(max_turns: bad) end
      end
    end

    test ":fork_session needs :resume or :continue" do
      assert_raise ArgumentError, ~r/needs :resume or :continue/, fn ->
        CLI.build_command(fork_session: true)
      end

      {_exec, args, _env} = CLI.build_command(continue: true, fork_session: true)
      assert "--fork-session" in args

      {_exec, args, _env} = CLI.build_command(fork_session: false)
      refute "--fork-session" in args
    end

    test ":json_schema takes a map or a JSON object string" do
      schema = %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}}

      {_exec, args, _env} = CLI.build_command(json_schema: schema)
      assert JSON.decode!(value_after(args, "--json-schema")) == schema

      text = ~s({"type": "object"})
      {_exec, args, _env} = CLI.build_command(json_schema: text)
      assert args_contain_pair?(args, "--json-schema", text)

      for bad <- ["not json", "[1, 2]", ~s("object"), 42] do
        assert_raise ArgumentError, ~r/:json_schema must be/, fn ->
          CLI.build_command(json_schema: bad)
        end
      end
    end
  end

  describe "ClaudeCode :hermetic" do
    test ":full drops every settings source, strict MCP, no dynamic sections, no auto-memory" do
      {_exec, args, env} = ClaudeCode.build_command(hermetic: :full)

      # An empty argv token, not a missing one: the CLI reads the next flag
      # as the value otherwise.
      assert args_contain_pair?(args, "--setting-sources", "")
      assert "--strict-mcp-config" in args
      assert "--exclude-dynamic-system-prompt-sections" in args
      refute "--bare" in args
      assert env == %{"CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1"}
    end

    test ":project keeps user settings only" do
      {_exec, args, _env} = ClaudeCode.build_command(hermetic: :project)
      assert args_contain_pair?(args, "--setting-sources", "user")
    end

    test "the caller's :setting_sources and :env win" do
      {_exec, args, env} =
        ClaudeCode.build_command(
          hermetic: :full,
          setting_sources: ["user", "project"],
          env: %{"CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "0", "OTHER" => "x"}
        )

      assert args_contain_pair?(args, "--setting-sources", "user,project")
      assert env == %{"CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "0", "OTHER" => "x"}
    end

    test "false is off and an unknown scope raises" do
      assert ClaudeCode.build_command(hermetic: false) == ClaudeCode.build_command([])

      assert_raise ArgumentError, ~r/:hermetic must be :full or :project/, fn ->
        ClaudeCode.build_command(hermetic: true)
      end
    end
  end

  describe "contract_flags/0" do
    test "covers every flag build_command/1 can emit" do
      {_exec, args, _env} =
        ClaudeCode.build_command(
          model: "m",
          system_prompt: "s",
          allowed_tools: ["Read"],
          disallowed_tools: ["Bash(rm:*)"],
          append_system_prompt: "a",
          max_turns: 3,
          effort: :high,
          fallback_model: "haiku",
          json_schema: %{"type" => "object"},
          fork_session: true,
          exclude_dynamic_system_prompt_sections: true,
          permission_mode: "plan",
          permission_prompts: "none",
          can_use_tool: {M, :f, []},
          max_budget_usd: 1,
          session_id: "id",
          resume: "id",
          add_dir: "/d",
          settings_file: "/s.json",
          setting_sources: ["user"],
          sdk_mcp_servers: %{"app" => :spec},
          agents: %{},
          plugin_dir: "/p",
          continue: true,
          include_partial_messages: true,
          no_session_persistence: true,
          strict_mcp_config: true,
          bare: true
        )

      emitted = args |> Enum.filter(&String.starts_with?(&1, "--")) |> MapSet.new()
      table = CLI.contract_flags() |> Enum.map(& &1.flag) |> MapSet.new()

      assert MapSet.subset?(emitted, table), inspect(MapSet.difference(emitted, table))
      assert MapSet.equal?(emitted, table), inspect(MapSet.difference(table, emitted))
    end
  end

  describe "build_env/1" do
    test "returns empty map with no env options" do
      assert CLI.build_env([]) == %{}
    end

    test "sets api_key as ANTHROPIC_API_KEY" do
      env = CLI.build_env(api_key: "sk-test-123")
      assert env["ANTHROPIC_API_KEY"] == "sk-test-123"
    end

    test "sets api_url as ANTHROPIC_BASE_URL" do
      env = CLI.build_env(api_url: "https://custom.api.example.com")
      assert env["ANTHROPIC_BASE_URL"] == "https://custom.api.example.com"
    end

    test "combines api_key and api_url" do
      env = CLI.build_env(api_key: "sk-key", api_url: "https://api.example.com")
      assert env["ANTHROPIC_API_KEY"] == "sk-key"
      assert env["ANTHROPIC_BASE_URL"] == "https://api.example.com"
    end

    test "merges custom env map" do
      env = CLI.build_env(env: %{"MY_VAR" => "hello", "OTHER" => "world"})
      assert env["MY_VAR"] == "hello"
      assert env["OTHER"] == "world"
    end

    test "custom env overrides shorthands" do
      env =
        CLI.build_env(
          api_key: "shorthand-key",
          env: %{"ANTHROPIC_API_KEY" => "explicit-key"}
        )

      assert env["ANTHROPIC_API_KEY"] == "explicit-key"
    end

    test "build_command includes env" do
      {_exec, _args, env} =
        CLI.build_command(
          api_key: "sk-test",
          api_url: "https://custom.api.com",
          env: %{"EXTRA" => "val"}
        )

      assert env["ANTHROPIC_API_KEY"] == "sk-test"
      assert env["ANTHROPIC_BASE_URL"] == "https://custom.api.com"
      assert env["EXTRA"] == "val"
    end

    test "rejects env key with newline (shell injection attempt)" do
      assert_raise ArgumentError, ~r/env key must match/, fn ->
        CLI.build_env(env: %{"FOO\nexport PATH=/evil" => "x"})
      end
    end

    test "rejects env key with equals sign" do
      assert_raise ArgumentError, ~r/env key must match/, fn ->
        CLI.build_env(env: %{"FOO=BAR" => "x"})
      end
    end

    test "rejects env key starting with digit" do
      assert_raise ArgumentError, ~r/env key must match/, fn ->
        CLI.build_env(env: %{"1FOO" => "x"})
      end
    end

    test "rejects env value with null byte" do
      assert_raise ArgumentError, ~r/null byte/, fn ->
        CLI.build_env(env: %{"K" => "v\0"})
      end
    end

    test "rejects env value with newline" do
      # Newline is an ASCII control char; env values now reject the whole
      # 0x00–0x1f range via the shared validator (consistent with path opts).
      assert_raise ArgumentError, ~r/control char/, fn ->
        CLI.build_env(env: %{"K" => "v\nbad"})
      end
    end

    test "rejects non-binary env value" do
      assert_raise ArgumentError, ~r/must be a binary/, fn ->
        CLI.build_env(env: %{"K" => 123})
      end
    end

    test "rejects non-binary api_key" do
      assert_raise ArgumentError, ~r/api_key must be a binary/, fn ->
        CLI.build_env(api_key: :secret)
      end
    end
  end

  describe "sanitize_path!/1" do
    test "expands relative paths" do
      assert Path.type(CLI.sanitize_path!("./foo")) == :absolute
    end

    test "preserves absolute paths" do
      assert CLI.sanitize_path!("/usr/local/bin") == "/usr/local/bin"
    end

    test "raises on null bytes" do
      assert_raise ArgumentError, fn -> CLI.sanitize_path!("/foo\0bar") end
    end

    test "raises on control characters" do
      assert_raise ArgumentError, fn -> CLI.sanitize_path!("/foo\tbar") end
    end

    test "raises on non-binary" do
      assert_raise ArgumentError, fn -> CLI.sanitize_path!(:atom) end
    end
  end

  defp value_after(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)

  defp args_contain_pair?(args, flag, value) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> false
      idx -> Enum.at(args, idx + 1) == value
    end
  end
end
