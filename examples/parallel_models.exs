# Run the same prompt across multiple models in parallel and print
# the results side by side. Demonstrates `CrowdControl.run_many/2`.
#
#   mix run examples/parallel_models.exs

api_key = System.fetch_env!("ANTHROPIC_API_KEY")

opts_list = [
  [model: "sonnet", api_key: api_key, timeout: 60_000],
  [model: "opus", api_key: api_key, timeout: 60_000],
  [model: "haiku", api_key: api_key, timeout: 60_000]
]

results = CrowdControl.run_many("In one sentence: what is OTP?", opts_list)

case results do
  {:timeout, partial} ->
    IO.puts("Only #{length(partial)} of #{length(opts_list)} finished in time.")
    Enum.each(partial, fn {_pid, {:result, _, %{"result" => r}}} -> IO.puts(r) end)

  results when is_list(results) ->
    Enum.each(results, fn {pid, {:result, _, %{"result" => r}}} ->
      IO.puts("--- #{inspect(pid)} ---")
      IO.puts(r)
    end)
end
