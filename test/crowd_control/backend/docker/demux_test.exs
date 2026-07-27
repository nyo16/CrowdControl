defmodule CrowdControl.Backend.Docker.DemuxTest do
  # Pure function, no Docker daemon required — these run unconditionally.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrowdControl.Backend.Docker.Demux

  doctest CrowdControl.Backend.Docker.Demux

  defp frame(type, payload) do
    <<type::8, 0::24, byte_size(payload)::32-big, payload::binary>>
  end

  defp stdout(payload), do: frame(1, payload)
  defp stderr(payload), do: frame(2, payload)

  defp feed_all(chunks) do
    {payloads, state} =
      Enum.reduce(chunks, {[], Demux.new()}, fn chunk, {acc, state} ->
        {out, state} = Demux.feed(state, chunk)
        {acc ++ out, state}
      end)

    {payloads, state}
  end

  describe "framing" do
    test "decodes a single stdout frame" do
      {payloads, state} = Demux.feed(Demux.new(), stdout("hello"))

      assert payloads == ["hello"]
      assert Demux.pending(state) == 0
    end

    test "decodes several frames in one feed" do
      data = stdout("one") <> stdout("two") <> stdout("three")
      {payloads, _} = Demux.feed(Demux.new(), data)

      assert payloads == ["one", "two", "three"]
    end

    test "drops stderr but stays in sync with the stream" do
      # The length field must be honoured even for dropped frames -- skipping
      # only the header would leave the payload to be misparsed as frames.
      data = stderr("this is a diagnostic") <> stdout("real output")
      {payloads, state} = Demux.feed(Demux.new(), data)

      assert payloads == ["real output"]
      assert Demux.pending(state) == 0
    end

    test "drops stdin frames too" do
      {payloads, _} = Demux.feed(Demux.new(), frame(0, "in") <> stdout("out"))
      assert payloads == ["out"]
    end

    test "handles an empty payload" do
      {payloads, state} = Demux.feed(Demux.new(), stdout(""))

      assert payloads == [""]
      assert Demux.pending(state) == 0
    end

    test "preserves binary payloads exactly, including newlines and UTF-8" do
      payload = "{\"a\":\"café-✓\"}\n{\"b\":1}\n"
      {payloads, _} = Demux.feed(Demux.new(), stdout(payload))

      assert payloads == [payload]
    end
  end

  describe "resumability across chunk boundaries" do
    test "a header split across two feeds" do
      f = stdout("abc")
      <<first::binary-size(3), rest::binary>> = f

      {payloads1, state} = Demux.feed(Demux.new(), first)
      assert payloads1 == []
      assert Demux.pending(state) == 3

      {payloads2, state} = Demux.feed(state, rest)
      assert payloads2 == ["abc"]
      assert Demux.pending(state) == 0
    end

    test "a payload split across three feeds" do
      f = stdout("abcdefghij")
      <<a::binary-size(9), b::binary-size(6), c::binary>> = f

      {payloads, state} = feed_all([a, b, c])
      assert payloads == ["abcdefghij"]
      assert Demux.pending(state) == 0
    end

    test "one byte at a time reconstructs every frame" do
      data = stdout("alpha") <> stderr("noise") <> stdout("beta")
      chunks = for <<byte <- data>>, do: <<byte>>

      {payloads, state} = feed_all(chunks)

      assert payloads == ["alpha", "beta"]
      assert Demux.pending(state) == 0
    end

    test "a stream cut mid-frame leaves bytes pending and emits nothing partial" do
      f = stdout("incomplete")
      truncated = binary_part(f, 0, byte_size(f) - 4)

      {payloads, state} = Demux.feed(Demux.new(), truncated)

      assert payloads == []
      assert Demux.pending(state) > 0
    end
  end

  describe "property: arbitrary chunk splits" do
    property "payloads are recovered regardless of how the stream is split" do
      check all(
              payloads <- list_of(binary(min_length: 0, max_length: 40), min_length: 1),
              split_points <- list_of(positive_integer())
            ) do
        stream = Enum.map_join(payloads, "", &stdout/1)
        chunks = split_binary(stream, split_points)

        {decoded, state} = feed_all(chunks)

        assert decoded == payloads
        assert Demux.pending(state) == 0
      end
    end

    property "interleaved stderr never corrupts stdout recovery" do
      check all(
              outs <- list_of(binary(max_length: 20), min_length: 1),
              errs <- list_of(binary(max_length: 20)),
              split_points <- list_of(positive_integer())
            ) do
        # Interleave: one stderr frame after each stdout frame we have noise for.
        stream =
          outs
          |> Enum.with_index()
          |> Enum.map_join("", fn {payload, i} ->
            case Enum.at(errs, i) do
              nil -> stdout(payload)
              err -> stdout(payload) <> stderr(err)
            end
          end)

        {decoded, state} = feed_all(split_binary(stream, split_points))

        assert decoded == outs
        assert Demux.pending(state) == 0
      end
    end
  end

  # Chop `binary` at the given offsets, mirroring arbitrary HTTP chunking.
  defp split_binary(binary, split_points) do
    size = byte_size(binary)

    points =
      split_points
      |> Enum.map(&rem(&1, max(size, 1)))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(&(&1 > 0 and &1 < size))

    {chunks, last} =
      Enum.reduce(points, {[], 0}, fn point, {acc, prev} ->
        {[binary_part(binary, prev, point - prev) | acc], point}
      end)

    Enum.reverse([binary_part(binary, last, size - last) | chunks])
  end
end
