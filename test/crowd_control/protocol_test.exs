defmodule CrowdControl.ProtocolTest do
  use ExUnit.Case, async: true

  alias CrowdControl.Protocol

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
  end
end
