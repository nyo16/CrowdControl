defmodule CrowdControl.Agent.OmpTest do
  use ExUnit.Case, async: true

  alias CrowdControl.Agent.Omp

  defp args(opts), do: elem(Omp.build_command(opts), 1)

  defp flag_value(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  defp decode(map), do: map |> JSON.encode!() |> Omp.decode_line()

  describe "build_command/1" do
    test "defaults to the omp executable in rpc mode" do
      assert {"omp", ["--mode", "rpc" | _], %{}} = Omp.build_command()
    end

    test "honors an explicit executable" do
      assert {"/opt/homebrew/bin/omp", _, _} =
               Omp.build_command(executable: "/opt/homebrew/bin/omp")
    end

    test "maps shared options onto omp flags" do
      args = args(model: "opus", system_prompt: "be terse", allowed_tools: ["read", "edit"])

      assert flag_value(args, "--model") == "opus"
      assert flag_value(args, "--system-prompt") == "be terse"
      assert flag_value(args, "--tools") == "read,edit"
    end

    test "translates Claude Code permission modes to approval modes" do
      assert flag_value(args(permission_mode: "bypassPermissions"), "--approval-mode") == "yolo"
      assert flag_value(args(permission_mode: "acceptEdits"), "--approval-mode") == "write"
      assert flag_value(args(permission_mode: "default"), "--approval-mode") == "always-ask"
    end

    test "an omp-native approval mode wins over the Claude spelling" do
      args = args(permission_mode: "bypassPermissions", approval_mode: "write")
      assert flag_value(args, "--approval-mode") == "write"
    end

    test "rejects permission modes with no approval-mode equivalent" do
      assert_raise ArgumentError, ~r/no omp approval-mode equivalent/, fn ->
        args(permission_mode: "plan")
      end
    end

    test "rejects an invalid approval mode" do
      assert_raise ArgumentError, ~r/:approval_mode must be one of/, fn ->
        args(approval_mode: "yolo-plus")
      end
    end

    test "rejects an invalid thinking level" do
      assert_raise ArgumentError, ~r/:thinking must be one of/, fn ->
        args(thinking: "ludicrous")
      end
    end

    test "repeats --add-dir once per directory and expands paths" do
      args = args(add_dir: ["/project/a", "/project/b"])

      assert Enum.count(args, &(&1 == "--add-dir")) == 2
      assert "/project/a" in args and "/project/b" in args
    end

    test "expands relative paths" do
      assert args(cwd: "./rel") |> flag_value("--cwd") == Path.expand("./rel")
    end

    test "boolean flags take no value" do
      args = args(continue: true, no_session_persistence: true, no_lsp: true)

      assert "--continue" in args
      assert "--no-session" in args
      assert "--no-lsp" in args
      refute "--auto-approve" in args
    end

    test "false booleans are omitted" do
      refute "--continue" in args(continue: false)
    end

    test "extra_args are appended verbatim" do
      assert "--plan-yolo" in args(extra_args: ["--plan-yolo"])
    end

    test "rejects control characters in argv values" do
      assert_raise ArgumentError, ~r/control character/, fn -> args(model: "opus\ninjected") end
      assert_raise ArgumentError, ~r/control character/, fn -> args(extra_args: ["a\nb"]) end
      assert_raise ArgumentError, fn -> args(cwd: "/etc\0/passwd") end
    end

    test "rejects Claude-Code-only options instead of dropping them" do
      for {key, value} <- [
            mcp_config: "/tmp/mcp.json",
            strict_mcp_config: true,
            agents: %{"a" => %{}},
            plugin_dir: "/tmp/plugins",
            settings_file: "/tmp/settings.json",
            settings_json: "{}",
            setting_sources: ["user"],
            max_budget_usd: 1.5,
            session_id: "abc",
            bare: true
          ] do
        assert_raise ArgumentError, ~r/no omp equivalent/, fn -> args([{key, value}]) end
      end
    end

    test "an explicitly-false Claude-only flag is treated as absent, not rejected" do
      # `bare: false` asks for omp's default behaviour, so dropping it changes
      # nothing. Raising would break a shared option list driving a mixed
      # claude+omp fan-out.
      assert ["--mode", "rpc"] = args(bare: false, strict_mcp_config: false)
    end

    test "an invalid :streaming_behavior is rejected at build time, not at prompt time" do
      # encode_prompt/3 runs inside Session.init/1 and handle_call/3, where a
      # raise takes down the session and the caller instead of returning an error.
      assert_raise ArgumentError, ~r/:streaming_behavior must be one of/, fn ->
        args(streaming_behavior: "nope")
      end
    end

    test "builds env through the shared, validated builder" do
      {_exec, _args, env} = Omp.build_command(api_key: "sk-test", env: %{"FOO" => "bar"})

      assert env == %{"ANTHROPIC_API_KEY" => "sk-test", "FOO" => "bar"}
    end

    test "the api key never reaches argv" do
      # Backends splice argv into an `sh -c` string; a key there is readable
      # via `ps`. The env-file / exec-Env path is the only sanctioned channel.
      {_exec, args, _env} = Omp.build_command(api_key: "sk-test-SECRET")

      refute Enum.any?(args, &String.contains?(&1, "sk-test-SECRET"))
    end
  end

  describe "init_frames/1" do
    test "asks for the session state so a session id is observable" do
      assert [frame] = Omp.init_frames([])
      assert String.ends_with?(frame, "\n")

      assert %{"type" => "get_state", "id" => "cc-init"} = JSON.decode!(frame)
    end
  end

  describe "encode_prompt/3" do
    test "emits a prompt command with a sequence-derived id" do
      frame = Omp.encode_prompt("hello", 3, [])

      assert %{
               "id" => "cc-prompt-3",
               "type" => "prompt",
               "message" => "hello",
               "streamingBehavior" => "followUp"
             } = JSON.decode!(frame)

      assert String.ends_with?(frame, "\n")
    end

    test "steering can be selected per session" do
      frame = Omp.encode_prompt("hello", 0, streaming_behavior: "steer")
      assert %{"streamingBehavior" => "steer"} = JSON.decode!(frame)
    end

    test "rejects an unknown streaming behavior" do
      assert_raise ArgumentError, ~r/:streaming_behavior must be one of/, fn ->
        Omp.encode_prompt("hello", 0, streaming_behavior: "interrupt")
      end
    end
  end

  describe "decode_line/1" do
    test "a get_state response becomes a Claude-shaped system init" do
      assert {:system_init, init} =
               decode(%{
                 "type" => "response",
                 "command" => "get_state",
                 "success" => true,
                 "data" => %{
                   "sessionId" => "abc-123",
                   "sessionFile" => "/tmp/abc.jsonl",
                   "model" => %{"id" => "claude-opus-5", "provider" => "anthropic"},
                   "dumpTools" => [%{"name" => "read"}, %{"name" => "write"}]
                 }
               })

      assert init["session_id"] == "abc-123"
      assert init["type"] == "system"
      assert init["subtype"] == "init"
      assert init["model"] == "claude-opus-5"
      assert init["tools"] == ["read", "write"]
    end

    test "a terminal agent_end becomes a result carrying text, cost and usage" do
      assert {:result, "success", result} =
               decode(%{
                 "type" => "agent_end",
                 "isTerminal" => true,
                 "messages" => [
                   %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]},
                   %{
                     "role" => "assistant",
                     "content" => [
                       %{"type" => "thinking", "thinking" => "hmm"},
                       %{"type" => "text", "text" => "Hello"}
                     ],
                     "stopReason" => "stop",
                     "duration" => 1234,
                     "usage" => %{"output" => 44, "cost" => %{"total" => 0.25}}
                   }
                 ]
               })

      assert result["result"] == "Hello"
      assert result["total_cost_usd"] == 0.25
      assert result["num_turns"] == 1
      assert result["duration_ms"] == 1234
      assert result["stop_reason"] == "stop"
      assert result["is_error"] == false
      assert result["usage"] == %{"output" => 44, "cost" => %{"total" => 0.25}}
    end

    test "cost sums every assistant message in the turn" do
      assert {:result, "success", %{"total_cost_usd" => total, "num_turns" => 2}} =
               decode(%{
                 "type" => "agent_end",
                 "messages" => [
                   %{"role" => "assistant", "usage" => %{"cost" => %{"total" => 0.25}}},
                   %{
                     "role" => "assistant",
                     "content" => [%{"type" => "text", "text" => "done"}],
                     "usage" => %{"cost" => %{"total" => 0.75}}
                   }
                 ]
               })

      assert_in_delta total, 1.0, 1.0e-9
    end

    test "an agent_end with no assistant message still yields a result" do
      assert {:result, "success", result} = decode(%{"type" => "agent_end", "messages" => []})

      assert result["result"] == ""
      assert result["total_cost_usd"] == 0.0
      assert result["num_turns"] == 0
    end

    test "a non-terminal agent_end does not complete the turn" do
      assert {:stream_event, _} =
               decode(%{"type" => "agent_end", "isTerminal" => false, "messages" => []})
    end

    test "message_end is tagged by role" do
      assert {:assistant, _} =
               decode(%{"type" => "message_end", "message" => %{"role" => "assistant"}})

      assert {:user, _} = decode(%{"type" => "message_end", "message" => %{"role" => "user"}})
    end

    test "streaming deltas are stream events" do
      assert {:stream_event, _} =
               decode(%{
                 "type" => "message_update",
                 "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "he"}
               })
    end

    test "a rejected prompt terminates the turn as an error result" do
      assert {:result, "error_prompt_failed", result} =
               decode(%{
                 "type" => "response",
                 "command" => "prompt",
                 "success" => false,
                 "error" => "session is streaming",
                 "code" => "session_busy"
               })

      assert result["is_error"] == true
      assert result["result"] == "session is streaming"
      assert result["error_code"] == "session_busy"
    end

    test "an unrelated command failure is not a result" do
      assert {:unknown, _} =
               decode(%{
                 "type" => "response",
                 "command" => "set_model",
                 "success" => false,
                 "error" => "Model not found"
               })
    end

    test "handshake and unrecognized frames fall through to :unknown" do
      assert {:unknown, %{"type" => "ready"}} =
               decode(%{"type" => "ready", "protocolVersion" => 1})

      assert {:unknown, _} = decode(%{"type" => "turn_start"})
    end

    test "a local-only prompt completes the turn instead of waiting for agent_end" do
      # A slash command omp resolves itself emits NO agent_end. Without this
      # clause a collector blocks until its own deadline for a command that
      # finished in milliseconds.
      assert {:result, "success", result} =
               decode(%{
                 "type" => "response",
                 "command" => "prompt",
                 "success" => true,
                 "data" => %{"agentInvoked" => false}
               })

      assert result["local_only"] == true
      assert result["is_error"] == false
      assert result["result"] == ""

      assert {:result, "success", %{"local_only" => true}} =
               decode(%{
                 "type" => "prompt_result",
                 "id" => "cc-prompt-0",
                 "agentInvoked" => false
               })
    end

    test "an agent-invoking prompt ack is not mistaken for completion" do
      # omp v17.2.12 omits `data` entirely for prompts that do invoke the
      # agent; treating a missing/true agentInvoked as terminal would end the
      # turn before the model had answered.
      assert {:unknown, _} =
               decode(%{"type" => "response", "command" => "prompt", "success" => true})

      assert {:unknown, _} =
               decode(%{
                 "type" => "response",
                 "command" => "prompt",
                 "success" => true,
                 "data" => %{"agentInvoked" => true}
               })
    end

    # decode_line/1 runs inside Session.handle_cast/2: a raise here does not
    # return an error, it kills the session. These are the shapes a schema
    # change in omp would produce, and every one of them used to raise.
    test "a type-drifted get_state payload decodes instead of raising" do
      for {label, data} <- [
            {"model as string", %{"model" => "claude-opus-5"}},
            {"model as list", %{"model" => ["a"]}},
            {"model as number", %{"model" => 7}},
            {"dumpTools as string", %{"dumpTools" => "read,write"}},
            {"dumpTools as object", %{"dumpTools" => %{"a" => 1}}},
            {"dumpTools entries not maps", %{"dumpTools" => ["read", 2, nil]}},
            {"everything hostile", %{"model" => "x", "dumpTools" => "y", "sessionId" => %{}}}
          ] do
        assert {:system_init, init} =
                 decode(%{
                   "type" => "response",
                   "command" => "get_state",
                   "success" => true,
                   "data" => data
                 }),
               "#{label} should decode"

        assert is_list(init["tools"]), "#{label} should still yield a tool list"
      end
    end

    test "a non-string sessionId is clamped to nil rather than propagated" do
      # session_id is spec'd String.t() | nil through Session and Store, and is
      # fed back to omp as --resume, where a map raises in to_string/1.
      assert {:system_init, init} =
               decode(%{
                 "type" => "response",
                 "command" => "get_state",
                 "success" => true,
                 "data" => %{"sessionId" => %{"nested" => 1}, "sessionFile" => 42}
               })

      assert init["session_id"] == nil
      assert init["session_file"] == nil
    end

    test "never raises on garbage" do
      assert {:invalid_json, "{nope"} = Omp.decode_line("{nope")
      assert {:invalid_json, "[1,2]"} = Omp.decode_line("[1,2]")
      assert {:invalid_json, ""} = Omp.decode_line("")
    end
  end
end
