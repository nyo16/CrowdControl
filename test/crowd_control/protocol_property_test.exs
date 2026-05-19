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
      result = Protocol.decode_line(input)

      assert match?({:system_init, _}, result) or
               match?({:assistant, _}, result) or
               match?({:user, _}, result) or
               match?({:result, _, _}, result) or
               match?({:stream_event, _}, result) or
               match?({:unknown, _}, result) or
               match?({:invalid_json, _}, result)
    end
  end
end
