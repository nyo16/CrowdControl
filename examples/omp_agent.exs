# Drive the omp CLI (https://omp.sh/) over its JSON-RPC mode, then fan the same
# prompt across omp and Claude Code to show the message contract is identical.
# Demonstrates the `:agent` option and `CrowdControl.Agent.Omp`.
#
#   mix run examples/omp_agent.exs

prompt = "In one sentence: what is OTP?"

# --- One omp session, watched turn by turn ---

{:ok, session} =
  CrowdControl.start_session(
    agent: :omp,
    # omp's own approval mode; permission_mode: "bypassPermissions" works too.
    approval_mode: "yolo",
    no_session_persistence: true,
    timeout: 120_000,
    prompt: prompt
  )

CrowdControl.Session.subscribe(session)

loop = fn loop ->
  receive do
    {:crowd_control, ^session, {:system_init, init}} ->
      IO.puts("omp up: session=#{init["session_id"]} model=#{init["model"]}")
      loop.(loop)

    {:crowd_control, ^session, {:result, "success", result}} ->
      IO.puts("#{result["result"]}")
      IO.puts("(#{result["num_turns"]} turn(s), $#{result["total_cost_usd"]})")

    {:crowd_control, ^session, {:result, subtype, result}} ->
      IO.puts("omp failed (#{subtype}): #{inspect(result["result"])}")

    {:crowd_control, ^session, _other} ->
      loop.(loop)
  after
    120_000 -> IO.puts("timed out")
  end
end

loop.(loop)

# omp keeps reading stdin after a turn, so the session is still usable.
:ok = CrowdControl.Session.send_prompt(session, "Now in five words.")
loop.(loop)

CrowdControl.Session.stop(session)

# --- Mixed fan-out: omp and Claude Code, collected uniformly ---

results =
  CrowdControl.run_many(prompt, [
    [agent: :omp, approval_mode: "yolo", timeout: 120_000],
    [agent: :claude, permission_mode: "bypassPermissions", timeout: 120_000]
  ])

case results do
  {:timeout, partial} ->
    IO.puts("only #{length(partial)} of 2 finished in time")

  results when is_list(results) ->
    Enum.each(results, fn {pid, {:result, _, %{"result" => text}}} ->
      IO.puts("--- #{inspect(pid)} ---")
      IO.puts(text)
    end)
end
