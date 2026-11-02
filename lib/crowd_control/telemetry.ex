defmodule CrowdControl.Telemetry do
  @moduledoc """
  `:telemetry` emits that cost nothing when `:telemetry` is not installed.

  `:telemetry` is an optional dependency of this library. Every event
  CrowdControl emits goes through `execute/3` or `span/3`, which have the same
  signatures and return values as `:telemetry.execute/3` and `:telemetry.span/3`
  and fall through to a no-op when the `:telemetry` module cannot be loaded.

  To receive events, add `{:telemetry, "~> 1.0"}` to your own dependencies (it
  is usually there already, through Req or Finch) and attach a handler:

      :telemetry.attach("gce", [:crowd_control, :gce, :phase], &MyApp.handle/4, nil)

  ## Events

    * `[:crowd_control, :gce, :phase]`: one per `CrowdControl.Provider.Gce`
      acquire phase, measurements `%{duration_ms}`, metadata
      `%{phase, result, instance_name, zone}`.
  """

  # The calls below are guarded by available?/0, so a consumer without
  # :telemetry never reaches them; this keeps that consumer's compile clean.
  @compile {:no_warn_undefined, :telemetry}

  @available_key {__MODULE__, :available?}

  @doc "Same as `:telemetry.execute/3`; returns `:ok` without emitting when `:telemetry` is absent."
  @spec execute([atom(), ...], map() | number(), map()) :: :ok
  def execute(event_name, measurements, metadata) do
    if available?(), do: :telemetry.execute(event_name, measurements, metadata), else: :ok
  end

  @doc """
  Same as `:telemetry.span/3`; when `:telemetry` is absent, runs `fun` and
  returns its result without emitting.

  `fun` returns `{result, stop_metadata}` or
  `{result, extra_measurements, stop_metadata}`.
  """
  @spec span([atom(), ...], map(), (-> {result, map()} | {result, map(), map()})) :: result
        when result: term()
  def span(event_prefix, start_metadata, fun) do
    if available?() do
      :telemetry.span(event_prefix, start_metadata, fun)
    else
      case fun.() do
        {result, _stop_metadata} -> result
        {result, _extra_measurements, _stop_metadata} -> result
      end
    end
  end

  # Checked once per VM: a code-server round trip on every emit would cost more
  # than the emit. The answer cannot change without a code reload, and a
  # persistent_term write happens exactly once.
  defp available? do
    case :persistent_term.get(@available_key, nil) do
      nil ->
        available = Code.ensure_loaded?(:telemetry)
        :persistent_term.put(@available_key, available)
        available

      available ->
        available
    end
  end
end
