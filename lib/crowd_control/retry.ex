defmodule CrowdControl.Retry do
  @moduledoc """
  When and how long to wait before re-sending a failed prompt; the policy
  behind the `:retry` option of `CrowdControl.run/2` and
  `CrowdControl.run_many/3`.

  Pure: `CrowdControl` does the sleeping and the re-sending, into the same
  session.

  ## What is retried

  By default only a result that is safe to send again: an `:api_error` (see
  `CrowdControl.Result.classify/1`) of category `:rate_limit`, `:overloaded`,
  `:server_error` or `:connection`, from a turn that ran at most one
  agentic step (`num_turns` absent, 0 or 1). A turn that got further may have
  run tools, and running them twice is the caller's call: `retry_on`
  widens the rule with an MFA, called as `apply(m, f, [result | extra_args])`,
  whose `true` makes any result retryable.

  ## Options

    * `:max_retries` - re-sends after the first attempt (default `3`)
    * `:base_delay_ms` - the first delay (default `1_000`)
    * `:multiplier` - growth per attempt, at least 1 (default `2`)
    * `:max_delay_ms` - the delay ceiling (default `30_000`)
    * `:retry_on` - `{module, function, extra_args}`, see above

  The delay before re-send `n` (counting from 0) is a uniform random pick in
  `0..min(base_delay_ms * multiplier ** n, max_delay_ms)` ("full jitter"), so a
  fleet that failed together does not retry together. When the session last
  reported a `:rejected` `CrowdControl.RateLimit` whose `resets_at` is still
  ahead, the delay is the time until then instead, and a reset further away
  than `:max_delay_ms` is not waited for: the result is returned as it is.
  """

  alias CrowdControl.{Error, RateLimit, Result}

  @retryable [:rate_limit, :overloaded, :server_error, :connection]

  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          multiplier: number(),
          retry_on: {module(), atom(), list()} | nil
        }

  defstruct max_retries: 3,
            base_delay_ms: 1_000,
            max_delay_ms: 30_000,
            multiplier: 2,
            retry_on: nil

  @doc """
  A validated policy from a `:retry` option: `false` (or `nil`) is no retry,
  `true` the defaults, a keyword list overrides them. Raises `ArgumentError` on
  an unknown key or a bad value.
  """
  @spec new!(boolean() | keyword() | nil) :: t() | nil
  def new!(off) when off in [nil, false], do: nil
  def new!(true), do: %__MODULE__{}

  def new!(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, Map.keys(Map.from_struct(%__MODULE__{})))
    Enum.each(opts, &check!/1)
    struct!(__MODULE__, opts)
  end

  def new!(other),
    do: raise(ArgumentError, ":retry must be a boolean or a keyword list, got: #{inspect(other)}")

  defp check!({key, n})
       when key in [:max_retries, :base_delay_ms, :max_delay_ms] and is_integer(n) and n >= 0,
       do: :ok

  defp check!({:multiplier, m}) when is_number(m) and m >= 1, do: :ok
  defp check!({:retry_on, nil}), do: :ok

  # Checked here, before any session starts: a typo found at the first failed
  # result would surface mid-run instead.
  defp check!({:retry_on, {m, f, a}}) when is_atom(m) and is_atom(f) and is_list(a) do
    unless Code.ensure_loaded?(m) and function_exported?(m, f, length(a) + 1) do
      raise ArgumentError,
            ":retry_on #{inspect(m)}.#{f}/#{length(a) + 1} is not defined " <>
              "(it is called with the result prepended to extra_args)"
    end
  end

  defp check!({:retry_on, other}) do
    raise ArgumentError,
          ":retry_on must be an MFA tuple {module, function, extra_args}, got: #{inspect(other)}"
  end

  defp check!({key, value}),
    do: raise(ArgumentError, "invalid :retry option #{inspect(key)}: #{inspect(value)}")

  @doc "Whether `result` may be sent again under `retry` (see the moduledoc)."
  @spec retryable?(Result.result_message() | term(), t()) :: boolean()
  def retryable?(result, %__MODULE__{} = retry), do: safe?(result) or retry_on?(result, retry)

  defp safe?(result) do
    case Result.classify(result) do
      {:error, %Error{kind: :api_error, reason: %{category: category}}}
      when category in @retryable ->
        Result.num_turns(result) in [nil, 0, 1]

      _other ->
        false
    end
  end

  defp retry_on?(_result, %__MODULE__{retry_on: nil}), do: false
  defp retry_on?(result, %__MODULE__{retry_on: {m, f, a}}), do: apply(m, f, [result | a]) == true

  @doc """
  The delay in ms before re-send `attempt` (0 for the first), or `:give_up`
  when the session's rate limit resets later than `:max_delay_ms` from now.

  `rate_limit` is the session's latest `CrowdControl.RateLimit`, if any;
  `now_ms` is the current `System.system_time(:millisecond)`.
  """
  @spec delay(non_neg_integer(), t(), RateLimit.t() | nil, integer()) ::
          {:ok, non_neg_integer()} | :give_up
  def delay(attempt, %__MODULE__{} = retry, rate_limit \\ nil, now_ms \\ now_ms()) do
    case until_reset(rate_limit, now_ms) do
      wait when is_integer(wait) and wait > retry.max_delay_ms -> :give_up
      wait when is_integer(wait) -> {:ok, wait}
      nil -> {:ok, jittered(attempt, retry)}
    end
  end

  # Only a rejection says the account is out of quota; `resets_at` is in Unix
  # seconds. A reset already behind us is no reason to wait.
  defp until_reset(%RateLimit{status: :rejected, resets_at: at}, now_ms) when is_integer(at) do
    wait = at * 1_000 - now_ms
    if wait > 0, do: wait
  end

  defp until_reset(_rate_limit, _now_ms), do: nil

  defp jittered(attempt, retry) do
    ceiling = min(round(retry.base_delay_ms * retry.multiplier ** attempt), retry.max_delay_ms)
    :rand.uniform(ceiling + 1) - 1
  end

  defp now_ms, do: System.system_time(:millisecond)

  @doc "The `CrowdControl.Error` category of a result, for telemetry; `nil` when it has none."
  @spec category(term()) :: atom() | nil
  def category(result) do
    case Result.classify(result) do
      {:error, %Error{reason: %{category: category}}} -> category
      _other -> nil
    end
  end
end
