defmodule CrowdControl.Result do
  @moduledoc """
  Interprets the `{:result, subtype, map}` message that ends every turn.

  Sessions broadcast results untyped, because that shape is the contract every
  agent normalises to. `classify/1` turns one into `{:ok, map}` or
  `{:error, %CrowdControl.Error{}}`, and the accessors read the fields both
  Claude Code and omp put on a result map.

      {:result, _, _} = result = CrowdControl.run("hi")

      case CrowdControl.Result.classify(result) do
        {:ok, map} -> map["result"]
        {:error, %CrowdControl.Error{kind: :api_error, reason: %{category: :rate_limit}}} -> :retry
        {:error, error} -> raise error
      end

  Classification never raises and never creates atoms: subtypes are matched
  against a fixed set of binaries and anything else is `:unknown`.

  ## Mapping

  | subtype | condition | kind |
  |---|---|---|
  | `success` | `is_error` not `true` | `{:ok, map}` |
  | `success` | `is_error: true` | `:auth`, `:api_error` or `:unknown`, from the text |
  | `error_max_turns` | | `:max_turns_exceeded` |
  | `error_max_budget_usd` | | `:max_budget_exceeded` |
  | `error_during_execution` | `terminal_reason: "aborted_tools"` | `:aborted` |
  | `error_during_execution` | API failure in the text | `:auth` or `:api_error` |
  | `error_during_execution` | otherwise | `:execution_error` |
  | `error_prompt_failed` (omp) | | `:prompt_failed` |
  | anything else | | `:unknown` |

  `:api_error` and `:auth` are read from the result's `"result"` text, its
  `"errors"` list and `"terminal_reason"`: Claude Code reports an API failure
  as an error result whose text is `"API Error: <status> <body>"`.
  """

  alias CrowdControl.Error

  @type result_message :: {:result, String.t(), map()}

  @doc """
  Classify a result message.

  Returns `{:ok, map}` for a successful turn and `{:error, %CrowdControl.Error{}}`
  otherwise. Any other input is `{:error, %CrowdControl.Error{kind: :unknown}}`.
  """
  @spec classify(result_message() | term()) :: {:ok, map()} | {:error, Error.t()}
  def classify({:result, subtype, map}) when is_map(map), do: do_classify(subtype, map)
  def classify({:result, subtype, _not_a_map}), do: do_classify(subtype, %{})

  def classify(_other),
    do: {:error, %Error{kind: :unknown, subtype: nil, raw: nil}}

  defp do_classify("success", map) do
    if map["is_error"] == true, do: error(api_or(:unknown, map), "success", map), else: {:ok, map}
  end

  defp do_classify("error_max_turns" = subtype, map),
    do: error({:max_turns_exceeded, %{num_turns: num_turns(map)}}, subtype, map)

  defp do_classify("error_max_budget_usd" = subtype, map) do
    reason = %{cap: budget_cap(map), cost_usd: cost_usd(map), num_turns: num_turns(map)}
    error({:max_budget_exceeded, reason}, subtype, map)
  end

  defp do_classify("error_during_execution" = subtype, map) do
    kind =
      if map["terminal_reason"] == "aborted_tools",
        do: {:aborted, text(map)},
        else: api_or(:execution_error, map)

    error(kind, subtype, map)
  end

  defp do_classify("error_prompt_failed" = subtype, map) do
    message = if is_binary(map["result"]), do: map["result"]
    error({:prompt_failed, %{message: message, code: map["error_code"]}}, subtype, map)
  end

  defp do_classify(subtype, map), do: error({:unknown, text(map)}, subtype, map)

  defp error({kind, reason}, subtype, map) do
    {:error,
     %Error{
       kind: kind,
       reason: reason,
       subtype: if(is_binary(subtype), do: subtype),
       session_id: session_id(map),
       raw: map
     }}
  end

  # --- API failures ---

  # `fallback` is the kind used when the text shows no API failure at all.
  defp api_or(fallback, map) do
    text = text(map)
    status = status(text)

    cond do
      auth?(status, text) ->
        {:auth, text}

      api_failure?(map, status, text) ->
        {:api_error, %{category: category(status, text), status: status}}

      true ->
        {fallback, text}
    end
  end

  defp auth?(status, _text) when status in [401, 403], do: true

  defp auth?(_status, text),
    do: Regex.match?(~r/invalid api key|authentication_error|please run \/login/i, text)

  defp api_failure?(map, status, text) do
    map["terminal_reason"] == "api_error" or is_integer(status) or
      Regex.match?(~r/api error|rate_limit_error|overloaded_error/i, text)
  end

  # `API Error: 529 {...}` is Claude Code's format; the JSON body's
  # `"status": 529` and a bare `status 429` cover the variants seen in SDKs.
  defp status(text) do
    case Regex.run(~r/(?:api error:?|status(?:\s+code)?"?\s*[:=]?)\s*(\d{3})\b/i, text) do
      [_, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  defp category(429, _text), do: :rate_limit
  defp category(529, _text), do: :overloaded
  defp category(status, _text) when status in 500..599, do: :server_error
  defp category(status, _text) when is_integer(status), do: :other

  defp category(nil, text) do
    cond do
      Regex.match?(~r/rate.?limit/i, text) -> :rate_limit
      Regex.match?(~r/overloaded/i, text) -> :overloaded
      Regex.match?(~r/api_error|internal server error|server error/i, text) -> :server_error
      true -> :connection
    end
  end

  # Everything human-readable the result carries, as one binary. Never raises:
  # non-binary entries are skipped.
  defp text(map) do
    errors = if is_list(map["errors"]), do: map["errors"], else: []

    [map["result"] | errors]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  # Claude Code puts the cap only in the error text ("Reached maximum budget
  # ($0.50)"); a `max_budget_usd` field wins if a future CLI adds one.
  defp budget_cap(%{"max_budget_usd" => cap}) when is_number(cap), do: cap

  defp budget_cap(map) do
    case Regex.run(~r/\$(\d+(?:\.\d+)?)/, text(map)) do
      [_, amount] -> parse_number(amount)
      nil -> nil
    end
  end

  defp parse_number(amount) do
    case Float.parse(amount) do
      {value, ""} -> value
      _ -> nil
    end
  end

  # --- accessors ---

  @doc "The turn's `total_cost_usd`, or `nil` when absent."
  @spec cost_usd(result_message() | map() | Error.t()) :: number() | nil
  def cost_usd(result), do: number_field(result, "total_cost_usd")

  @doc "The agent's `session_id`, or `nil` when absent."
  @spec session_id(result_message() | map() | Error.t()) :: String.t() | nil
  def session_id(result) do
    case field(result, "session_id") do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  @doc "The turn's `num_turns`, or `nil` when absent."
  @spec num_turns(result_message() | map() | Error.t()) :: non_neg_integer() | nil
  def num_turns(result) do
    case field(result, "num_turns") do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  @doc "The turn's `permission_denials` list, or `[]` when absent."
  @spec permission_denials(result_message() | map() | Error.t()) :: [map()]
  def permission_denials(result) do
    case field(result, "permission_denials") do
      denials when is_list(denials) -> denials
      _ -> []
    end
  end

  defp number_field(result, key) do
    case field(result, key) do
      n when is_number(n) -> n
      _ -> nil
    end
  end

  defp field({:result, _subtype, map}, key), do: field(map, key)
  defp field(%Error{raw: map}, key), do: field(map, key)
  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_other, _key), do: nil
end
