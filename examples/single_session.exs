# Single session: start, send a prompt, print streaming messages,
# then stop when the result arrives.
#
#   mix run examples/single_session.exs

alias CrowdControl.Session

{:ok, session} =
  CrowdControl.start_session(
    model: "sonnet",
    timeout: 60_000,
    api_key: System.fetch_env!("ANTHROPIC_API_KEY")
  )

Session.subscribe(session)
:ok = Session.send_prompt(session, "Write a haiku about Elixir.")

defmodule Loop do
  def run(session) do
    receive do
      {:crowd_control, ^session, {:assistant, %{"message" => %{"content" => content}}}} ->
        Enum.each(content, fn
          %{"type" => "text", "text" => text} -> IO.puts(text)
          _ -> :ok
        end)

        run(session)

      {:crowd_control, ^session, {:result, _subtype, %{"result" => result}}} ->
        IO.puts("\n--- DONE ---\n#{result}")

      {:crowd_control, ^session, _other} ->
        run(session)
    after
      60_000 -> IO.puts("Timed out waiting for result")
    end
  end
end

Loop.run(session)
Session.stop(session)
