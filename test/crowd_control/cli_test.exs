defmodule CrowdControl.CLITest do
  use ExUnit.Case, async: true

  alias CrowdControl.CLI

  describe "build_command/1" do
    test "defaults to claude with base args" do
      {executable, args} = CLI.build_command()
      assert executable == "claude"
      assert "--print" in args
      assert "--verbose" in args
      assert args_contain_pair?(args, "--output-format", "stream-json")
      assert args_contain_pair?(args, "--input-format", "stream-json")
    end

    test "overrides executable" do
      {executable, _args} = CLI.build_command(executable: "open-code")
      assert executable == "open-code"
    end

    test "adds model flag" do
      {_exec, args} = CLI.build_command(model: "opus")
      assert args_contain_pair?(args, "--model", "opus")
    end

    test "adds system prompt" do
      {_exec, args} = CLI.build_command(system_prompt: "You are helpful")
      assert args_contain_pair?(args, "--system-prompt", "You are helpful")
    end

    test "adds allowed tools as comma-separated" do
      {_exec, args} = CLI.build_command(allowed_tools: ["Read", "Edit", "Bash"])
      assert args_contain_pair?(args, "--allowed-tools", "Read,Edit,Bash")
    end

    test "adds permission mode" do
      {_exec, args} = CLI.build_command(permission_mode: "bypassPermissions")
      assert args_contain_pair?(args, "--permission-mode", "bypassPermissions")
    end

    test "adds max budget" do
      {_exec, args} = CLI.build_command(max_budget_usd: 1.5)
      assert args_contain_pair?(args, "--max-budget-usd", "1.5")
    end

    test "adds boolean flags" do
      {_exec, args} = CLI.build_command(continue: true, include_partial_messages: true)
      assert "--continue" in args
      assert "--include-partial-messages" in args
    end

    test "skips false boolean flags" do
      {_exec, args} = CLI.build_command(continue: false)
      refute "--continue" in args
    end

    test "adds extra args" do
      {_exec, args} = CLI.build_command(extra_args: ["--dangerously-skip-permissions"])
      assert "--dangerously-skip-permissions" in args
    end

    test "combines multiple options" do
      {exec, args} =
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

  defp args_contain_pair?(args, flag, value) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> false
      idx -> Enum.at(args, idx + 1) == value
    end
  end
end
