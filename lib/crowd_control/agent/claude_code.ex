defmodule CrowdControl.Agent.ClaudeCode do
  @moduledoc """
  `CrowdControl.Agent` adapter for the Claude Code stream-json wire format.

  Also drives the `open-code` CLI, which speaks the same protocol; pass
  `executable: "open-code"`.

  Argv construction lives in `CrowdControl.CLI` and framing in
  `CrowdControl.Protocol`; this module only binds the two to the behaviour.
  The CLI is launched with `--input-format stream-json`, so it reads prompts
  from stdin for the life of the session and needs no handshake.
  """

  @behaviour CrowdControl.Agent

  @impl true
  defdelegate build_command(opts), to: CrowdControl.CLI

  @impl true
  def init_frames(_opts), do: []

  @impl true
  def encode_prompt(prompt, _seq, _opts), do: CrowdControl.Protocol.encode_user_message(prompt)

  @impl true
  defdelegate decode_line(line), to: CrowdControl.Protocol
end
