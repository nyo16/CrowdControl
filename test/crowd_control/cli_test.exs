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

    test "adds extra args" do
      {_exec, args, _env} = CLI.build_command(extra_args: ["--dangerously-skip-permissions"])
      assert "--dangerously-skip-permissions" in args
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
  end

  defp args_contain_pair?(args, flag, value) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> false
      idx -> Enum.at(args, idx + 1) == value
    end
  end
end
