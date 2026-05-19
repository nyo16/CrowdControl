defmodule CrowdControl.CLITest do
  use ExUnit.Case, async: true

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
      assert_raise ArgumentError, ~r/newline/, fn ->
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

  defp args_contain_pair?(args, flag, value) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> false
      idx -> Enum.at(args, idx + 1) == value
    end
  end
end
