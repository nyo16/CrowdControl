defmodule CrowdControl.Error do
  @moduledoc """
  A failed turn, classified.

  Built by `CrowdControl.Result.classify/1` from a `{:result, subtype, map}`
  message, and raised by `CrowdControl.run!/2`. Subscribers still receive the
  untyped `{:result, subtype, map}`; this struct is an interpretation of it,
  not a replacement.

  ## Fields

    * `:kind` - one atom from the closed set below.
    * `:reason` - kind-specific detail (see below), or `nil`.
    * `:session_id` - the agent's session id, when the result carries one.
    * `:subtype` - the result subtype exactly as the agent sent it (a binary).
    * `:raw` - the whole result map, for anything the classification dropped.

  ## Kinds

    * `:api_error` - the model API failed. `reason` is
      `%{category: category, status: integer | nil}`, where `category` is
      `:rate_limit` (429), `:overloaded` (529), `:server_error` (other 5xx),
      `:connection` (no HTTP response), or `:other` (any other status).
    * `:auth` - the API rejected the credentials (401/403, invalid key, login
      required). `reason` is the error text.
    * `:max_turns_exceeded` - `error_max_turns`. `reason` is `%{num_turns: n}`.
    * `:max_budget_exceeded` - `error_max_budget_usd`. `reason` is
      `%{cap: number | nil, cost_usd: number | nil, num_turns: n | nil}`.
    * `:execution_error` - `error_during_execution` for any reason other than
      aborted tools. `reason` is the error text.
    * `:aborted` - `error_during_execution` with `terminal_reason:
      "aborted_tools"`: the turn was interrupted, or a permission answer asked
      to stop. `reason` is the error text.
    * `:prompt_failed` - omp's `error_prompt_failed`: the agent rejected the
      prompt. `reason` is `%{message: text | nil, code: term}`.
    * `:session_error` - raised only by `CrowdControl.run!/2` when no result
      arrived at all. `reason` is the `run/2` error term (`:timeout`,
      `:session_exited`, a start failure...).
    * `:unknown` - a subtype this version does not know, or an error result
      whose cause could not be determined. Never raised by classification.
  """

  defexception [:kind, :reason, :session_id, :subtype, :raw]

  @type kind ::
          :api_error
          | :auth
          | :max_turns_exceeded
          | :max_budget_exceeded
          | :execution_error
          | :aborted
          | :prompt_failed
          | :session_error
          | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          reason: term(),
          session_id: String.t() | nil,
          subtype: String.t() | nil,
          raw: map() | nil
        }

  @kinds [
    :api_error,
    :auth,
    :max_turns_exceeded,
    :max_budget_exceeded,
    :execution_error,
    :aborted,
    :prompt_failed,
    :session_error,
    :unknown
  ]

  @doc "Every kind an error can carry."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @impl true
  def message(%__MODULE__{kind: kind, reason: reason, subtype: subtype}) do
    base = "#{kind}" <> if(is_binary(subtype), do: " (subtype #{inspect(subtype)})", else: "")

    case detail(kind, reason) do
      nil -> base
      text -> base <> ": " <> text
    end
  end

  defp detail(:api_error, %{category: category, status: status}) when is_integer(status),
    do: "#{category}, HTTP #{status}"

  defp detail(:api_error, %{category: category}), do: "#{category}"

  defp detail(:max_turns_exceeded, %{num_turns: n}) when is_integer(n), do: "after #{n} turns"

  defp detail(:max_budget_exceeded, %{cap: cap, cost_usd: cost}) when is_number(cost),
    do: "spent $#{cost}" <> if(is_number(cap), do: " of a $#{cap} cap", else: "")

  defp detail(:prompt_failed, %{message: message}) when is_binary(message), do: message
  defp detail(_kind, reason) when is_binary(reason) and reason != "", do: reason
  defp detail(:session_error, reason) when not is_nil(reason), do: inspect(reason)
  defp detail(_kind, _reason), do: nil
end
