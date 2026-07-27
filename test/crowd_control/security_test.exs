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

    test "carriage-return env value is rejected" do
      assert_raise ArgumentError, ~r/control char/, fn ->
        CLI.build_env(env: %{"K" => "v\rbad"})
      end
    end

    test "tab env value is rejected" do
      assert_raise ArgumentError, ~r/control char/, fn ->
        CLI.build_env(env: %{"K" => "v\tbad"})
      end
    end

    test "other ASCII control char (0x01) in env value is rejected" do
      assert_raise ArgumentError, ~r/control char/, fn ->
        CLI.build_env(env: %{"K" => <<"v", 0x01, "bad">>})
      end
    end

    test "ordinary printable env value is accepted" do
      assert %{"K" => "value-123_/.:"} = CLI.build_env(env: %{"K" => "value-123_/.:"})
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
          {"backslash", "back\\slash"},
          {"mixed metacharacters", ~s/'; $(id) `whoami` "q"/},
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
        TestHelpers.stop_session(pid)

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
      TestHelpers.stop_session(pid)
    end

    test "one byte over limit rejected" do
      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          max_prompt_size: 3,
          timeout: 10_000
        )

      assert {:error, :prompt_too_large} = Session.send_prompt(pid, "abcd")
      TestHelpers.stop_session(pid)
    end
  end

  describe "secret redaction" do
    test "a rejected env value is never echoed in the exception message" do
      # build_env/1 runs inside Session.init/1, so anything in this message ends
      # up in a GenServer crash report -- Logger, erl_crash.dump, Sentry.
      # Reading a key from a file leaves a trailing newline, which is enough to
      # reach this path.
      secret = "sk-ant-SUPERSECRETVALUE-DO-NOT-LOG\n"

      err = assert_raise ArgumentError, fn -> CLI.build_env(api_key: secret) end
      message = Exception.message(err)

      refute message =~ "SUPERSECRETVALUE",
             "exception leaked the secret: #{message}"

      assert message =~ "redacted"
      assert message =~ "ANTHROPIC_API_KEY"
    end

    test "a rejected :env value is never echoed either" do
      err =
        assert_raise ArgumentError, fn ->
          CLI.build_env(env: %{"TOKEN" => "tok-SUPERSECRETVALUE\0"})
        end

      refute Exception.message(err) =~ "SUPERSECRETVALUE"
      assert Exception.message(err) =~ ~r/null byte/
    end
  end

  describe "test oracle integrity" do
    test "an env value cannot execute commands inside fake_cli.sh" do
      # The oracle proves CrowdControl's escaping works, so it must not itself
      # be bypassable. `${!VAR}` was: bash evaluates array subscripts inside
      # indirect expansion arithmetically, so this value -- which passes
      # validate_env!/1 -- used to run `touch`.
      marker = Path.join(System.tmp_dir!(), "cc_injection_#{System.unique_integer([:positive])}")
      refute File.exists?(marker)

      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_cli_path(),
          env: %{"FAKE_CLI_ECHO_ENV" => "x[$(touch #{marker})]"},
          timeout: 5_000
        )

      Session.subscribe(pid)
      :ok = Session.send_prompt(pid, "hi")
      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 5_000
      TestHelpers.stop_session(pid)

      refute File.exists?(marker), "fake_cli.sh evaluated an env value as code"
    end
  end
end
