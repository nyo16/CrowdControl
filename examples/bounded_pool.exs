# Saturate the supervisor's max_sessions cap and observe graceful
# degradation. Adjust via:
#
#   config :crowd_control, :max_sessions, 5
#
#   mix run examples/bounded_pool.exs

api_key = System.fetch_env!("ANTHROPIC_API_KEY")
cap = Application.get_env(:crowd_control, :max_sessions, 50)

IO.puts("Attempting to start #{cap + 2} sessions against a cap of #{cap}")

results =
  for i <- 1..(cap + 2) do
    case CrowdControl.start_session(api_key: api_key, timeout: 60_000) do
      {:ok, pid} -> {:ok, i, pid}
      {:error, reason} -> {:error, i, reason}
    end
  end

Enum.each(results, fn
  {:ok, i, pid} -> IO.puts("session #{i}: ok #{inspect(pid)}")
  {:error, i, reason} -> IO.puts("session #{i}: error #{inspect(reason)}")
end)

pids = for {:ok, _i, pid} <- results, do: pid
CrowdControl.stop_all(pids)
