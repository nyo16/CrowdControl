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

  Durations are in `:native` time units, as with `:telemetry.span/3`. Every
  session event's metadata carries `%{store_key, agent, backend}`.

    * `[:crowd_control, :session, :start]`: a session is up (provisioned and
      exec'd, or reattached). Measurements `%{system_time, monotonic_time}`.
    * `[:crowd_control, :session, :stop]`: the session process ended normally.
      Measurements `%{duration, monotonic_time}`; metadata adds
      `%{status, exit_status}`.
    * `[:crowd_control, :session, :exception]`: the session process ended
      abnormally. Measurements as `:stop`; metadata adds `%{kind, reason,
      stacktrace}`.
    * `[:crowd_control, :turn, :start]`: a prompt was written. Measurements
      `%{system_time, monotonic_time}`; metadata adds `%{turn}`.
    * `[:crowd_control, :turn, :stop]`: that prompt's result arrived.
      Measurements `%{duration, monotonic_time}`; metadata adds `%{turn,
      cost_usd, turn_cost_usd, subtype, error_kind}`. `cost_usd` is the CLI's
      cumulative `total_cost_usd`, `turn_cost_usd` this turn's share of it, and
      `error_kind` the `CrowdControl.Error` kind from
      `CrowdControl.Result.classify/1` (`nil` for a successful turn).
    * `[:crowd_control, :backend, :provision, :start | :stop | :exception]`: a
      `:telemetry.span/3` around `c:CrowdControl.Backend.provision/1`; stop
      metadata adds `%{result: :ok | :error}`.
    * `[:crowd_control, :control, :decision]`: one per `can_use_tool` request
      settled, measurements `%{system_time}`, metadata `%{store_key, request_id,
      tool_name, behavior, source}`. `behavior` is `:allow`, `:deny`, `:error`
      (no handler) or `:cancelled`; `source` is `:callback`, `:respond`,
      `:timeout` (`:permission_timeout`) or `:cancel` (withdrawn by the CLI).
      Answers are written to the CLI's stdin and never reach the output
      capture, so this event is their audit trail.
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
