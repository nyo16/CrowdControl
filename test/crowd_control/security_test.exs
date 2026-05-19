defmodule CrowdControl.SecurityTest do
  use ExUnit.Case, async: true

  alias CrowdControl.{CLI, Session, TestHelpers}

  describe "env injection attempts" do
    test "newline-injected env key is rejected before write" do
      assert_raise ArgumentError, fn ->
        CLI.build_env(env: %{"GOOD\nexport PATH=/evil" => "x"})
      end
    end

    test "equals-injected env key is rejected" do
      assert_raise ArgumentError, fn ->
        CLI.build_env(env: %{"K=V" => "x"})
      end
    end

    test "null-byte env value is rejected" do
      assert_raise ArgumentError, fn ->
        CLI.build_env(env: %{"K" => <<"v", 0, "rest">>})
      end
    end

    test "newline env value is rejected" do
      assert_raise ArgumentError, fn ->
        CLI.build_env(env: %{"K" => "v\nbad"})
      end
    end
  end

  describe "path traversal attempts on argv-bound options" do
    test "add_dir with null byte is rejected" do
      assert_raise ArgumentError, fn -> CLI.build_command(add_dir: "/etc\0/passwd") end
    end

    test "add_dir list with one bad entry rejects the whole list" do
      assert_raise ArgumentError, fn ->
        CLI.build_command(add_dir: ["/ok", "/bad\nentry"])
      end
    end

    test "mcp_config rejects control characters" do
      assert_raise ArgumentError, fn ->
        CLI.build_command(mcp_config: "/path\twith-tab")
      end
    end

    test "plugin_dir rejects null bytes" do
      assert_raise ArgumentError, fn -> CLI.build_command(plugin_dir: "/a\0b") end
    end
  end

  describe "shell escaping (observable via env-file passthrough)" do
    for {name, raw} <- [
          {"single quote", "O'Brien"},
          {"double quote", ~s(say "hi")},
          {"backticks", "value `id`"},
          {"command substitution", "value $(echo pwned)"},
          {"semicolon chain", "value; echo pwned"},
          {"ampersand chain", "value && echo pwned"},
          {"dollar var", "value $HOME"},
          {"unicode", "café-✓"}
        ] do
      @raw raw
      @name name

      test "env value with #{@name} round-trips intact through the env-file sourcing" do
        marker = "MARKER_#{System.unique_integer([:positive])}"

        {:ok, pid} =
          Session.start_link(
            executable: TestHelpers.fake_cli_path(),
            env: %{"FAKE_CLI_ECHO_ENV" => marker, marker => @raw},
            timeout: 10_000
          )

        Session.subscribe(pid)
        :ok = Session.send_prompt(pid, "x")

        assert_receive {:crowd_control, ^pid, {:result, "success", %{"result" => result}}}, 5_000
        Session.stop(pid)

        assert result == "#{marker}=#{@raw}",
               "shell escape regressed for #{@name}: got #{inspect(result)}"
      end
    end
  end

  describe "prompt boundary" do
    test "exactly at byte limit accepted" do
      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          max_prompt_size: 3,
          timeout: 10_000
        )

      Session.subscribe(pid)
      assert :ok = Session.send_prompt(pid, "abc")
      Session.stop(pid)
    end

    test "one byte over limit rejected" do
      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          max_prompt_size: 3,
          timeout: 10_000
        )

      assert {:error, :prompt_too_large} = Session.send_prompt(pid, "abcd")
      Session.stop(pid)
    end
  end
end
