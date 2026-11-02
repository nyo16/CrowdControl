defmodule CrowdControl.TelemetryWrapperTest do
  # Handlers are global.
  use ExUnit.Case, async: false

  alias CrowdControl.Telemetry

  setup context do
    test_pid = self()
    handler_id = {__MODULE__, context.test}

    :telemetry.attach_many(
      handler_id,
      [
        [:crowd_control, :wrapper_test, :event],
        [:crowd_control, :wrapper_test, :span, :start],
        [:crowd_control, :wrapper_test, :span, :stop],
        [:crowd_control, :wrapper_test, :span, :exception]
      ],
      &__MODULE__.forward/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def forward(event, measurements, metadata, test_pid),
    do: send(test_pid, {:event, event, measurements, metadata})

  test "execute/3 reaches an attached handler" do
    assert :ok = Telemetry.execute([:crowd_control, :wrapper_test, :event], %{n: 1}, %{k: :v})
    assert_received {:event, [:crowd_control, :wrapper_test, :event], %{n: 1}, %{k: :v}}
  end

  test "span/3 emits a start/stop pair and returns the function's result" do
    assert :value =
             Telemetry.span([:crowd_control, :wrapper_test, :span], %{phase: :a}, fn ->
               {:value, %{phase: :a, outcome: :ok}}
             end)

    assert_received {:event, [:crowd_control, :wrapper_test, :span, :start], %{monotonic_time: _},
                     %{phase: :a}}

    assert_received {:event, [:crowd_control, :wrapper_test, :span, :stop], %{duration: _},
                     %{phase: :a, outcome: :ok}}
  end

  test "span/3 emits :exception and reraises when the function raises" do
    assert_raise RuntimeError, "boom", fn ->
      Telemetry.span([:crowd_control, :wrapper_test, :span], %{}, fn -> raise "boom" end)
    end

    assert_received {:event, [:crowd_control, :wrapper_test, :span, :exception], %{duration: _},
                     %{kind: :error}}
  end

  describe "without :telemetry" do
    # Stands in for a consumer that never installed :telemetry: the wrapper
    # consults its cached probe, so forcing it false exercises the no-op path.
    setup do
      key = {Telemetry, :available?}
      previous = :persistent_term.get(key, nil)
      :persistent_term.put(key, false)

      on_exit(fn ->
        if is_nil(previous),
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, previous)
      end)
    end

    test "execute/3 returns :ok and emits nothing" do
      assert :ok = Telemetry.execute([:crowd_control, :wrapper_test, :event], %{}, %{})
      refute_received {:event, _, _, _}
    end

    test "span/3 returns the result for both return shapes and emits nothing" do
      prefix = [:crowd_control, :wrapper_test, :span]
      assert 1 = Telemetry.span(prefix, %{}, fn -> {1, %{}} end)
      assert 2 = Telemetry.span(prefix, %{}, fn -> {2, %{extra: 1}, %{}} end)
      refute_received {:event, _, _, _}
    end
  end
end
