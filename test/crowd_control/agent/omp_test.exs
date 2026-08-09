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

  describe "custom providers" do
    defp config(spec), do: JSON.decode!(Omp.render_models_config!(spec))

    defp provider(spec) do
      %{"providers" => providers} = config(spec)
      {id, body} = Enum.at(providers, 0)
      {id, body}
    end

    test "a bare base_url renders the built-in vllm provider with no auth" do
      # omp's built-in `vllm` id already reads /v1/models (and max_model_len),
      # so an explicit discovery block would be redundant.
      assert {"vllm", body} = provider(base_url: "http://10.0.0.5:8000/v1")

      assert body["baseUrl"] == "http://10.0.0.5:8000/v1"
      assert body["api"] == "openai-completions"
      assert body["auth"] == "none"
      refute Map.has_key?(body, "discovery")
      refute Map.has_key?(body, "models")
    end

    test "a non-vllm id gets generic OpenAI discovery spelled out" do
      assert {"my-proxy", body} = provider(id: "my-proxy", base_url: "http://h:8000/v1")
      assert body["discovery"] == %{"type" => "openai-models-list"}
    end

    test "an explicit model list replaces discovery" do
      {_id, body} =
        provider(
          id: "my-proxy",
          base_url: "http://h:8000/v1",
          models: [
            [
              id: "Qwen/Q3",
              context_window: 32_768,
              max_tokens: 4096,
              reasoning: true,
              input: ["text"]
            ]
          ]
        )

      refute Map.has_key?(body, "discovery")

      assert body["models"] == [
               %{
                 "id" => "Qwen/Q3",
                 "name" => "Qwen/Q3",
                 "contextWindow" => 32_768,
                 "maxTokens" => 4096,
                 "reasoning" => true,
                 "input" => ["text"]
               }
             ]
    end

    test "an anthropic-shaped endpoint refuses to guess a model list" do
      # There is no OpenAI /v1/models to probe, so inventing a discovery block
      # would yield a provider that silently resolves nothing.
      assert_raise ArgumentError, ~r/cannot discover models/, fn ->
        config(id: "gw", base_url: "https://gw/v1", api: "anthropic-messages")
      end
    end

    test "accepts a map spec as well as a keyword list" do
      assert {"vllm", %{"baseUrl" => "http://h/v1"}} = provider(%{base_url: "http://h/v1"})
    end

    test "requires a base_url" do
      assert_raise ArgumentError, ~r/requires :base_url/, fn -> config(id: "x") end
    end

    test "rejects an unsupported api" do
      assert_raise ArgumentError, ~r/:api must be one of/, fn ->
        config(base_url: "http://h/v1", api: "grpc")
      end
    end

    test "rejects control characters in the base url" do
      assert_raise ArgumentError, ~r/control character/, fn ->
        config(base_url: "http://h/v1\nX: y")
      end
    end

    # The whole point of the env-var indirection: models.yml is a plain file on
    # disk, and a provider key has no business being in it.
    test "the provider key is referenced by env var name, never written to the config" do
      {_id, body} = provider(base_url: "http://h/v1", api_key: "vllm-secret-abc")

      assert body["apiKey"] == "OMP_CUSTOM_PROVIDER_KEY"
      assert body["authHeader"] == true
      refute Map.has_key?(body, "auth")

      refute Omp.render_models_config!(base_url: "http://h/v1", api_key: "vllm-secret-abc")
             |> String.contains?("vllm-secret-abc")
    end

    test "the provider key travels through env, never through argv" do
      {_exe, args, env} =
        Omp.build_command(custom_provider: [base_url: "http://h/v1", api_key: "vllm-secret-abc"])

      assert env["OMP_CUSTOM_PROVIDER_KEY"] == "vllm-secret-abc"
      refute Enum.any?(args, &String.contains?(&1, "vllm-secret-abc"))

      Omp.remove_provider_dir(env["PI_CODING_AGENT_DIR"])
    end

    test ":api_key_env renames the variable on both sides" do
      {_exe, _args, env} =
        Omp.build_command(
          custom_provider: [base_url: "http://h/v1", api_key: "k", api_key_env: "MY_VLLM_KEY"]
        )

      assert env["MY_VLLM_KEY"] == "k"

      {_id, body} = provider(base_url: "http://h/v1", api_key: "k", api_key_env: "MY_VLLM_KEY")
      assert body["apiKey"] == "MY_VLLM_KEY"

      Omp.remove_provider_dir(env["PI_CODING_AGENT_DIR"])
    end

    test "build_command points PI_CODING_AGENT_DIR at a private generated dir" do
      {_exe, _args, env} = Omp.build_command(custom_provider: [base_url: "http://h/v1"])
      dir = env["PI_CODING_AGENT_DIR"]

      assert File.dir?(dir)
      # 0o40700 -- owner only, like Backend.Local's env dir.
      assert File.stat!(dir).mode == 0o40700
      assert File.stat!(Path.join(dir, "models.yml")).mode == 0o100600

      assert JSON.decode!(File.read!(Path.join(dir, "models.yml")))["providers"]["vllm"][
               "baseUrl"
             ] ==
               "http://h/v1"

      Omp.remove_provider_dir(dir)
    end

    test "one spec maps to one directory, so a fan-out does not write N copies" do
      same_a = Omp.provider_dir!(base_url: "http://shared:8000/v1")
      same_b = Omp.provider_dir!(base_url: "http://shared:8000/v1")
      other = Omp.provider_dir!(base_url: "http://elsewhere:8000/v1")

      assert same_a == same_b
      refute same_a == other

      Enum.each([same_a, other], &Omp.remove_provider_dir/1)
    end

    test "the directory name is not guessable from the spec alone" do
      # A pure content hash would let another local user pre-create the path (or
      # plant a symlink at models.yml) before we write it.
      dir = Omp.provider_dir!(base_url: "http://h:8000/v1")
      digest = :sha256 |> :crypto.hash("http://h:8000/v1") |> Base.encode16(case: :lower)

      refute String.contains?(Path.basename(dir), binary_part(digest, 0, 16))

      Omp.remove_provider_dir(dir)
    end

    test ":agent_dir passes a caller-owned directory through instead" do
      {_exe, _args, env} = Omp.build_command(agent_dir: "/tmp/my-omp-agent")
      assert env["PI_CODING_AGENT_DIR"] == "/tmp/my-omp-agent"
    end

    test ":agent_dir and :custom_provider together are a contradiction, not a merge" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        Omp.build_command(agent_dir: "/tmp/x", custom_provider: [base_url: "http://h/v1"])
      end
    end

    test "an explicit :env entry still wins over the generated ones" do
      {_exe, _args, env} =
        Omp.build_command(
          custom_provider: [base_url: "http://h/v1"],
          env: %{"PI_CODING_AGENT_DIR" => "/tmp/caller-wins"}
        )

      assert env["PI_CODING_AGENT_DIR"] == "/tmp/caller-wins"
    end

    test "remove_provider_dir refuses anything it did not create" do
      assert {:error, :not_a_provider_dir} = Omp.remove_provider_dir("/etc")
      assert {:error, :not_a_provider_dir} = Omp.remove_provider_dir(System.tmp_dir!())

      assert {:error, :not_a_provider_dir} =
               Omp.remove_provider_dir(Path.join(System.tmp_dir!(), "cc_omp_x/../../etc"))
    end

    test "remove_provider_dir refuses a symlink wearing our prefix" do
      # A planted `<tmp>/cc_omp_evil -> <victim>` passes both the parent-dir and
      # prefix checks. File.rm_rf/1 unlinks rather than follows, so the victim
      # would survive anyway -- but the guard should not be resting on that.
      victim = Path.join(System.tmp_dir!(), "cc_omp_victim_#{System.unique_integer([:positive])}")
      link = Path.join(System.tmp_dir!(), "cc_omp_evil_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(victim, "nested"))
      File.write!(Path.join(victim, "keep.txt"), "keep")
      :ok = File.ln_s(victim, link)

      on_exit(fn ->
        File.rm(link)
        File.rm_rf(victim)
      end)

      assert {:error, :not_a_provider_dir} = Omp.remove_provider_dir(link)
      assert File.exists?(Path.join(victim, "keep.txt")), "the symlink target must be untouched"
      assert File.exists?(link), "we refused, so we should not have unlinked it either"
    end

    test "remove_provider_dir refuses a plain file wearing our prefix" do
      path = Path.join(System.tmp_dir!(), "cc_omp_notadir_#{System.unique_integer([:positive])}")
      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      assert {:error, :not_a_provider_dir} = Omp.remove_provider_dir(path)
    end

    test "inherit_auth links the real store in, and a plain spec does not" do
      fake_agent =
        Path.join(System.tmp_dir!(), "cc_fake_agent_#{System.unique_integer([:positive])}")

      File.mkdir_p!(fake_agent)
      File.write!(Path.join(fake_agent, "agent.db"), "pretend-sqlite")
      on_exit(fn -> File.rm_rf(fake_agent) end)

      inheriting = Omp.provider_dir!(base_url: "http://h/v1", inherit_auth: fake_agent)
      plain = Omp.provider_dir!(base_url: "http://h/v1")
      on_exit(fn -> Enum.each([inheriting, plain], &Omp.remove_provider_dir/1) end)

      assert {:ok, target} = File.read_link(Path.join(inheriting, "agent.db"))
      assert target == Path.join(fake_agent, "agent.db")
      refute File.exists?(Path.join(plain, "agent.db"))

      # Same models.yml, different auth intent: the content-addressed path must
      # not collide, or one spec would silently inherit the other's decision.
      refute inheriting == plain
    end

    test "removing an inheriting dir leaves the real auth store alone" do
      fake_agent =
        Path.join(System.tmp_dir!(), "cc_fake_agent_#{System.unique_integer([:positive])}")

      store = Path.join(fake_agent, "agent.db")
      File.mkdir_p!(fake_agent)
      File.write!(store, "pretend-sqlite")
      on_exit(fn -> File.rm_rf(fake_agent) end)

      dir = Omp.provider_dir!(base_url: "http://h/v1", inherit_auth: fake_agent)
      assert :ok = Omp.remove_provider_dir(dir)

      refute File.dir?(dir)
      assert File.read!(store) == "pretend-sqlite"
    end

    test "inherit_auth is idempotent across sessions sharing a spec" do
      fake_agent =
        Path.join(System.tmp_dir!(), "cc_fake_agent_#{System.unique_integer([:positive])}")

      File.mkdir_p!(fake_agent)
      File.write!(Path.join(fake_agent, "agent.db"), "pretend-sqlite")
      on_exit(fn -> File.rm_rf(fake_agent) end)

      spec = [base_url: "http://h/v1", inherit_auth: fake_agent]
      a = Omp.provider_dir!(spec)
      b = Omp.provider_dir!(spec)
      on_exit(fn -> Omp.remove_provider_dir(a) end)

      assert a == b
      assert {:ok, _} = File.read_link(Path.join(b, "agent.db"))
    end

    test "inherit_auth says so when there is no store to inherit" do
      assert_raise ArgumentError, ~r/no omp auth store at/, fn ->
        Omp.provider_dir!(base_url: "http://h/v1", inherit_auth: "/tmp/cc-no-such-agent-dir")
      end
    end

    test "inherit_auth: false is the same as omitting it" do
      with_flag = Omp.provider_dir!(base_url: "http://h/v1", inherit_auth: false)
      without = Omp.provider_dir!(base_url: "http://h/v1")
      on_exit(fn -> Omp.remove_provider_dir(without) end)

      assert with_flag == without
    end
  end

  describe "credentials" do
    test ":oauth_token carries a Claude subscription, not an API key" do
      # omp resolves ANTHROPIC_OAUTH_TOKEN ahead of ANTHROPIC_API_KEY, which is
      # what makes a session bill a subscription instead of per-token usage.
      {_exe, args, env} = Omp.build_command(oauth_token: "sk-ant-oat-123")

      assert env["ANTHROPIC_OAUTH_TOKEN"] == "sk-ant-oat-123"
      refute Map.has_key?(env, "ANTHROPIC_API_KEY")
      refute Enum.any?(args, &String.contains?(&1, "sk-ant-oat-123"))
    end

    test ":oauth_token and :api_key can both be present" do
      {_exe, _args, env} = Omp.build_command(oauth_token: "oat", api_key: "key")

      assert env["ANTHROPIC_OAUTH_TOKEN"] == "oat"
      assert env["ANTHROPIC_API_KEY"] == "key"
    end

    test ":oauth_token works alongside a custom provider" do
      {_exe, _args, env} =
        Omp.build_command(
          oauth_token: "oat",
          custom_provider: [base_url: "http://h/v1", api_key: "vllm-key"]
        )

      assert env["ANTHROPIC_OAUTH_TOKEN"] == "oat"
      assert env["OMP_CUSTOM_PROVIDER_KEY"] == "vllm-key"

      Omp.remove_provider_dir(env["PI_CODING_AGENT_DIR"])
    end

    test "rejects a non-binary :oauth_token" do
      assert_raise ArgumentError, ~r/:oauth_token must be a binary/, fn ->
        Omp.build_command(oauth_token: :secret)
      end
    end

    test ":auth_token is rejected rather than silently ignored" do
      # ANTHROPIC_AUTH_TOKEN is a Claude Code mechanism; setting it for omp would
      # look like it worked and change nothing.
      assert_raise ArgumentError, ~r/no omp equivalent.*custom_provider/s, fn ->
        Omp.build_command(auth_token: "bearer")
      end
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
