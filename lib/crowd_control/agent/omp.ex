defmodule CrowdControl.Agent.Omp do
  @moduledoc """
  `CrowdControl.Agent` adapter for [Oh My Pi](https://omp.sh/) (`omp`).

  Launches `omp --mode rpc`, omp's newline-delimited JSON-RPC protocol over
  stdio, and normalizes its frames into `t:CrowdControl.Protocol.message/0` so
  subscribers written against Claude Code work unchanged.

  ## Wire mapping

  | omp frame | CrowdControl message |
  | --- | --- |
  | `get_state` response (sent once at startup) | `{:system_init, map}` with `"session_id"` |
  | `message_end` (assistant) | `{:assistant, map}` |
  | `message_end` (user) | `{:user, map}` |
  | `message_update` | `{:stream_event, map}` |
  | `agent_end` with `isTerminal != false` | `{:result, "success", map}` |
  | `agent_end` with `isTerminal == false` | `{:stream_event, map}` |
  | `prompt` response or `prompt_result` with `agentInvoked: false` | `{:result, "success", map}` with `"local_only" => true` |
  | failed `prompt` response | `{:result, "error_prompt_failed", map}` |
  | anything else | `{:unknown, map}` |

  omp acknowledges a `prompt` command before the turn runs, so the completion
  signal is `agent_end` — and only when `isTerminal` is not `false`, since a
  `false` means maintenance or async delivery will resume the session. An
  `agent_end` is turned into a Claude-shaped result map: `"result"` is the final
  assistant text, `"total_cost_usd"` the summed cost of the turn's assistant
  messages, plus `"usage"`, `"num_turns"`, `"duration_ms"` and `"stop_reason"`.

  A prompt that omp resolves locally — a slash command such as `/tools` — never
  produces an `agent_end`. It completes with `agentInvoked: false`, which maps
  to a result carrying `"local_only" => true` and an empty `"result"`: the
  command's own text arrives separately as `command_output` frames, and
  `decode_line/1` is stateless. Without this a local-only prompt would hang a
  collector until its deadline.

  The adapter stays on protocol v1 (no `negotiate_protocol`), so an oversized
  logical frame is truncated by omp rather than chunked; `:max_line_bytes` on
  the session still bounds what a single line may cost.

  ## Options

  Shared with `CrowdControl.CLI` (Claude Code): `:executable` (default `"omp"`),
  `:model`, `:system_prompt`, `:allowed_tools`, `:permission_mode`, `:resume`,
  `:continue`, `:add_dir`, `:no_session_persistence`, `:extra_args`, `:env`,
  `:api_key`, `:api_url`.

  `:permission_mode` is translated to omp's approval modes:
  `"bypassPermissions"` => `yolo`, `"acceptEdits"` => `write`, `"default"` =>
  `always-ask`. `"plan"` has no approval-mode equivalent and raises; use
  `extra_args: ["--plan-yolo"]` if that is what you want.

  omp-native options:

    * `:approval_mode` - `"always-ask"`, `"write"` or `"yolo"`; wins over
      `:permission_mode`
    * `:auto_approve` - `true` to auto-approve every tool call
    * `:append_system_prompt` - text (or file path) appended to the system prompt
    * `:thinking` - `"off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "auto"`
    * `:provider`, `:service_tier`, `:profile`, `:max_time`
    * `:cwd`, `:session_dir` - paths (sanitized + expanded)
    * `:config`, `:hooks`, `:extensions` - path or list of paths, one flag each
    * `:models`, `:skills` - lists joined with `,`
    * `:no_tools`, `:no_lsp`, `:no_pty`, `:no_extensions`, `:no_skills`,
      `:no_rules`, `:no_title`, `:advisor`, `:allow_home`, `:hide_thinking` - booleans
    * `:streaming_behavior` - `"followUp"` (default) or `"steer"`; how a prompt
      sent mid-turn is queued
    * `:agent_dir` - path for `PI_CODING_AGENT_DIR`, the directory omp reads
      `models.yml` and `config.yml` from (sanitized + expanded)
    * `:custom_provider` - declarative OpenAI-compatible endpoint; see below

  Claude-Code-only options (`:mcp_config`, `:strict_mcp_config`, `:agents`,
  `:plugin_dir`, `:settings`, `:settings_file`, `:settings_json`,
  `:setting_sources`, `:max_budget_usd`, `:session_id`, `:bare`) have no omp
  equivalent and raise `ArgumentError` rather than being dropped silently.
  `:include_partial_messages` is accepted and ignored: RPC mode always streams
  deltas as `message_update` frames.

  ## Custom providers (vLLM, LiteLLM, any OpenAI-compatible endpoint)

  omp resolves a provider's `baseUrl` from `models.yml` under its agent
  directory — there is no CLI flag for it. `:custom_provider` renders that file
  into a private `0700` temp directory and points `PI_CODING_AGENT_DIR` at it:

      CrowdControl.run("Explain this repo",
        agent: :omp,
        custom_provider: [base_url: "http://10.0.0.5:8000/v1"],
        model: "vllm/Qwen/Qwen3-Coder-30B"
      )

  Spec keys:

    * `:base_url` - **required**, the OpenAI-compatible endpoint
    * `:id` - provider id, default `"vllm"`. omp has a built-in `vllm` provider
      that reads `max_model_len` from `/v1/models`; any other id is a plain
      custom provider. The id is the `provider/` prefix in `:model`.
    * `:api` - default `"openai-completions"`; use `"openai-responses"` for a
      server exposing `/v1/responses`, or `"anthropic-messages"`
    * `:api_key` - provider credential. **Never written to `models.yml`**: it is
      passed through the same validated environment channel as `:api_key`
      (a `0600` env file locally, the exec `Env` array remotely), and the config
      references it by variable name. Omit it for an unauthenticated server,
      which renders `auth: none`.
    * `:api_key_env` - name of that variable, default `"OMP_CUSTOM_PROVIDER_KEY"`
    * `:models` - explicit model list, each `[id: ..., name: ..., context_window:
      ..., max_tokens: ..., reasoning: true | false, input: ["text", "image"]]`.
      Omit to discover models from the server's `/v1/models` instead.
    * `:headers` - extra request headers as a string-keyed map

  The directory is content-addressed, so every session in a fan-out sharing one
  spec shares one directory rather than writing N copies. Build it yourself with
  `provider_dir!/1` and pass `:agent_dir` when you want to own the lifecycle
  (and `remove_provider_dir/1` to delete it). For the Docker and Kubernetes
  backends the directory has to exist *inside* the sandbox, so mount your own
  and pass `:agent_dir` — a host temp dir is not visible there.

  > #### `PI_CODING_AGENT_DIR` relocates more than `models.yml` {: .warning}
  >
  > It moves the whole `~/.omp/agent` base for that session: `config.yml`, the
  > auth store (`agent.db`), and saved sessions. A session pointed at a custom
  > provider therefore does not see your global omp settings or stored logins,
  > which is usually what you want for an isolated endpoint but does mean
  > `:custom_provider` and your normal Anthropic credentials do not mix in one
  > session. `~/.omp` itself (skills, plugins) is unaffected.
  """

  @behaviour CrowdControl.Agent

  alias CrowdControl.CLI

  @base_args ["--mode", "rpc"]

  @approval_modes ~w(always-ask write yolo)

  @permission_modes %{
    "bypassPermissions" => "yolo",
    "acceptEdits" => "write",
    "default" => "always-ask"
  }

  @thinking_levels ~w(off minimal low medium high xhigh max auto)

  @streaming_behaviors ~w(followUp steer)

  # C0 control bytes, as single-byte patterns for :binary.match/2.
  @control_bytes for b <- 0..31, do: <<b>>

  @default_provider_id "vllm"
  @default_provider_api "openai-completions"
  @default_provider_key_env "OMP_CUSTOM_PROVIDER_KEY"
  @provider_apis ~w(openai-completions openai-responses anthropic-messages)
  @agent_dir_env "PI_CODING_AGENT_DIR"

  @unsupported [
    mcp_config: "omp configures MCP servers through its config file",
    strict_mcp_config: "omp configures MCP servers through its config file",
    agents: "omp discovers task agents from disk; see `omp agents`",
    plugin_dir: "use :extensions or `omp plugin install`",
    settings: "use :config with an omp config.yml overlay",
    settings_file: "use :config with an omp config.yml overlay",
    settings_json: "use :config with an omp config.yml overlay",
    setting_sources: "omp has no setting-source selector",
    max_budget_usd: "omp has no spend ceiling flag; use :max_time",
    session_id: "omp mints its own session id; use :resume to rejoin one",
    bare: "omp has no bare mode"
  ]

  @impl true
  @spec build_command(keyword()) :: {String.t(), [String.t()], CrowdControl.Agent.env()}
  def build_command(opts \\ []) do
    reject_unsupported!(opts)
    # Validated here, not just at prompt time: encode_prompt/3 runs inside
    # Session.init/1 and handle_call/3, where a raise takes down the session
    # and the caller. Every other option fails at build time with a plain
    # {:error, _} from start_link/1, and this one should too.
    _ = streaming_behavior!(opts)

    executable = Keyword.get(opts, :executable, "omp")

    # Merged *under* an explicit :env so a caller can always override, and
    # merged before CLI.build_env/1 so the provider key and the agent dir go
    # through the same key/value validation as everything else -- and out to
    # the subprocess through the same 0600 env file, never through argv.
    extra = provider_env!(opts)
    opts = Keyword.update(opts, :env, extra, &Map.merge(extra, &1))

    {executable, @base_args ++ optional_args(opts), CLI.build_env(opts)}
  end

  @impl true
  @spec init_frames(keyword()) :: [binary()]
  def init_frames(_opts) do
    # omp has no init frame of its own: the ready frame carries no session id,
    # and RPC mode reports one only on request. Asking for it up front is what
    # makes {:system_init, %{"session_id" => _}} arrive for an omp session at
    # the same point it would for Claude Code.
    [encode_frame(%{"id" => "cc-init", "type" => "get_state"})]
  end

  @impl true
  @spec encode_prompt(binary(), non_neg_integer(), keyword()) :: binary()
  def encode_prompt(prompt, seq, opts) when is_binary(prompt) and is_integer(seq) do
    encode_frame(%{
      "id" => "cc-prompt-#{seq}",
      "type" => "prompt",
      "message" => prompt,
      # Required by omp when the agent is mid-turn, ignored when it is idle.
      # Defaulting to a follow-up keeps a fan-out orchestrator from aborting
      # tool calls that are already in flight.
      "streamingBehavior" => streaming_behavior!(opts)
    })
  end

  @impl true
  @spec decode_line(binary()) :: CrowdControl.Protocol.message()
  def decode_line(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, map} when is_map(map) -> classify(map)
      {:ok, _other} -> {:invalid_json, line}
      {:error, _reason} -> {:invalid_json, line}
    end
  end

  @doc """
  Renders a `models.yml` for a custom provider into a private temp directory
  and returns its path, for use as `:agent_dir`.

  The directory is `0700`, the file `0600`, and the name is derived from a
  per-VM random salt plus a digest of the rendered config — so one spec maps to
  one directory no matter how many sessions share it, and the path is not
  guessable by another local user. Writing is idempotent.

  The spec never carries a secret to disk: `:api_key` is referenced by
  environment-variable name (see `:api_key_env`), and the value itself travels
  through the session's normal environment channel.

  Delete it with `remove_provider_dir/1` when the last session using it is done;
  it is a few hundred bytes, so leaving it until the OS clears the temp
  directory is also fine.

      dir = CrowdControl.Agent.Omp.provider_dir!(base_url: "http://10.0.0.5:8000/v1")
      CrowdControl.run("hi", agent: :omp, agent_dir: dir, model: "vllm/my-model")
  """
  @spec provider_dir!(keyword() | map()) :: String.t()
  def provider_dir!(spec) do
    config = render_models_config!(spec)
    dir = Path.join(System.tmp_dir!(), "cc_omp_#{salt()}_#{digest(config)}")

    write_provider_dir!(dir, config)
  end

  @doc """
  Removes a directory created by `provider_dir!/1`.

  Refuses any path that is not one of ours, so a caller cannot turn a stray
  option value into a recursive delete.
  """
  @spec remove_provider_dir(String.t()) :: :ok | {:error, :not_a_provider_dir}
  def remove_provider_dir(dir) when is_binary(dir) do
    # Path.expand/1 on both sides: System.tmp_dir!/0 keeps a trailing slash on
    # macOS while Path.dirname/1 never emits one, so a raw comparison silently
    # refuses to delete our own directories.
    expanded = Path.expand(dir)

    if Path.dirname(expanded) == Path.expand(System.tmp_dir!()) and
         String.starts_with?(Path.basename(expanded), "cc_omp_") do
      _ = File.rm_rf(expanded)
      :ok
    else
      {:error, :not_a_provider_dir}
    end
  end

  @doc """
  Renders the `models.yml` body for a custom-provider spec.

  Emitted as JSON, which every YAML parser accepts: it keeps quoting and
  escaping in `JSON.encode!/1` rather than in a hand-rolled emitter.
  """
  @spec render_models_config!(keyword() | map()) :: binary()
  def render_models_config!(spec) do
    spec = normalize_spec!(spec)
    id = spec[:id] || @default_provider_id

    provider =
      %{"baseUrl" => base_url!(spec), "api" => provider_api!(spec)}
      |> put_provider_auth(spec)
      |> put_provider_models(spec, id)
      |> put_provider_headers(spec)

    JSON.encode!(%{"providers" => %{id => provider}})
  end

  # --- custom provider ---

  defp provider_env!(opts) do
    spec = opts[:custom_provider]
    dir = opts[:agent_dir]

    cond do
      spec && dir ->
        raise ArgumentError,
              ":custom_provider and :agent_dir are mutually exclusive -- " <>
                ":custom_provider generates an agent dir, :agent_dir supplies one. " <>
                "Pass the result of provider_dir!/1 as :agent_dir to do both."

      spec ->
        normalized = normalize_spec!(spec)

        %{@agent_dir_env => provider_dir!(normalized)}
        |> put_provider_key(normalized)

      dir ->
        %{@agent_dir_env => CLI.sanitize_path!(dir)}

      true ->
        %{}
    end
  end

  defp put_provider_key(env, spec) do
    case spec[:api_key] do
      nil ->
        env

      key when is_binary(key) ->
        Map.put(env, key_env_name!(spec), key)

      other ->
        raise ArgumentError, ":custom_provider :api_key must be a binary, got: #{inspect(other)}"
    end
  end

  defp normalize_spec!(spec) when is_list(spec) do
    if Keyword.keyword?(spec) do
      spec
    else
      raise ArgumentError, ":custom_provider must be a keyword list or map, got: #{inspect(spec)}"
    end
  end

  defp normalize_spec!(spec) when is_map(spec) and not is_struct(spec) do
    Enum.map(spec, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
    end)
  rescue
    ArgumentError ->
      reraise ArgumentError, [message: ":custom_provider has an unknown key"], __STACKTRACE__
  end

  defp normalize_spec!(other),
    do:
      raise(
        ArgumentError,
        ":custom_provider must be a keyword list or map, got: #{inspect(other)}"
      )

  defp base_url!(spec) do
    case spec[:base_url] do
      url when is_binary(url) and url != "" ->
        validate!(url, ":custom_provider :base_url")
        url

      other ->
        raise ArgumentError,
              ":custom_provider requires :base_url (e.g. \"http://127.0.0.1:8000/v1\"), " <>
                "got: #{inspect(other)}"
    end
  end

  defp provider_api!(spec) do
    case spec[:api] || @default_provider_api do
      api when api in @provider_apis ->
        api

      other ->
        raise ArgumentError,
              ":custom_provider :api must be one of #{inspect(@provider_apis)}, got: #{inspect(other)}"
    end
  end

  # The key itself never lands in the file: omp resolves `apiKey` as an
  # environment-variable name first and a literal only as a fallback, so naming
  # the variable keeps the secret in the 0600 env file where the rest of the
  # credentials already live.
  defp put_provider_auth(provider, spec) do
    case spec[:api_key] do
      nil -> Map.put(provider, "auth", "none")
      _key -> provider |> Map.put("apiKey", key_env_name!(spec)) |> Map.put("authHeader", true)
    end
  end

  defp key_env_name!(spec) do
    case spec[:api_key_env] || @default_provider_key_env do
      name when is_binary(name) ->
        name

      other ->
        raise ArgumentError,
              ":custom_provider :api_key_env must be a binary, got: #{inspect(other)}"
    end
  end

  # No explicit list means "ask the server". omp's built-in `vllm` provider
  # already knows how to read /v1/models (and vLLM's `max_model_len`); any other
  # OpenAI-shaped id needs the generic discovery type spelled out. An
  # Anthropic-shaped endpoint has no OpenAI /v1/models to probe, so guessing one
  # would produce a provider that silently resolves no models at all -- say so
  # instead.
  defp put_provider_models(provider, spec, id) do
    case {spec[:models], provider["api"]} do
      {nil, _api} when id == @default_provider_id ->
        provider

      {nil, "anthropic-messages"} ->
        raise ArgumentError,
              ":custom_provider with api: \"anthropic-messages\" cannot discover models " <>
                "(there is no OpenAI /v1/models to probe); list them with :models"

      {nil, _api} ->
        Map.put(provider, "discovery", %{"type" => "openai-models-list"})

      {models, _api} when is_list(models) ->
        Map.put(provider, "models", Enum.map(models, &model_entry!/1))

      {other, _api} ->
        raise ArgumentError, ":custom_provider :models must be a list, got: #{inspect(other)}"
    end
  end

  defp model_entry!(model) do
    model = normalize_spec!(model)

    id =
      case model[:id] do
        id when is_binary(id) and id != "" ->
          id

        other ->
          raise ArgumentError, "each :custom_provider model needs an :id, got: #{inspect(other)}"
      end

    %{"id" => id}
    |> maybe_put("name", model[:name] || id)
    |> maybe_put("contextWindow", model[:context_window])
    |> maybe_put("maxTokens", model[:max_tokens])
    |> maybe_put("reasoning", model[:reasoning])
    |> maybe_put("input", model[:input])
  end

  defp put_provider_headers(provider, spec) do
    case spec[:headers] do
      nil ->
        provider

      headers when is_map(headers) ->
        Map.put(provider, "headers", headers)

      other ->
        raise ArgumentError, ":custom_provider :headers must be a map, got: #{inspect(other)}"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # sobelow_skip ["Traversal.FileModule"]
  defp write_provider_dir!(dir, config) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    path = Path.join(dir, "models.yml")
    File.write!(path, config)
    File.chmod!(path, 0o600)

    dir
  end

  defp digest(config),
    do: :sha256 |> :crypto.hash(config) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  # A content-only directory name would be guessable, letting another local user
  # pre-create it (or plant a symlink at models.yml) before we do. The salt is
  # random per VM, so the path is unpredictable while still being stable enough
  # for every session in one fan-out to share a directory.
  defp salt do
    case :persistent_term.get({__MODULE__, :salt}, nil) do
      nil ->
        salt = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
        :persistent_term.put({__MODULE__, :salt}, salt)
        salt

      salt ->
        salt
    end
  end

  # --- argv ---

  # `false` counts as absent. `bare: false` and `strict_mcp_config: false`
  # request omp's *default* behaviour, so dropping them changes nothing --
  # and raising would break the shared option list that drives a mixed
  # claude+omp fan-out. Only a value that would actually change behaviour
  # is worth refusing.
  defp reject_unsupported!(opts) do
    Enum.each(@unsupported, fn {key, hint} ->
      case opts[key] do
        nil ->
          :ok

        false ->
          :ok

        _ ->
          raise ArgumentError,
                "#{inspect(key)} is a Claude Code option with no omp equivalent (#{hint})"
      end
    end)
  end

  defp optional_args(opts) do
    []
    |> flag("--model", opts[:model])
    |> flag("--provider", opts[:provider])
    |> flag("--system-prompt", opts[:system_prompt])
    |> flag("--append-system-prompt", opts[:append_system_prompt])
    |> flag("--service-tier", opts[:service_tier])
    |> flag("--profile", opts[:profile])
    |> flag("--max-time", opts[:max_time])
    |> flag("--resume", opts[:resume])
    |> flag("--thinking", thinking!(opts[:thinking]))
    |> flag("--tools", join(opts[:allowed_tools]))
    |> flag("--models", join(opts[:models]))
    |> flag("--skills", join(opts[:skills]))
    |> flag("--approval-mode", approval_mode!(opts))
    |> path_flag("--cwd", opts[:cwd])
    |> path_flag("--session-dir", opts[:session_dir])
    |> repeated_path_flag("--add-dir", opts[:add_dir])
    |> repeated_path_flag("--config", opts[:config])
    |> repeated_path_flag("--hook", opts[:hooks])
    |> repeated_path_flag("--extension", opts[:extensions])
    |> bool("--continue", opts[:continue])
    |> bool("--no-session", opts[:no_session_persistence])
    |> bool("--auto-approve", opts[:auto_approve])
    |> bool("--no-tools", opts[:no_tools])
    |> bool("--no-lsp", opts[:no_lsp])
    |> bool("--no-pty", opts[:no_pty])
    |> bool("--no-extensions", opts[:no_extensions])
    |> bool("--no-skills", opts[:no_skills])
    |> bool("--no-rules", opts[:no_rules])
    |> bool("--no-title", opts[:no_title])
    |> bool("--advisor", opts[:advisor])
    |> bool("--allow-home", opts[:allow_home])
    |> bool("--hide-thinking", opts[:hide_thinking])
    |> extra(opts[:extra_args])
    |> Enum.reverse()
  end

  defp flag(args, _name, nil), do: args

  defp flag(args, name, value) do
    value = to_string(value)
    validate!(value, name)
    [value, name | args]
  end

  defp path_flag(args, _name, nil), do: args
  defp path_flag(args, name, value), do: [CLI.sanitize_path!(value), name | args]

  defp repeated_path_flag(args, _name, nil), do: args

  defp repeated_path_flag(args, name, values) when is_list(values) do
    Enum.reduce(values, args, &path_flag(&2, name, &1))
  end

  defp repeated_path_flag(args, name, value), do: path_flag(args, name, value)

  defp bool(args, _name, nil), do: args
  defp bool(args, _name, false), do: args
  defp bool(args, name, true), do: [name | args]

  defp bool(_args, name, other),
    do: raise(ArgumentError, "#{name} expects a boolean, got: #{inspect(other)}")

  defp extra(args, nil), do: args

  defp extra(args, values) when is_list(values) do
    Enum.each(values, fn value ->
      unless is_binary(value),
        do: raise(ArgumentError, "extra_args entries must be binaries, got: #{inspect(value)}")

      validate!(value, ":extra_args")
    end)

    Enum.reverse(values) ++ args
  end

  defp extra(_args, other),
    do: raise(ArgumentError, ":extra_args must be a list, got: #{inspect(other)}")

  defp join(nil), do: nil
  defp join(values) when is_list(values), do: Enum.join(values, ",")
  defp join(value) when is_binary(value), do: value

  defp thinking!(nil), do: nil
  defp thinking!(level) when level in @thinking_levels, do: level

  defp thinking!(other),
    do:
      raise(
        ArgumentError,
        ":thinking must be one of #{inspect(@thinking_levels)}, got: #{inspect(other)}"
      )

  # :approval_mode is omp-native and wins; :permission_mode is the Claude Code
  # spelling and is translated so the same option list can drive both agents.
  defp approval_mode!(opts) do
    case {opts[:approval_mode], opts[:permission_mode]} do
      {nil, nil} -> nil
      {nil, permission} -> translate_permission_mode!(permission)
      {mode, _} when mode in @approval_modes -> mode
      {mode, _} -> raise ArgumentError, bad_approval_mode(mode)
    end
  end

  defp bad_approval_mode(mode),
    do: ":approval_mode must be one of #{inspect(@approval_modes)}, got: #{inspect(mode)}"

  defp translate_permission_mode!(permission) do
    case Map.fetch(@permission_modes, permission) do
      {:ok, mode} ->
        mode

      :error ->
        raise ArgumentError,
              "permission_mode #{inspect(permission)} has no omp approval-mode equivalent " <>
                "(known: #{inspect(Map.keys(@permission_modes))}); pass :approval_mode " <>
                "(#{inspect(@approval_modes)}) or :extra_args instead"
    end
  end

  defp streaming_behavior!(opts) do
    case Keyword.get(opts, :streaming_behavior, "followUp") do
      behavior when behavior in @streaming_behaviors ->
        behavior

      other ->
        raise ArgumentError,
              ":streaming_behavior must be one of #{inspect(@streaming_behaviors)}, " <>
                "got: #{inspect(other)}"
    end
  end

  defp validate!(value, label) do
    # Backends shell-escape argv before it crosses an `sh -c` boundary, so this
    # is belt-and-braces: it keeps a stray newline out of the command line the
    # remote backends assemble, and out of logs.
    case :binary.match(value, @control_bytes) do
      :nomatch ->
        :ok

      {pos, _} ->
        raise ArgumentError,
              "#{label} contains a control character at byte #{pos} " <>
                "(#{byte_size(value)} bytes); value redacted"
    end
  end

  # --- framing ---

  defp encode_frame(map), do: JSON.encode!(map) <> "\n"

  defp classify(%{"type" => "response", "command" => "get_state", "success" => true, "data" => d})
       when is_map(d),
       do: {:system_init, system_init(d)}

  defp classify(%{"type" => "response", "success" => false, "command" => command} = map)
       when command in ["prompt", "abort_and_prompt"] do
    # A rejected prompt is terminal for this turn: no agent_end will ever
    # arrive, so surfacing it as a result is what stops a collector from
    # blocking until its own deadline.
    {:result, "error_prompt_failed",
     %{
       "type" => "result",
       "subtype" => "error_prompt_failed",
       "agent" => "omp",
       "is_error" => true,
       "result" => map["error"],
       "error_code" => map["code"]
     }}
  end

  # A local-only prompt -- a slash command that omp resolves without a model
  # turn -- emits NO agent_end. Its completion signal is `agentInvoked: false`,
  # either inline on the prompt response or on a later prompt_result frame.
  # Without these two clauses `CrowdControl.run("/tools", agent: :omp)` blocks
  # until its own deadline for a command that finished in milliseconds.
  #
  # An *absent* `data` is deliberately not treated as completion: omp v17.2.12
  # omits it entirely for ordinary agent-invoking prompts, whose real terminal
  # frame is agent_end.
  defp classify(%{
         "type" => "response",
         "command" => "prompt",
         "success" => true,
         "data" => %{"agentInvoked" => false}
       }),
       do: {:result, "success", local_result()}

  defp classify(%{"type" => "prompt_result", "agentInvoked" => false}),
    do: {:result, "success", local_result()}

  defp classify(%{"type" => "agent_end", "isTerminal" => false} = map), do: {:stream_event, map}
  defp classify(%{"type" => "agent_end"} = map), do: {:result, "success", result(map)}

  defp classify(%{"type" => "message_end", "message" => %{"role" => "assistant"}} = map),
    do: {:assistant, map}

  defp classify(%{"type" => "message_end", "message" => %{"role" => "user"}} = map),
    do: {:user, map}

  defp classify(%{"type" => "message_update"} = map), do: {:stream_event, map}
  defp classify(map), do: {:unknown, map}

  defp local_result do
    %{
      "type" => "result",
      "subtype" => "success",
      "agent" => "omp",
      "is_error" => false,
      # The command's own text was already delivered as command_output frames;
      # decode_line/1 is stateless and cannot accumulate them into this map.
      "result" => "",
      "local_only" => true,
      "total_cost_usd" => 0.0,
      "num_turns" => 0
    }
  end

  # Every read here is shape-guarded. decode_line/1 runs inside
  # Session.handle_cast/2, so a raise on an unexpected value type does not
  # return an error -- it kills the session, skips the {:error, _} broadcast,
  # and dumps state (including :api_key) into the crash report. `|| %{}`
  # defends against nil and nothing else; omp changing "model" from an object
  # to a bare id string would be enough.
  defp system_init(data) do
    model = submap(data, "model")

    %{
      "type" => "system",
      "subtype" => "init",
      "agent" => "omp",
      "session_id" => string_or_nil(data["sessionId"]),
      "session_file" => string_or_nil(data["sessionFile"]),
      "model" => model["id"],
      "provider" => model["provider"],
      "context_window" => model["contextWindow"],
      "thinking_level" => data["thinkingLevel"],
      "tools" => tool_names(data)
    }
  end

  defp submap(data, key) do
    case Map.get(data, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  # `session_id` is spec'd String.t() | nil all the way through Session and
  # Store, and is fed back to omp as `--resume`. Clamp it at the boundary
  # rather than letting a map travel three modules and raise in to_string/1.
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp tool_names(data) do
    case Map.get(data, "dumpTools") do
      tools when is_list(tools) -> for tool <- tools, is_map(tool), do: tool["name"]
      _ -> []
    end
  end

  defp result(%{"messages" => messages}) when is_list(messages) do
    assistants = Enum.filter(messages, &(is_map(&1) and &1["role"] == "assistant"))
    last = List.last(assistants) || %{}

    %{
      "type" => "result",
      "subtype" => "success",
      "agent" => "omp",
      "is_error" => false,
      "result" => assistant_text(last),
      # agent_end carries only the turn's messages, so this is the cost of this
      # turn -- not of the session.
      "total_cost_usd" => Enum.reduce(assistants, 0.0, &(&2 + cost(&1))),
      "usage" => last["usage"],
      "num_turns" => length(assistants),
      "duration_ms" => last["duration"],
      "stop_reason" => last["stopReason"]
    }
  end

  defp result(map), do: result(Map.put(map, "messages", []))

  defp assistant_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("", & &1["text"])
  end

  defp assistant_text(_message), do: ""

  defp cost(%{"usage" => %{"cost" => %{"total" => total}}}) when is_number(total), do: total
  defp cost(_message), do: 0.0
end
