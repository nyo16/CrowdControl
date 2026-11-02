#!/usr/bin/env elixir
# Stream-json control-protocol stand-in for Claude Code, for CrowdControl tests.
#
# fake_cli.sh treats every stdin line as a prompt, so it cannot answer a control
# request. This one speaks the protocol, following the frames observed against
# claude 2.1.292 (.claude/plans/.../research/verify-control.md):
#
#   * a prompt starts a turn: system/init (first turn only, with
#     claude_code_version), then one Bash tool call per FAKE_CC_TOOLS, each
#     asked with a `can_use_tool` whose request_id is a UUID v4. The second is
#     asked only once the first is answered.
#   * allow -> a `user` tool_result (`ran: <updatedInput.command>`); an allow
#     without updatedInput fails the turn, as the CLI's schema would.
#   * deny -> an is_error tool_result carrying the message; the turn continues
#     and its result lists the denial in `permission_denials`.
#   * deny with interrupt, or an `interrupt` while a prompt is pending ->
#     `control_cancel_request` (interrupt only, sent before the ack), then an
#     `error_during_execution` / `aborted_tools` result, and exit 1 at EOF.
#   * a repeated `initialize` reports the pending prompt, verbatim, in
#     `pending_permission_requests`, plus `session_state`; for each declared
#     `sdkMcpServers` name it sends an MCP `initialize` (`mcp_message`, id 0).
#   * a late answer for a withdrawn or unknown request_id is ignored.
#   * mcp_permission mode: an SDK MCP tool is asked first, as a `can_use_tool`
#     named `mcp__<server>__<tool>` (the naming Claude Code gives SDK tools),
#     and only an allow is followed by the `tools/call`, whose arguments are
#     the allow's updatedInput.
#
# Environment:
#   FAKE_CC_VERSION      version for `--version` and system/init (2.1.292)
#   FAKE_CC_MODE         permission (default) | mcp | mcp_permission | hook
#   FAKE_CC_TOOLS        tool calls per turn in permission mode (1)
#   FAKE_CC_HOOK_ID      hook mode: callback_id to call
#   FAKE_CC_LOG          append every stdin line to this file

defmodule FakeControlCli do
  @rejected "The user doesn't want to proceed with this tool use. The tool use was rejected " <>
              "(eg. if it was a file edit, the new_string was NOT written to the file). STOP " <>
              "what you are doing and wait for the user to tell you how to proceed."

  def main(argv) do
    if "--version" in argv do
      IO.puts("#{version()} (Claude Code)")
      System.halt(0)
    end

    loop(%{
      inited: false,
      session_id: "fake-control-#{System.pid()}",
      mode: System.get_env("FAKE_CC_MODE", "permission"),
      tools: String.to_integer(System.get_env("FAKE_CC_TOOLS", "1")),
      turns: 0,
      cost: 0.0,
      waiting: nil,
      denials: [],
      outputs: [],
      exit_code: 0
    })
  end

  defp version, do: System.get_env("FAKE_CC_VERSION", "2.1.292")

  defp loop(state) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        log(line)

        state =
          case JSON.decode(String.trim_trailing(line)) do
            {:ok, %{} = frame} -> handle(frame, state)
            _ -> state
          end

        loop(state)

      _eof ->
        System.halt(state.exit_code)
    end
  end

  defp log(line) do
    case System.get_env("FAKE_CC_LOG") do
      nil -> :ok
      path -> File.write!(path, line, [:append])
    end
  end

  # --- inbound frames ---

  defp handle(%{"type" => "user"}, state), do: start_turn(state)

  defp handle(%{"type" => "control_request", "request_id" => id, "request" => request}, state),
    do: host_request(id, request, state)

  defp handle(
         %{"type" => "control_response", "response" => %{"request_id" => id} = response},
         state
       ) do
    case state.waiting do
      %{id: ^id} = waiting -> answered(waiting, response, %{state | waiting: nil})
      # Late, withdrawn, or an answer to our own MCP initialize: ignored.
      _other -> state
    end
  end

  defp handle(_frame, state), do: state

  # --- turns ---

  defp start_turn(state) do
    state =
      if state.inited do
        state
      else
        emit(%{
          "type" => "system",
          "subtype" => "init",
          "session_id" => state.session_id,
          "claude_code_version" => version(),
          "tools" => ["Bash"],
          "permissionMode" => "default"
        })

        %{state | inited: true}
      end

    state = %{state | turns: state.turns + 1, denials: [], outputs: []}

    case state.mode do
      "mcp" -> ask_mcp(state)
      "mcp_permission" -> ask_mcp_permission(state)
      "hook" -> ask_hook(state)
      _permission -> ask_tool(0, state)
    end
  end

  defp ask_tool(index, state) do
    tool_use_id = "toolu_fake_#{state.turns}_#{index}"
    input = %{"command" => "echo #{index} > out#{index}.txt", "description" => "write #{index}"}

    emit(
      assistant([
        %{"type" => "tool_use", "id" => tool_use_id, "name" => "Bash", "input" => input}
      ])
    )

    frame = %{
      "type" => "control_request",
      "request_id" => uuid(),
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => "Bash",
        "display_name" => "Bash",
        "input" => input,
        "description" => input["description"],
        "permission_suggestions" => [],
        "blocked_path" => nil,
        "tool_use_id" => tool_use_id
      }
    }

    emit(frame)

    waiting = %{kind: :permission, id: frame["request_id"], index: index, frame: frame}
    %{state | waiting: waiting}
  end

  defp ask_mcp(state) do
    {server, tool, args} = mcp_tool()

    emit(
      assistant([
        %{
          "type" => "tool_use",
          "id" => "toolu_mcp",
          "name" => "mcp__#{server}__#{tool}",
          "input" => args
        }
      ])
    )

    call_mcp(server, tool, args, state)
  end

  # mcp modes always call the `echo` tool of the `app` server.
  defp mcp_tool, do: {"app", "echo", %{"text" => "hi"}}

  defp call_mcp(server, tool, args, state) do
    id = uuid()

    emit(%{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{
        "subtype" => "mcp_message",
        "server_name" => server,
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => tool, "arguments" => args}
        }
      }
    })

    %{state | waiting: %{kind: :mcp, id: id}}
  end

  defp ask_mcp_permission(state) do
    {server, tool, args} = mcp_tool()
    name = "mcp__#{server}__#{tool}"

    emit(
      assistant([%{"type" => "tool_use", "id" => "toolu_mcp", "name" => name, "input" => args}])
    )

    frame = %{
      "type" => "control_request",
      "request_id" => uuid(),
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => name,
        "display_name" => tool,
        "input" => args,
        "permission_suggestions" => [],
        "blocked_path" => nil,
        "tool_use_id" => "toolu_mcp"
      }
    }

    emit(frame)
    waiting = %{kind: :mcp_permission, id: frame["request_id"], frame: frame, mcp: {server, tool}}
    %{state | waiting: waiting}
  end

  defp ask_hook(state) do
    id = uuid()

    emit(%{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{
        "subtype" => "hook_callback",
        "callback_id" => System.get_env("FAKE_CC_HOOK_ID", "hook_PreToolUse_0_0"),
        "input" => %{
          "hook_event_name" => "PreToolUse",
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "ls"}
        },
        "tool_use_id" => "toolu_hook"
      }
    })

    %{state | waiting: %{kind: :hook, id: id}}
  end

  defp answered(%{kind: :mcp_permission, mcp: {server, tool}}, response, state) do
    case response do
      %{
        "subtype" => "success",
        "response" => %{"behavior" => "allow", "updatedInput" => %{} = input}
      } ->
        call_mcp(server, tool, input, state)

      %{"subtype" => "success", "response" => %{"behavior" => "deny"} = deny} ->
        emit(tool_result("toolu_mcp", deny["message"] || "", true))
        finish(%{state | outputs: ["denied: #{deny["message"]}"]})

      other ->
        emit(tool_result("toolu_mcp", "permission request failed", true))
        finish(%{state | outputs: ["failed: #{JSON.encode!(other)}"]})
    end
  end

  defp answered(%{kind: :permission} = waiting, %{"subtype" => "success"} = response, state) do
    tool_use_id = waiting.frame["request"]["tool_use_id"]
    input = waiting.frame["request"]["input"]

    case response["response"] do
      %{"behavior" => "allow", "updatedInput" => %{} = updated} ->
        output = "ran: #{updated["command"]}"
        emit(tool_result(tool_use_id, output, false))
        next_tool(waiting.index, %{state | outputs: state.outputs ++ [output]})

      %{"behavior" => "allow"} ->
        emit(
          result("error_during_execution", state, %{"errors" => ["allow without updatedInput"]})
        )

        state

      %{"behavior" => "deny", "interrupt" => true} ->
        state = %{state | denials: state.denials ++ [denial(tool_use_id, input)]}
        abort(tool_use_id, state)

      %{"behavior" => "deny"} = deny ->
        emit(tool_result(tool_use_id, deny["message"] || "", true))
        denials = state.denials ++ [denial(tool_use_id, input)]
        next_tool(waiting.index, %{state | denials: denials})
    end
  end

  defp answered(%{kind: :permission} = waiting, error_response, state) do
    tool_use_id = waiting.frame["request"]["tool_use_id"]
    message = "Tool permission request failed: #{error_response["error"]}"
    emit(tool_result(tool_use_id, message, true))
    next_tool(waiting.index, state)
  end

  defp answered(%{kind: kind}, response, state) when kind in [:mcp, :hook] do
    case response do
      %{"subtype" => "success"} ->
        mcp_or_hook_answered(kind, Map.get(response, "response", %{}), state)

      %{"error" => error} ->
        mcp_or_hook_answered(kind, %{"error" => error}, state)

      # A malformed host answer ends the turn with an explained error.
      other ->
        malformed_answer(other, state)
    end
  end

  defp mcp_or_hook_answered(kind, payload, state) do
    emit(tool_result("toolu_#{kind}", JSON.encode!(payload), false))
    finish(%{state | outputs: [JSON.encode!(payload)]})
  end

  defp malformed_answer(response, state) do
    errors = ["malformed control_response: #{JSON.encode!(response)}"]
    emit(result("error_during_execution", state, %{"errors" => errors}))
    state
  end

  defp next_tool(index, state) do
    if index + 1 < state.tools, do: ask_tool(index + 1, state), else: finish(state)
  end

  defp finish(state) do
    emit(assistant([%{"type" => "text", "text" => "done"}]))
    state = %{state | cost: state.cost + 0.01}

    emit(
      result("success", state, %{
        "is_error" => false,
        "stop_reason" => "end_turn",
        "terminal_reason" => "completed",
        "result" => Enum.join(state.outputs, "\n")
      })
    )

    state
  end

  defp abort(tool_use_id, state) do
    emit(tool_result(tool_use_id, @rejected, true))

    emit(%{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "[Request interrupted by user for tool use]"}]
      }
    })

    emit(
      result("error_during_execution", state, %{
        "is_error" => true,
        "stop_reason" => "tool_use",
        "terminal_reason" => "aborted_tools",
        "errors" => [
          "[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"
        ]
      })
    )

    %{state | waiting: nil, exit_code: 1}
  end

  # --- host-originated requests ---

  defp host_request(id, %{"subtype" => "initialize"} = request, state) do
    {pending, session_state} =
      case state.waiting do
        %{kind: kind, frame: frame} when kind in [:permission, :mcp_permission] ->
          {[frame], "requires_action"}

        _other ->
          {[], "idle"}
      end

    emit(%{
      "type" => "control_response",
      "response" => %{
        "subtype" => "success",
        "request_id" => id,
        "response" => %{
          "commands" => [],
          "session_state" => session_state,
          "current_permission_mode" => "default",
          "pid" => String.to_integer(System.pid())
        },
        "pending_permission_requests" => pending,
        "pending_user_dialog_requests" => []
      }
    })

    for name <- Map.get(request, "sdkMcpServers", []) do
      emit(%{
        "type" => "control_request",
        "request_id" => uuid(),
        "request" => %{
          "subtype" => "mcp_message",
          "server_name" => name,
          "message" => %{
            "jsonrpc" => "2.0",
            "id" => 0,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "claude-code", "version" => version()}
            }
          }
        }
      })
    end

    state
  end

  defp host_request(id, %{"subtype" => "interrupt"}, state) do
    case state.waiting do
      %{kind: :permission, id: pending_id, frame: frame} ->
        emit(%{"type" => "control_cancel_request", "request_id" => pending_id})
        ack(id, %{"still_queued" => []})
        abort(frame["request"]["tool_use_id"], %{state | waiting: nil})

      _other ->
        ack(id, %{"still_queued" => []})
        state
    end
  end

  defp host_request(id, %{"subtype" => "set_model"}, state) do
    ack(id, %{})
    state
  end

  defp host_request(id, %{"subtype" => "set_permission_mode", "mode" => mode}, state) do
    ack(id, %{"mode" => mode})
    state
  end

  defp host_request(id, %{"subtype" => subtype}, state) do
    emit(%{
      "type" => "control_response",
      "response" => %{
        "subtype" => "error",
        "request_id" => id,
        "error" => "Unsupported control request subtype: #{subtype}"
      }
    })

    state
  end

  # --- frames ---

  defp ack(id, response) do
    emit(%{
      "type" => "control_response",
      "response" => %{"subtype" => "success", "request_id" => id, "response" => response}
    })
  end

  defp assistant(content) do
    %{"type" => "assistant", "message" => %{"role" => "assistant", "content" => content}}
  end

  defp tool_result(tool_use_id, content, is_error) do
    %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => tool_use_id,
            "content" => content,
            "is_error" => is_error
          }
        ]
      }
    }
  end

  defp denial(tool_use_id, input),
    do: %{"tool_name" => "Bash", "tool_use_id" => tool_use_id, "tool_input" => input}

  defp result(subtype, state, fields) do
    Map.merge(
      %{
        "type" => "result",
        "subtype" => subtype,
        "is_error" => subtype != "success",
        "num_turns" => state.turns,
        "session_id" => state.session_id,
        "total_cost_usd" => state.cost,
        "permission_denials" => state.denials
      },
      fields
    )
  end

  defp emit(frame), do: IO.write(JSON.encode!(frame) <> "\n")

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::62>>, case: :lower)

    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end
end

FakeControlCli.main(System.argv())
