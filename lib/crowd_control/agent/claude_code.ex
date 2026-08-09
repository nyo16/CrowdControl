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

  All of these travel through the session's validated environment (a `0600` env
  file locally, the exec `Env` array remotely) — never argv, never `ps`:

    * `:api_key` — pay-per-use API key. Sets `ANTHROPIC_API_KEY`, sent as
      `x-api-key`.
    * `:oauth_token` — **subscription** (Pro/Max/Team). Sets
      `CLAUDE_CODE_OAUTH_TOKEN`, the long-lived token minted by
      `claude setup-token`. This is the headless way to bill a session to a
      Claude subscription instead of an API key, and it wins over `:api_key`.
    * `:auth_token` — bearer credential for a gateway or a self-hosted endpoint.
      Sets `ANTHROPIC_AUTH_TOKEN`, sent as `Authorization: Bearer`, which is
      what most non-Anthropic servers expect.
    * `env: %{"CLAUDE_CONFIG_DIR" => "/path/to/.claude"}` — point the CLI at an
      existing logged-in config directory. Use this when `claude auth login`
      already ran on the host and you want sessions to inherit that login
      wholesale; for containers, mount `~/.claude` in and set the variable to
      the mount path.

  ## Self-hosted and gateway endpoints

  Claude Code speaks **only** the Anthropic Messages API, so any endpoint you
  point it at has to serve `/v1/messages` — not just an OpenAI-compatible
  `/v1/chat/completions`. Recent vLLM builds expose both; LiteLLM has an
  Anthropic passthrough; a plain OpenAI-only server will not work (use
  `CrowdControl.Agent.Omp`'s `:custom_provider` for those).

      CrowdControl.run("Summarize this repo",
        api_url: "http://10.0.0.5:8000",          # no /v1 -- the CLI appends it
        auth_token: System.fetch_env!("VLLM_KEY"),
        model: "deepseek-v4-flash"
      )

  Check before you wire it up:

      curl -sS $BASE/v1/messages -H "Authorization: Bearer $KEY" \\
        -H 'content-type: application/json' \\
        -d '{"model":"…","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'

  A JSON body with `"type": "message"` means Claude Code can drive it. Note that
  `"total_cost_usd"` on the result is then meaningless — the CLI prices the
  response against Anthropic's table for a model it does not know.
  """

  @behaviour CrowdControl.Agent

  @token_envs [oauth_token: "CLAUDE_CODE_OAUTH_TOKEN", auth_token: "ANTHROPIC_AUTH_TOKEN"]

  @impl true
  def build_command(opts \\ []) do
    CrowdControl.CLI.build_command(put_tokens(opts))
  end

  # Merged under an explicit :env so a caller can still override, and merged
  # before CLI.build_env/1 so each token is validated like every other value.
  defp put_tokens(opts) do
    Enum.reduce(@token_envs, opts, fn {key, var}, acc ->
      case Keyword.get(acc, key) do
        nil ->
          acc

        token when is_binary(token) ->
          Keyword.update(acc, :env, %{var => token}, &Map.merge(%{var => token}, &1))

        other ->
          raise ArgumentError, "#{inspect(key)} must be a binary, got: #{inspect(other)}"
      end
    end)
  end

  @impl true
  def init_frames(_opts), do: []

  @impl true
  def encode_prompt(prompt, _seq, _opts), do: CrowdControl.Protocol.encode_user_message(prompt)

  @impl true
  defdelegate decode_line(line), to: CrowdControl.Protocol
end
