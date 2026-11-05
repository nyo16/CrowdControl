defmodule CrowdControl.ProtocolPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrowdControl.Protocol

  property "split_lines/1 returns lines that joined with \\n + remainder reproduce the input" do
    check all(buffer <- StreamData.binary()) do
      {lines, remainder} = Protocol.split_lines(buffer)
      reconstructed = Enum.join(lines ++ [remainder], "\n")
      assert reconstructed == buffer
    end
  end

  property "split_lines/1 never returns a remainder containing a newline" do
    check all(buffer <- StreamData.binary()) do
      {_lines, remainder} = Protocol.split_lines(buffer)
      refute String.contains?(remainder, "\n")
    end
  end

  property "encode_user_message/1 round-trips through decode_line/1" do
    check all(prompt <- StreamData.string(:printable)) do
      encoded = Protocol.encode_user_message(prompt)
      [line] = String.split(encoded, "\n", trim: true)

      assert {:user, %{"message" => %{"content" => ^prompt, "role" => "user"}}} =
               Protocol.decode_line(line)
    end
  end

  property "decode_line/1 never raises on arbitrary binary" do
    check all(input <- StreamData.binary()) do
      assert message?(Protocol.decode_line(input))
    end
  end

  property "classify/1 never raises on arbitrary maps, control-shaped or not" do
    check all(map <- frame_like()) do
      assert message?(Protocol.classify(map))
    end
  end

  property "control frames survive a JSON round trip unchanged" do
    check all(
            id <- StreamData.string(:printable),
            subtype <- StreamData.string(:alphanumeric, min_length: 1),
            body <- StreamData.map_of(StreamData.string(:alphanumeric), json_leaf())
          ) do
      request = Map.put(body, "subtype", subtype)

      assert {:control_request, ^id, ^subtype, ^request} =
               id |> Protocol.encode_control_request(request) |> Protocol.decode_line()

      assert {:control_response, ^id, {:ok, ^body}, _} =
               id |> Protocol.encode_control_response({:ok, body}) |> Protocol.decode_line()
    end
  end

  defp message?({tag, _}) when tag in [:system_init, :assistant, :user, :stream_event],
    do: true

  defp message?({:result, _, _}), do: true

  defp message?({:control_request, id, subtype, request}),
    do: is_binary(id) and is_binary(subtype) and is_map(request)

  defp message?({:control_response, id, {tag, _}, envelope}),
    do: is_binary(id) and tag in [:ok, :error] and is_map(envelope)

  defp message?({:control_cancel, id}), do: is_binary(id)
  defp message?(:keep_alive), do: true
  defp message?({:unknown, map}), do: is_map(map)
  defp message?({:invalid_json, raw}), do: is_binary(raw)
  defp message?(_other), do: false

  # Maps that look like stream-json frames often enough to reach every clause:
  # each expected key is present or dropped at random, and holds either the
  # value type the clause expects or any other JSON value.
  defp frame_like do
    StreamData.one_of([
      some_keys(%{
        "type" =>
          StreamData.member_of(
            ~w(control_request control_response control_cancel_request keep_alive system result user)
          ),
        "request_id" => id_or_junk(),
        "request" => StreamData.one_of([envelope_like(), json_value()]),
        "response" => StreamData.one_of([envelope_like(), json_value()])
      }),
      StreamData.map_of(StreamData.string(:alphanumeric), json_value(), max_length: 4)
    ])
  end

  defp envelope_like do
    some_keys(%{
      "subtype" =>
        StreamData.one_of([StreamData.member_of(~w(success error initialize)), json_value()]),
      "request_id" => id_or_junk(),
      "response" => json_value(),
      "error" => json_value(),
      "pending_permission_requests" => json_value()
    })
  end

  defp id_or_junk, do: StreamData.one_of([StreamData.string(:alphanumeric), json_value()])

  defp some_keys(generators) do
    StreamData.bind(StreamData.fixed_map(generators), fn map ->
      StreamData.map(StreamData.list_of(StreamData.member_of(Map.keys(map))), &Map.drop(map, &1))
    end)
  end

  defp json_leaf do
    StreamData.one_of([
      StreamData.string(:printable),
      StreamData.integer(),
      StreamData.boolean(),
      StreamData.constant(nil)
    ])
  end

  defp json_value do
    StreamData.tree(json_leaf(), fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 3),
        StreamData.map_of(StreamData.string(:alphanumeric), child, max_length: 3)
      ])
    end)
  end
end
