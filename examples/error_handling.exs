# Demonstrate the structured error surface: timeout, oversize prompt,
# missing executable.
#
#   mix run examples/error_handling.exs

api_key = System.fetch_env!("ANTHROPIC_API_KEY")

IO.puts("--- timeout ---")

IO.inspect(
  CrowdControl.run("Write an essay about the moon.",
    model: "sonnet",
    api_key: api_key,
    timeout: 100
  )
)

IO.puts("\n--- prompt too large ---")

case CrowdControl.start_session(max_prompt_size: 5, api_key: api_key, timeout: 10_000) do
  {:ok, session} ->
    IO.inspect(CrowdControl.Session.send_prompt(session, "way too long"))
    CrowdControl.Session.stop(session)

  other ->
    IO.inspect(other)
end

IO.puts("\n--- nonexistent executable ---")

IO.inspect(
  CrowdControl.run("hello",
    executable: "/nonexistent/binary",
    api_key: api_key,
    timeout: 2_000
  )
)
