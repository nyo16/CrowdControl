defmodule CrowdControl.Agent.OmpPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrowdControl.Agent.Omp

  @tags [:system_init, :assistant, :user, :result, :stream_event, :unknown, :invalid_json]

  defp tag({tag, _}), do: tag
  defp tag({tag, _, _}), do: tag

  property "decode_line/1 never raises on arbitrary binary" do
    check all(input <- StreamData.binary()) do
      assert tag(Omp.decode_line(input)) in @tags
    end
  end

  # The binary property above is necessary but not sufficient: it essentially
  # never produces a *well-formed* frame, so it cannot reach the classify
  # clauses at all. The bug this file exists for was a valid JSON object whose
  # field types differed from omp's current schema -- `"model"` as a bare id
  # string rather than an object. decode_line/1 runs inside
  # Session.handle_cast/2, so that raise killed the session outright.
  #
  # These generators build structurally plausible frames and randomize the
  # *types* of the values inside them.
  defp json_value do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.boolean(),
      StreamData.integer(),
      StreamData.string(:printable),
      StreamData.list_of(StreamData.string(:printable), max_length: 3),
      StreamData.map_of(StreamData.string(:alphanumeric), StreamData.integer(), max_length: 3),
      StreamData.list_of(
        StreamData.map_of(StreamData.string(:alphanumeric), StreamData.integer(), max_length: 2),
        max_length: 3
      )
    ])
  end

  defp frame_with(type, keys) do
    keys
    |> Enum.map(fn key -> StreamData.tuple({StreamData.constant(key), json_value()}) end)
    |> StreamData.fixed_list()
    |> StreamData.map(&Map.new([{"type", type} | &1]))
  end

  property "a get_state response with arbitrarily-typed fields decodes instead of raising" do
    payload_keys = ["sessionId", "sessionFile", "model", "dumpTools", "thinkingLevel"]

    check all(
            data <- frame_with("ignored", payload_keys) |> StreamData.map(&Map.delete(&1, "type"))
          ) do
      frame =
        JSON.encode!(%{
          "type" => "response",
          "command" => "get_state",
          "success" => true,
          "data" => data
        })

      assert {:system_init, init} = Omp.decode_line(frame)
      # The two invariants downstream code actually relies on.
      assert is_nil(init["session_id"]) or is_binary(init["session_id"])
      assert is_list(init["tools"])
    end
  end

  property "an agent_end with arbitrarily-typed fields decodes instead of raising" do
    check all(frame <- frame_with("agent_end", ["messages", "isTerminal"])) do
      assert tag(Omp.decode_line(JSON.encode!(frame))) in @tags
    end
  end

  property "arbitrary well-formed frames of every known type decode instead of raising" do
    types = ["response", "message_end", "message_update", "prompt_result", "ready", "agent_start"]
    keys = ["command", "success", "data", "message", "messages", "agentInvoked", "isTerminal"]

    check all(type <- StreamData.member_of(types), frame <- frame_with(type, keys)) do
      assert tag(Omp.decode_line(JSON.encode!(frame))) in @tags
    end
  end
end
