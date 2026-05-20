# Render assistant deltas as they arrive using :include_partial_messages.
#
#   mix run examples/streaming.exs

alias CrowdControl.Session

{:ok, session} =
  CrowdControl.start_session(
    model: "sonnet",
    include_partial_messages: true,
    timeout: 60_000,
    api_key: System.fetch_env!("ANTHROPIC_API_KEY")
  )

Session.subscribe(session)
:ok = Session.send_prompt(session, "Count from 1 to 10, one number per line.")

defmodule Stream do
  def run(session) do
    receive do
      {:crowd_control, ^session,
       {:stream_event, %{"event" => "content_block_delta", "delta" => %{"text" => text}}}} ->
        IO.write(text)
        run(session)

      {:crowd_control, ^session, {:result, _, _}} ->
        IO.puts("\n[done]")

      {:crowd_control, ^session, _} ->
        run(session)
    after
      60_000 -> IO.puts("\n[timeout]")
    end
  end
end

Stream.run(session)
Session.stop(session)
