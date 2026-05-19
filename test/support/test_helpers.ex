defmodule CrowdControl.TestHelpers do
  @moduledoc false

  @doc "Absolute path to the fake CLI shell script used by integration tests."
  def fake_cli_path do
    Path.expand("../support/fake_cli.sh", __DIR__)
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
