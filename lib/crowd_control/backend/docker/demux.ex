defmodule CrowdControl.Backend.Docker.Demux do
  @moduledoc """
  Docker multiplexed-stream framing.

  When a container is created without a TTY, the Engine API interleaves stdout
  and stderr on one connection using an 8-byte header per frame:

      <<stream_type::8, 0::24, length::32-big, payload::binary-size(length)>>

  where `stream_type` is `0` stdin, `1` stdout, `2` stderr.

  ## Why this is resumable

  Frames do not align with HTTP chunk boundaries. A header can arrive split
  across two chunks — three bytes in one, five in the next — and a payload can
  span several. So this is a feed/state machine rather than a parser over a
  complete binary: `feed/2` returns whatever complete payloads it can and
  carries the remainder forward. It deliberately mirrors the pure-function shape
  of `CrowdControl.Protocol.split_lines/1`.

  ## Only stdout survives

  Stream types other than `1` are dropped. CrowdControl controls the exec
  command, so stdout carries the CLI's stream-json and nothing else; stderr is
  diagnostic noise that would corrupt the JSON line stream if merged into it.
  Stderr frames really do occur in practice — a `tail` against a missing file
  produces them — so this is load-bearing, not defensive.

      iex> alias CrowdControl.Backend.Docker.Demux
      iex> frame = <<1, 0, 0, 0, 0, 0, 0, 5, "hello">>
      iex> {payloads, _state} = Demux.feed(Demux.new(), frame)
      iex> payloads
      ["hello"]
  """

  @stdout 1

  @typedoc "Opaque demux state; carries the bytes of an incomplete frame."
  @opaque t :: %__MODULE__{buffer: binary()}

  defstruct buffer: ""

  @doc "A demux state with nothing buffered."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed bytes in, get complete stdout payloads out.

  Returns `{payloads, state}`. Pass `state` to the next call.

      iex> alias CrowdControl.Backend.Docker.Demux
      iex> # a header split across two feeds
      iex> {[], s} = Demux.feed(Demux.new(), <<1, 0, 0>>)
      iex> {payloads, _s} = Demux.feed(s, <<0, 0, 0, 0, 3, "abc">>)
      iex> payloads
      ["abc"]

      iex> alias CrowdControl.Backend.Docker.Demux
      iex> # stderr (type 2) is dropped, stdout (type 1) survives
      iex> err = <<2, 0, 0, 0, 0, 0, 0, 3, "err">>
      iex> out = <<1, 0, 0, 0, 0, 0, 0, 2, "ok">>
      iex> {payloads, _s} = Demux.feed(Demux.new(), err <> out)
      iex> payloads
      ["ok"]
  """
  @spec feed(t(), binary()) :: {[binary()], t()}
  def feed(%__MODULE__{buffer: buffer}, data) when is_binary(data) do
    {payloads, rest} = parse(buffer <> data, [])
    {payloads, %__MODULE__{buffer: rest}}
  end

  @doc """
  Bytes currently held for an incomplete frame.

  Non-zero at end of stream means the stream was cut mid-frame.
  """
  @spec pending(t()) :: non_neg_integer()
  def pending(%__MODULE__{buffer: buffer}), do: byte_size(buffer)

  # A complete stdout frame: emit the payload.
  defp parse(<<@stdout, _::24, len::32-big, payload::binary-size(len), rest::binary>>, acc) do
    parse(rest, [payload | acc])
  end

  # A complete frame on any other stream: consume and discard it. Matching the
  # length is what keeps the stream in sync -- skipping the header alone would
  # leave the payload to be misread as frames.
  defp parse(<<_type, _::24, len::32-big, _payload::binary-size(len), rest::binary>>, acc) do
    parse(rest, acc)
  end

  # Anything else is an incomplete frame: too few bytes for a header, or a
  # header whose payload has not fully arrived. Carry it forward.
  defp parse(rest, acc), do: {Enum.reverse(acc), rest}
end
