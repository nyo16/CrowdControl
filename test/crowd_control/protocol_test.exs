defmodule CrowdControl.ProtocolTest do
  use ExUnit.Case, async: true

  alias CrowdControl.Protocol

  doctest CrowdControl.Protocol

  describe "split_lines/1" do
    test "splits complete lines" do
      {lines, remainder} = Protocol.split_lines("line1\nline2\nline3\n")
      assert lines == ["line1", "line2", "line3"]
      assert remainder == ""
    end

    test "handles incomplete trailing line" do
      {lines, remainder} = Protocol.split_lines("line1\npartial")
      assert lines == ["line1"]
      assert remainder == "partial"
    end

    test "handles no newlines" do
      {lines, remainder} = Protocol.split_lines("no newline here")
      assert lines == []
      assert remainder == "no newline here"
    end

    test "handles empty buffer" do
      {lines, remainder} = Protocol.split_lines("")
      assert lines == []
      assert remainder == ""
    end

    test "handles single newline" do
      {lines, remainder} = Protocol.split_lines("\n")
      assert lines == [""]
      assert remainder == ""
    end
  end

  describe "decode_line/1" do
    test "decodes system init message" do
      json = ~s({"type":"system","subtype":"init","session_id":"abc-123","tools":[]})
      assert {:system_init, %{"session_id" => "abc-123"}} = Protocol.decode_line(json)
    end

    test "decodes assistant message" do
      json = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}})
      assert {:assistant, %{"message" => _}} = Protocol.decode_line(json)
    end

    test "decodes user message" do
      json = ~s({"type":"user","message":{"content":[]}})
      assert {:user, _} = Protocol.decode_line(json)
    end

    test "decodes result success" do
      json = ~s({"type":"result","subtype":"success","result":"done","total_cost_usd":0.001})
      assert {:result, "success", %{"result" => "done"}} = Protocol.decode_line(json)
    end

    test "decodes result error" do
      json = ~s({"type":"result","subtype":"error_max_turns","result":""})
      assert {:result, "error_max_turns", _} = Protocol.decode_line(json)
    end

    test "decodes stream event" do
      json = ~s({"type":"stream_event","event":"content_block_delta"})
      assert {:stream_event, _} = Protocol.decode_line(json)
    end

    test "classifies unknown types" do
      json = ~s({"type":"something_else","data":"value"})
      assert {:unknown, %{"type" => "something_else"}} = Protocol.decode_line(json)
    end

    test "returns invalid_json on malformed input instead of raising" do
      assert {:invalid_json, "{not json"} = Protocol.decode_line("{not json")
    end

    test "returns invalid_json on non-object JSON" do
      assert {:invalid_json, "[1,2,3]"} = Protocol.decode_line("[1,2,3]")
    end

    test "returns invalid_json on empty string" do
      assert {:invalid_json, ""} = Protocol.decode_line("")
    end
  end

  describe "encode_user_message/1" do
    test "encodes a prompt with trailing newline" do
      result = Protocol.encode_user_message("Hello world")
      assert String.ends_with?(result, "\n")

      decoded = JSON.decode!(String.trim_trailing(result, "\n"))
      assert decoded["type"] == "user"
      assert decoded["message"]["role"] == "user"
      assert decoded["message"]["content"] == "Hello world"
    end

    test "handles special characters" do
      result = Protocol.encode_user_message(~s(Say "hello" & 'goodbye'))
      decoded = JSON.decode!(String.trim_trailing(result, "\n"))
      assert decoded["message"]["content"] == ~s(Say "hello" & 'goodbye')
    end

    test "round-trips through decode_line/1" do
      encoded = Protocol.encode_user_message("round-trip test ✓")
      [line] = String.split(encoded, "\n", trim: true)

      assert {:user, %{"message" => %{"content" => "round-trip test ✓"}}} =
               Protocol.decode_line(line)
    end
  end

  # Frames observed against claude 2.1.292, copied verbatim from
  # .claude/plans/claude-wrapper-ex-harvest/research/verify-control.md (and the
  # PROBE lines of control-protocol.md). The can_use_tool frame is wrapped over
  # several lines there; `line/1` joins it, which is safe because no string in
  # it contains a newline.

  # CLI -> host, verify-control.md Step 3.
  @can_use_tool ~S"""
  {"type":"control_request","request_id":"a6395e9d-5eda-47d2-9f71-733c8aef7cd5","request":{
    "subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash",
    "input":{"command":"echo hi > hi.txt","description":"say hi"},
    "description":"say hi",
    "permission_suggestions":[
      {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo hi *"}],"behavior":"allow","destination":"localSettings"},
      {"type":"addDirectories","directories":["/private/tmp/cc-verify-VerifyControlReinit/work-allow"],"destination":"session"}],
    "blocked_path":"/private/tmp/cc-verify-VerifyControlReinit/work-allow/hi.txt",
    "tool_use_id":"toolu_mock_1"}}
  """

  # Host -> CLI, Step 4.
  @reinit ~S({"type":"control_request","request_id":"req_init_2","request":{"subtype":"initialize"}})

  # Host -> CLI, Step 5 (the request_id is elided with "…" in the source; kept as is).
  @allow ~S"""
  {"type":"control_response","response":{"subtype":"success","request_id":"a6395e9d-…","response":{
       "behavior":"allow","updatedInput":{"command":"echo hi-from-host","description":"say hi (host edited)"}}}}
  """

  # Host -> CLI, Step 6a.
  @deny ~S({"type":"control_response","response":{"subtype":"success","request_id":"0c15f268-dd8d-4581-b1c1-70d5e47625ee","response":{"behavior":"deny","message":"Denied by verify host"}}})

  # Host -> CLI, Step 6b.
  @deny_interrupt ~S({"type":"control_response","response":{"subtype":"success","request_id":"d3c22063-0de3-4b6d-a0c6-093f820d07a3","response":{"behavior":"deny","message":"Denied by verify host","interrupt":true}}})

  # Step 6c: host -> CLI interrupt, then the CLI's cancel and ack.
  @interrupt ~S({"type":"control_request","request_id":"req_int_1","request":{"subtype":"interrupt"}})
  @cancel ~S({"type":"control_cancel_request","request_id":"97a2d200-2530-4c43-8d71-e0e66f205c6b"})
  @interrupt_ack ~S({"type":"control_response","response":{"subtype":"success","request_id":"req_int_1","response":{"still_queued":[]}}})

  # The notice that follows every re-initialize (Step 4).
  @background_tasks ~S({"type":"system","subtype":"background_tasks_changed","tasks":[]})

  # control-protocol.md §1.2 PROBE: the initialize envelope, wrapped in its frame.
  @init_envelope ~S({"subtype":"success","request_id":"req_a","pending_permission_requests":[],"pending_user_dialog_requests":[]})

  # control-protocol.md §1.4.
  @keep_alive ~S({"type":"keep_alive"})

  defp line(frame), do: frame |> String.replace("\n", "") |> String.trim()
  defp json(frame), do: frame |> line() |> JSON.decode!()

  describe "control frames observed from the CLI" do
    test "can_use_tool classifies with its id, subtype and full request" do
      assert {:control_request, "a6395e9d-5eda-47d2-9f71-733c8aef7cd5", "can_use_tool", request} =
               Protocol.decode_line(line(@can_use_tool))

      assert request["tool_use_id"] == "toolu_mock_1"
      assert request["input"] == %{"command" => "echo hi > hi.txt", "description" => "say hi"}

      frame = Protocol.encode_control_request("a6395e9d-5eda-47d2-9f71-733c8aef7cd5", request)
      assert JSON.decode!(frame) == json(@can_use_tool)
    end

    test "control_cancel_request" do
      assert Protocol.decode_line(@cancel) ==
               {:control_cancel, "97a2d200-2530-4c43-8d71-e0e66f205c6b"}
    end

    test "the interrupt ack round-trips" do
      assert {:control_response, "req_int_1", {:ok, %{"still_queued" => []}} = result, _env} =
               Protocol.decode_line(@interrupt_ack)

      assert JSON.decode!(Protocol.encode_control_response("req_int_1", result)) ==
               json(@interrupt_ack)
    end

    test "an initialize reply keeps envelope-level pending_permission_requests" do
      frame = ~s({"type":"control_response","response":#{@init_envelope}})

      assert {:control_response, "req_a", {:ok, %{}}, envelope} = Protocol.decode_line(frame)
      assert envelope["pending_permission_requests"] == []
      assert envelope["pending_user_dialog_requests"] == []
    end

    test "a pending entry is a full frame that classifies like a live one" do
      envelope =
        @init_envelope
        |> JSON.decode!()
        |> Map.merge(%{
          "request_id" => "req_init_2",
          "pending_permission_requests" => [json(@can_use_tool)],
          "response" => %{"session_state" => "requires_action"}
        })

      frame = JSON.encode!(%{"type" => "control_response", "response" => envelope})

      assert {:control_response, "req_init_2", {:ok, %{"session_state" => "requires_action"}},
              %{"pending_permission_requests" => [entry]}} = Protocol.decode_line(frame)

      assert Protocol.classify(entry) == Protocol.decode_line(line(@can_use_tool))
    end

    test "an error reply" do
      frame =
        ~s({"type":"control_response","response":{"subtype":"error","request_id":"req_x",) <>
          ~s("error":"Unsupported control request subtype: no_such_subtype"}})

      assert {:control_response, "req_x",
              {:error, "Unsupported control request subtype: no_such_subtype"} = result, _env} =
               Protocol.decode_line(frame)

      assert JSON.decode!(Protocol.encode_control_response("req_x", result)) ==
               JSON.decode!(frame)
    end

    test "keep_alive and the re-initialize notice" do
      assert Protocol.decode_line(@keep_alive) == :keep_alive

      assert {:unknown, %{"subtype" => "background_tasks_changed"}} =
               Protocol.decode_line(@background_tasks)
    end

    test "control frames with non-string ids stay unknown" do
      for frame <- [
            ~s({"type":"control_request","request_id":1,"request":{"subtype":"interrupt"}}),
            ~s({"type":"control_request","request_id":"a","request":{"subtype":7}}),
            ~s({"type":"control_request","request_id":"a","request":[]}),
            ~s({"type":"control_response","response":{"subtype":"success","request_id":null}}),
            ~s({"type":"control_response","response":{"subtype":"weird","request_id":"a"}}),
            ~s({"type":"control_cancel_request","request_id":{}})
          ] do
        assert {:unknown, _} = Protocol.decode_line(frame)
      end
    end

    test "a success reply without a response body is an empty ok" do
      frame = ~s({"type":"control_response","response":{"subtype":"success","request_id":"a"}})
      assert {:control_response, "a", {:ok, %{}}, _} = Protocol.decode_line(frame)
    end
  end

  describe "control frames the host sends" do
    test "initialize and interrupt requests match the observed frames" do
      assert JSON.decode!(
               Protocol.encode_control_request("req_init_2", %{"subtype" => "initialize"})
             ) ==
               json(@reinit)

      assert JSON.decode!(
               Protocol.encode_control_request("req_int_1", %{"subtype" => "interrupt"})
             ) ==
               json(@interrupt)

      assert {:control_request, "req_init_2", "initialize", %{}} = Protocol.decode_line(@reinit)
    end

    test "allow always carries updatedInput" do
      input = %{"command" => "echo hi-from-host", "description" => "say hi (host edited)"}
      frame = Protocol.encode_permission("a6395e9d-…", {:allow, input})

      assert String.ends_with?(frame, "\n")
      assert JSON.decode!(frame) == json(@allow)

      unchanged = Protocol.encode_permission("id", {:allow, %{}})
      assert %{"response" => %{"response" => %{"updatedInput" => %{}}}} = JSON.decode!(unchanged)
    end

    test "allow with permission updates" do
      perms = [%{"type" => "setMode", "mode" => "acceptEdits", "destination" => "session"}]

      assert {:control_response, "id",
              {:ok,
               %{
                 "behavior" => "allow",
                 "updatedInput" => %{"a" => 1},
                 "updatedPermissions" => ^perms
               }}, _} =
               Protocol.decode_line(
                 Protocol.encode_permission("id", {:allow, %{"a" => 1}, perms})
               )
    end

    test "deny, and deny with interrupt" do
      deny =
        Protocol.encode_permission(
          "0c15f268-dd8d-4581-b1c1-70d5e47625ee",
          {:deny, "Denied by verify host"}
        )

      assert JSON.decode!(deny) == json(@deny)

      deny_interrupt =
        Protocol.encode_permission(
          "d3c22063-0de3-4b6d-a0c6-093f820d07a3",
          {:deny, "Denied by verify host", interrupt: true}
        )

      assert JSON.decode!(deny_interrupt) == json(@deny_interrupt)

      assert Protocol.encode_permission("x", {:deny, "m", interrupt: false}) ==
               Protocol.encode_permission("x", {:deny, "m"})
    end
  end
end
