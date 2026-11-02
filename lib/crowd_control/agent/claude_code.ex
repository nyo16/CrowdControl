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

  ## Control protocol

  These options switch on the stream-json control protocol (CLI 2.1.268+, see
  `CrowdControl.CLI.min_version/0`). Any of them makes `init_frames/1` emit an
  `initialize` request, and `reattach_frames/1` re-sends the same bytes:

    * `:can_use_tool` - the tool-approval callback, an MFA tuple. Sets
      `permission_prompt_tool: "stdio"`, so the CLI asks the host over stdin;
      combining it with a *named* `:permission_prompt_tool` raises.
    * `:hooks` - hook callbacks, a map from hook event to a list of matchers:

          hooks: %{
            "PreToolUse" => [
              %{matcher: "Bash", hooks: [{MyApp.Hooks, :pre_bash, []}], timeout: 30}
            ]
          }

      Events may be atoms or strings; `:matcher` and `:timeout` (seconds) are
      optional. Every callback gets the deterministic id
      `"hook_<event>_<matcher index>_<callback index>"` (see
      `hook_callbacks/1`), so a re-sent `initialize` registers the same set.
    * `:sdk_mcp_servers` - in-BEAM MCP servers, a map from server name to server
      spec. Each name is declared to the CLI twice, as
      `%{"type" => "sdk", "name" => name}` in an inline `:mcp_config` entry and
      in the `initialize` request's `sdkMcpServers`.
  """

  @behaviour CrowdControl.Agent

  @token_envs [oauth_token: "CLAUDE_CODE_OAUTH_TOKEN", auth_token: "ANTHROPIC_AUTH_TOKEN"]

  @init_request_id "cc_init"

  @impl true
  def build_command(opts \\ []) do
    opts
    |> put_tokens()
    |> put_permission_prompt_tool()
    |> put_sdk_mcp_config()
    |> CrowdControl.CLI.build_command()
  end

  defp put_permission_prompt_tool(opts) do
    case {opts[:can_use_tool], opts[:permission_prompt_tool]} do
      {nil, _tool} ->
        opts

      {_callback, nil} ->
        Keyword.put(opts, :permission_prompt_tool, "stdio")

      {_callback, "stdio"} ->
        opts

      {_callback, tool} ->
        raise ArgumentError,
              ":can_use_tool answers permission prompts over stdio, so it cannot be " <>
                "combined with permission_prompt_tool: #{inspect(tool)}"
    end
  end

  defp put_sdk_mcp_config(opts) do
    case sdk_server_names(opts) do
      [] ->
        opts

      names ->
        servers = Map.new(names, &{&1, %{"type" => "sdk", "name" => &1}})
        entry = %{"mcpServers" => servers}
        Keyword.put(opts, :mcp_config, List.wrap(opts[:mcp_config]) ++ [entry])
    end
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
  def init_frames(opts) do
    if control?(opts), do: [initialize_frame(opts)], else: []
  end

  @doc """
  Frames to write when reattaching to a running CLI: the same `initialize` as
  `init_frames/1`, byte for byte. Its reply lists any permission request the
  CLI is still waiting on (`pending_permission_requests`).
  """
  @impl true
  def reattach_frames(opts), do: init_frames(opts)

  @impl true
  def capabilities, do: [:control, :interrupt, :sdk_mcp]

  @impl true
  def encode_control({:request, request_id, request}, _opts),
    do: CrowdControl.Protocol.encode_control_request(request_id, request)

  def encode_control({:response, request_id, result}, _opts),
    do: CrowdControl.Protocol.encode_control_response(request_id, result)

  def encode_control({:permission, request_id, decision}, _opts),
    do: CrowdControl.Protocol.encode_permission(request_id, decision)

  @doc """
  The `request_id` of the `initialize` request in `init_frames/1`, so a session
  can pick its reply out of the stream.
  """
  @spec init_request_id() :: String.t()
  def init_request_id, do: @init_request_id

  @doc """
  Maps every hook callback id in the `initialize` request to the callback it
  stands for, so an inbound `hook_callback` can be dispatched by its
  `callback_id`.

      iex> CrowdControl.Agent.ClaudeCode.hook_callbacks(
      ...>   hooks: %{"PreToolUse" => [%{matcher: "Bash", hooks: [{M, :f, []}]}]}
      ...> )
      %{"hook_PreToolUse_0_0" => {M, :f, []}}
  """
  @spec hook_callbacks(keyword()) :: %{String.t() => term()}
  def hook_callbacks(opts) do
    for {event, matchers} <- hook_events(opts),
        {%{hooks: callbacks}, i} <- Enum.with_index(matchers),
        {callback, j} <- Enum.with_index(callbacks),
        into: %{},
        do: {hook_id(event, i, j), callback}
  end

  defp control?(opts) do
    opts[:can_use_tool] != nil or hook_events(opts) != [] or sdk_server_names(opts) != []
  end

  defp initialize_frame(opts) do
    request =
      %{"subtype" => "initialize"}
      |> put_nonempty("hooks", wire_hooks(opts))
      |> put_nonempty("sdkMcpServers", sdk_server_names(opts))

    CrowdControl.Protocol.encode_control_request(@init_request_id, request)
  end

  defp put_nonempty(map, _key, empty) when empty == [] or empty == %{}, do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp wire_hooks(opts) do
    Map.new(hook_events(opts), fn {event, matchers} ->
      {event, matchers |> Enum.with_index() |> Enum.map(&wire_matcher(event, &1))}
    end)
  end

  defp wire_matcher(event, {matcher, i}) do
    ids = for {_callback, j} <- Enum.with_index(matcher.hooks), do: hook_id(event, i, j)

    %{"hookCallbackIds" => ids}
    |> put_present("matcher", matcher.matcher)
    |> put_present("timeout", matcher.timeout)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp hook_id(event, i, j), do: "hook_#{event}_#{i}_#{j}"

  # Normalized `:hooks`, sorted by event so every derived view is stable.
  # Shape only: whether each callback is a valid MFA is Session's check.
  defp hook_events(opts) do
    case opts[:hooks] do
      nil ->
        []

      hooks when is_map(hooks) ->
        hooks |> Enum.map(&hook_event!/1) |> Enum.sort()

      other ->
        raise ArgumentError, ":hooks must be a map of event => matchers, got: #{inspect(other)}"
    end
  end

  defp hook_event!({event, matchers}) do
    name = hook_event_name!(event)

    unless is_list(matchers) and matchers != [] do
      raise ArgumentError, ":hooks #{inspect(name)} must be a non-empty list of matchers"
    end

    {name, Enum.map(matchers, &hook_matcher!(name, &1))}
  end

  defp hook_event_name!(event) when is_atom(event) and not is_nil(event),
    do: hook_event_name!(Atom.to_string(event))

  defp hook_event_name!(event) when is_binary(event) do
    if event =~ ~r/\A[A-Za-z]+\z/,
      do: event,
      else: raise(ArgumentError, ":hooks event must be a hook name, got: #{inspect(event)}")
  end

  defp hook_event_name!(other),
    do: raise(ArgumentError, ":hooks event must be a hook name, got: #{inspect(other)}")

  defp hook_matcher!(event, %{hooks: [_ | _] = callbacks} = matcher) do
    matcher_pattern = Map.get(matcher, :matcher)
    timeout = Map.get(matcher, :timeout)

    unless is_nil(matcher_pattern) or is_binary(matcher_pattern) do
      raise ArgumentError, ":hooks #{event} :matcher must be a binary"
    end

    unless is_nil(timeout) or (is_integer(timeout) and timeout > 0) do
      raise ArgumentError, ":hooks #{event} :timeout must be a positive integer (seconds)"
    end

    %{matcher: matcher_pattern, timeout: timeout, hooks: callbacks}
  end

  defp hook_matcher!(event, other) do
    raise ArgumentError,
          ":hooks #{event} matchers must be maps with a non-empty :hooks list, " <>
            "got: #{inspect(other)}"
  end

  # Sorted, so the initialize request and the inline config are stable.
  defp sdk_server_names(opts) do
    case opts[:sdk_mcp_servers] do
      nil ->
        []

      servers when is_map(servers) ->
        servers |> Map.keys() |> Enum.map(&sdk_server_name!/1) |> Enum.sort()

      other ->
        raise ArgumentError,
              ":sdk_mcp_servers must be a map of name => server, got: #{inspect(other)}"
    end
  end

  defp sdk_server_name!(name) when is_binary(name) do
    if name =~ ~r/\A[A-Za-z0-9_-]+\z/,
      do: name,
      else:
        raise(
          ArgumentError,
          ":sdk_mcp_servers name must match [A-Za-z0-9_-]+, got: #{inspect(name)}"
        )
  end

  defp sdk_server_name!(other) do
    raise ArgumentError, ":sdk_mcp_servers names must be binaries, got: #{inspect(other)}"
  end

  @impl true
  def encode_prompt(prompt, _seq, _opts), do: CrowdControl.Protocol.encode_user_message(prompt)

  @impl true
  defdelegate decode_line(line), to: CrowdControl.Protocol
end
