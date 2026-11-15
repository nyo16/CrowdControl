defmodule CrowdControl.RetryTest do
  use ExUnit.Case, async: true

  alias CrowdControl.{RateLimit, Retry}

  def always(_result), do: true
  def tagged(_result, answer), do: answer

  defp api_error(status, fields \\ %{}) do
    map =
      Map.merge(
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => true,
          "terminal_reason" => "api_error",
          "api_error_status" => status,
          "num_turns" => 1
        },
        fields
      )

    {:result, "success", map}
  end

  describe "new!/1" do
    test "false and nil are off, true is the defaults, a keyword list overrides them" do
      assert Retry.new!(false) == nil
      assert Retry.new!(nil) == nil

      assert %Retry{max_retries: 3, base_delay_ms: 1_000, max_delay_ms: 30_000, multiplier: 2} =
               Retry.new!(true)

      assert %Retry{max_retries: 1, retry_on: {__MODULE__, :always, []}} =
               Retry.new!(max_retries: 1, retry_on: {__MODULE__, :always, []})
    end

    test "an unknown key or a bad value raises" do
      for bad <- [
            [max_attempts: 3],
            [max_retries: -1],
            [base_delay_ms: 1.5],
            [multiplier: 0.5],
            [retry_on: fn _ -> true end],
            :yes
          ] do
        assert_raise ArgumentError, fn -> Retry.new!(bad) end
      end
    end
  end

  describe "retryable?/2" do
    test "transient API failures from a tool-free turn are" do
      retry = Retry.new!(true)

      for status <- [429, 529, 500, 503] do
        assert Retry.retryable?(api_error(status), retry)
      end

      connection = api_error(nil, %{"result" => "API Error: Connection error."})
      assert Retry.retryable?(connection, retry)
      assert Retry.retryable?(api_error(529, %{"num_turns" => 0}), retry)

      {:result, subtype, map} = api_error(529)
      assert Retry.retryable?({:result, subtype, Map.delete(map, "num_turns")}, retry)
    end

    test "a turn that got further, a client error, auth, or success is not" do
      retry = Retry.new!(true)

      refute Retry.retryable?(api_error(529, %{"num_turns" => 3}), retry)
      refute Retry.retryable?(api_error(400), retry)
      refute Retry.retryable?(api_error(401), retry)
      refute Retry.retryable?({:result, "success", %{"is_error" => false}}, retry)
      refute Retry.retryable?({:error, :timeout}, retry)
    end

    test "retry_on widens the rule with the caller's MFA" do
      tool_turn = api_error(529, %{"num_turns" => 3})

      assert Retry.retryable?(tool_turn, Retry.new!(retry_on: {__MODULE__, :always, []}))
      refute Retry.retryable?(tool_turn, Retry.new!(retry_on: {__MODULE__, :tagged, [:nope]}))
    end
  end

  describe "delay/4" do
    test "full jitter within min(base * multiplier ** attempt, max)" do
      retry = Retry.new!(base_delay_ms: 100, multiplier: 3, max_delay_ms: 1_000)
      :rand.seed(:exsss, {1, 2, 3})

      for {attempt, ceiling} <- [{0, 100}, {1, 300}, {2, 900}, {3, 1_000}, {10, 1_000}] do
        delays = for _ <- 1..200, do: elem(Retry.delay(attempt, retry), 1)

        assert Enum.all?(delays, &(&1 in 0..ceiling))
        # Spread over the range, not pinned to one end.
        assert Enum.max(delays) > div(ceiling, 2) and Enum.min(delays) < div(ceiling, 2)
      end
    end

    test "a rejected rate limit waits until its reset, or gives up past max_delay_ms" do
      retry = Retry.new!(max_delay_ms: 30_000)
      now = 1_000_000_000_000

      soon = %RateLimit{status: :rejected, resets_at: div(now, 1_000) + 20}
      assert Retry.delay(0, retry, soon, now) == {:ok, 20_000}

      far = %RateLimit{status: :rejected, resets_at: div(now, 1_000) + 3_600}
      assert Retry.delay(0, retry, far, now) == :give_up
    end

    test "a reset in the past, a warning, or no reset time falls back to backoff" do
      retry = Retry.new!(base_delay_ms: 10, max_delay_ms: 30_000)
      now = 1_000_000_000_000

      for rate_limit <- [
            %RateLimit{status: :rejected, resets_at: div(now, 1_000) - 5},
            %RateLimit{status: :allowed_warning, resets_at: div(now, 1_000) + 3_600},
            %RateLimit{status: :rejected, resets_at: nil}
          ] do
        assert {:ok, delay} = Retry.delay(0, retry, rate_limit, now)
        assert delay in 0..10
      end
    end
  end
end
