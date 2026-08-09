defmodule CrowdControl.Agent.ClaudeCode do
  @moduledoc """
  `CrowdControl.Agent` adapter for the Claude Code stream-json wire format.

  Also drives the `open-code` CLI, which speaks the same protocol; pass
  `executable: "open-code"`.

  Argv construction lives in `CrowdControl.CLI` and framing in
  `CrowdControl.Protocol`; this module only binds the two to the behaviour.
  The CLI is launched with `--input-format stream-json`, so it reads prompts
  from stdin for the life of the session and needs no handshake.

  ## Credentials

  Three ways in, all through the session's validated environment (a `0600` env
  file locally, the exec `Env` array remotely) — never argv, never `ps`:

    * `:api_key` — pay-per-use API key. Sets `ANTHROPIC_API_KEY`.
    * `:oauth_token` — **subscription** (Pro/Max/Team). Sets
      `CLAUDE_CODE_OAUTH_TOKEN`, the long-lived token minted by
      `claude setup-token`. This is the headless way to bill a session to a
      Claude subscription instead of an API key.
    * `env: %{"CLAUDE_CONFIG_DIR" => "/path/to/.claude"}` — point the CLI at an
      existing logged-in config directory. Use this when `claude auth login`
      already ran on the host and you want sessions to inherit that login
      wholesale; for containers, mount `~/.claude` in and set the variable to
      the mount path.

  `:oauth_token` wins over `:api_key` inside Claude Code when both are set.
  """

  @behaviour CrowdControl.Agent

  @oauth_env "CLAUDE_CODE_OAUTH_TOKEN"

  @impl true
  def build_command(opts \\ []) do
    CrowdControl.CLI.build_command(put_oauth_token(opts))
  end

  # Merged under an explicit :env so a caller can still override, and merged
  # before CLI.build_env/1 so the token is validated like every other value.
  defp put_oauth_token(opts) do
    case Keyword.get(opts, :oauth_token) do
      nil ->
        opts

      token when is_binary(token) ->
        Keyword.update(opts, :env, %{@oauth_env => token}, &Map.merge(%{@oauth_env => token}, &1))

      other ->
        raise ArgumentError, ":oauth_token must be a binary, got: #{inspect(other)}"
    end
  end

  @impl true
  def init_frames(_opts), do: []

  @impl true
  def encode_prompt(prompt, _seq, _opts), do: CrowdControl.Protocol.encode_user_message(prompt)

  @impl true
  defdelegate decode_line(line), to: CrowdControl.Protocol
end
