defmodule CrowdControl.Protocol do
  @moduledoc """
  Pure functions for the Claude Code stream-json wire format.

  Messages are newline-delimited JSON objects on stdin/stdout.
  """

  @type message ::
          {:system_init, map()}
          | {:assistant, map()}
          | {:user, map()}
          | {:result, String.t(), map()}
          | {:stream_event, map()}
          | {:unknown, map()}
          | {:invalid_json, String.t()}

  @doc """
  Splits a binary buffer into complete lines and a remainder.

  Returns `{complete_lines, remainder}` where `complete_lines` is a list
  of binaries (without the trailing newline) and `remainder` is the
  incomplete trailing fragment (possibly empty).
  """
  @spec split_lines(binary()) :: {[binary()], binary()}
  def split_lines(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [only] -> {[], only}
      parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
    end
  end

  @doc """
  Decodes a single JSON line into a tagged tuple.

  Returns one of:
    - `{:system_init, map}`
    - `{:assistant, map}`
    - `{:user, map}`
    - `{:result, subtype, map}`
    - `{:stream_event, map}`
    - `{:unknown, map}`
    - `{:invalid_json, raw_line}` when the input is not valid JSON

  Does not raise; callers can safely pass arbitrary subprocess output.
  """
  @spec decode_line(binary()) :: message()
  def decode_line(json_string) when is_binary(json_string) do
    case JSON.decode(json_string) do
      {:ok, map} when is_map(map) -> classify(map)
      {:ok, _other} -> {:invalid_json, json_string}
      {:error, _reason} -> {:invalid_json, json_string}
    end
  end

  defp classify(%{"type" => "system", "subtype" => "init"} = map), do: {:system_init, map}
  defp classify(%{"type" => "assistant"} = map), do: {:assistant, map}
  defp classify(%{"type" => "user"} = map), do: {:user, map}

  defp classify(%{"type" => "result", "subtype" => subtype} = map),
    do: {:result, subtype, map}

  defp classify(%{"type" => "stream_event"} = map), do: {:stream_event, map}
  defp classify(map), do: {:unknown, map}

  @doc """
  Encodes a user prompt as a stream-json stdin message.

  Returns a newline-terminated JSON string.
  """
  @spec encode_user_message(binary()) :: binary()
  def encode_user_message(prompt) when is_binary(prompt) do
    message = %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => prompt}
    }

    JSON.encode!(message) <> "\n"
  end
end
