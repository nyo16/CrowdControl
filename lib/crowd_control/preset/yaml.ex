defmodule CrowdControl.Preset.YAML do
  @moduledoc false
  # The smallest YAML emitter the presets need, and deliberately no parser.
  #
  # Every string scalar is written JSON-quoted, which is a valid YAML
  # double-quoted scalar: whatever a caller put in a domain, a label or a URL
  # cannot open a new key, a new document or an anchor. Mappings are lists of
  # `{key, value}` pairs so the rendered order is the order written here, which
  # keeps a config diffable and a test assertion stable.
  #
  # Values: a binary, an integer, a boolean, `nil`, a list of `{key, value}`
  # pairs (a mapping), any other list (a sequence), or `{:block, text}` for a
  # literal block scalar (`|`), whose text the caller owns.

  @bare_key ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @doc false
  @spec encode([{String.t(), term()}]) :: String.t()
  def encode(pairs) when is_list(pairs), do: IO.iodata_to_binary(mapping(pairs, 0))

  defp mapping(pairs, indent) do
    Enum.map(pairs, fn {key, value} -> [pad(indent), key(key), ":", value(value, indent)] end)
  end

  defp value({:block, text}, indent) do
    lines = text |> String.trim_trailing("\n") |> String.split("\n")
    [" |\n", Enum.map(lines, &block_line(&1, indent + 2))]
  end

  defp value([], _indent), do: " []\n"

  defp value([{_key, _value} | _] = pairs, indent), do: ["\n", mapping(pairs, indent + 2)]

  defp value(list, indent) when is_list(list), do: ["\n", Enum.map(list, &item(&1, indent + 2))]

  defp value(scalar, _indent), do: [" ", scalar(scalar), "\n"]

  defp block_line("", _indent), do: "\n"
  defp block_line(line, indent), do: [pad(indent), line, "\n"]

  # A mapping inside a sequence starts on the dash line: rendered two deeper,
  # then its first line's indentation is swapped for the dash.
  defp item([{_key, _value} | _] = pairs, indent) do
    [first | rest] = pairs |> mapping(indent + 2) |> Enum.map(&IO.iodata_to_binary/1)
    [pad(indent), "- ", String.trim_leading(first) | rest]
  end

  defp item(scalar, indent), do: [pad(indent), "- ", scalar(scalar), "\n"]

  defp key(key) when is_binary(key) do
    if Regex.match?(@bare_key, key), do: key, else: JSON.encode!(key)
  end

  defp scalar(nil), do: "null"
  defp scalar(value) when is_boolean(value), do: to_string(value)
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_binary(value), do: JSON.encode!(value)

  defp pad(indent), do: String.duplicate(" ", indent)
end
