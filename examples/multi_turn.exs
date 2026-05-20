# Multi-turn conversation against a single session: send a prompt,
# wait for its result, then send a follow-up.
#
#   mix run examples/multi_turn.exs

alias CrowdControl.Session

{:ok, session} =
  CrowdControl.start_session(
    model: "sonnet",
    timeout: 120_000,
    api_key: System.fetch_env!("ANTHROPIC_API_KEY")
  )

Session.subscribe(session)

defmodule Turn do
  def ask(session, prompt) do
    IO.puts("> #{prompt}")
    :ok = Session.send_prompt(session, prompt)
    wait_for_result(session)
  end

  defp wait_for_result(session) do
    receive do
      {:crowd_control, ^session, {:result, _subtype, %{"result" => result}}} ->
        IO.puts("< #{result}\n")
        :ok

      {:crowd_control, ^session, _other} ->
        wait_for_result(session)
    after
      60_000 -> {:error, :timeout}
    end
  end
end

Turn.ask(session, "Name a small Elixir library.")
Turn.ask(session, "What does it do, in one sentence?")
Turn.ask(session, "Who maintains it?")

Session.stop(session)
