defmodule CrowdControl.TestHelpers do
  @moduledoc false

  alias CrowdControl.Session

  @doc "Absolute path to the fake CLI shell script used by integration tests."
  def fake_cli_path do
    Path.expand("../support/fake_cli.sh", __DIR__)
  end

  @doc "Absolute path to the fake `omp --mode rpc` script used by integration tests."
  def fake_omp_path do
    Path.expand("../support/fake_omp_rpc.sh", __DIR__)
  end

  @doc """
  Stop a session, tolerating mailbox congestion. Falls back to a hard
  `Process.exit(pid, :kill)` if the GenServer.call times out.
  """
  def stop_session(pid) when is_pid(pid) do
    Session.stop(pid)
  catch
    :exit, _ ->
      Process.exit(pid, :kill)
      :ok
  end

  @doc """
  Poll `fun` until it returns true, or raise after `timeout` ms.

  Used to reach a deterministic point in a session's lifecycle (e.g. "the
  subprocess has finished") without sleeping for an arbitrary duration.
  """
  def wait_until(fun, timeout \\ 5_000, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, interval)
  end

  defp do_wait_until(fun, deadline, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "wait_until/3 timed out"

      true ->
        Process.sleep(interval)
        do_wait_until(fun, deadline, interval)
    end
  end

  @doc """
  Receive a `{:crowd_control, session, payload}` matching a guard, or fail
  after the given timeout.
  """
  defmacro assert_session_message(session, pattern, timeout \\ 2000) do
    quote do
      receive do
        {:crowd_control, unquote(session), unquote(pattern) = msg} -> msg
      after
        unquote(timeout) ->
          flunk(
            "did not receive #{Macro.to_string(unquote(Macro.escape(pattern)))} within #{unquote(timeout)}ms"
          )
      end
    end
  end
end
