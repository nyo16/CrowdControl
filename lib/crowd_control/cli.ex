defmodule CrowdControl.CLI do
  @moduledoc """
  Builds CLI commands for Claude Code and Open Code executables.

  Sanitizes path-like options and environment variable keys/values to
  prevent shell injection and confused-deputy file reads.
  """

  require Logger

  @env_key_re ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  # C0 control bytes, as single-byte patterns for :binary.match/2.
  @control_bytes for b <- 0..31, do: <<b>>

  @base_args [
    "--print",
    "--output-format",
    "stream-json",
    "--input-format",
    "stream-json",
    "--verbose"
  ]

  # Lowest CLI release the control protocol is built against: from 2.1.268 a
  # success `initialize` reply always carries `pending_permission_requests`,
  # which reattach recovery depends on. `--permission-prompts` needs 2.1.259,
  # so this one bound covers every flag below.
  @min_version "2.1.268"

  # Every flag build_command/1 can emit, checked against a real binary by
  # `mix crowd_control.contract`. `operand` says whether it takes a value;
  # `hidden` flags are missing from `claude --help`, so the task proves them by
  # the parser's "argument missing" error instead. A test asserts this table
  # covers build_command/1's output, so a new flag cannot skip the contract.
  @contract_flags [
    %{flag: "--print", operand: false, hidden: false},
    %{flag: "--output-format", operand: true, hidden: false},
    %{flag: "--input-format", operand: true, hidden: false},
    %{flag: "--verbose", operand: false, hidden: false},
    %{flag: "--model", operand: true, hidden: false},
    %{flag: "--system-prompt", operand: true, hidden: false},
    %{flag: "--allowed-tools", operand: true, hidden: false},
    %{flag: "--permission-mode", operand: true, hidden: false},
    %{flag: "--permission-prompt-tool", operand: true, hidden: true},
    %{flag: "--permission-prompts", operand: true, hidden: false},
    %{flag: "--max-budget-usd", operand: true, hidden: false},
    %{flag: "--session-id", operand: true, hidden: false},
    %{flag: "--resume", operand: true, hidden: false},
    %{flag: "--add-dir", operand: true, hidden: false},
    %{flag: "--settings", operand: true, hidden: false},
    %{flag: "--setting-sources", operand: true, hidden: false},
    %{flag: "--mcp-config", operand: true, hidden: false},
    %{flag: "--agents", operand: true, hidden: false},
    %{flag: "--plugin-dir", operand: true, hidden: false},
    %{flag: "--continue", operand: false, hidden: false},
    %{flag: "--include-partial-messages", operand: false, hidden: false},
    %{flag: "--no-session-persistence", operand: false, hidden: false},
    %{flag: "--strict-mcp-config", operand: false, hidden: false},
    %{flag: "--bare", operand: false, hidden: false}
  ]

  @permission_prompts ["host", "none"]

  @typedoc """
  One `--mcp-config` entry: a path to a JSON file, or an inline
  `%{"mcpServers" => %{name => server}}` map whose every server names its
  `"type"`.
  """
  @type mcp_config_entry :: String.t() | map()

  @type opt ::
          {:executable, String.t()}
          | {:model, String.t()}
          | {:system_prompt, String.t()}
          | {:allowed_tools, [String.t()]}
          | {:permission_mode, String.t()}
          | {:permission_prompt_tool, String.t()}
          | {:permission_prompts, String.t()}
          | {:max_budget_usd, number()}
          | {:session_id, String.t()}
          | {:resume, String.t()}
          | {:continue, boolean()}
          | {:add_dir, String.t() | [String.t()]}
          | {:include_partial_messages, boolean()}
          | {:no_session_persistence, boolean()}
          | {:settings, String.t()}
          | {:settings_file, String.t()}
          | {:settings_json, String.t() | map()}
          | {:setting_sources, [String.t()]}
          | {:mcp_config, mcp_config_entry() | [mcp_config_entry()]}
          | {:strict_mcp_config, boolean()}
          | {:agents, String.t() | map()}
          | {:plugin_dir, String.t()}
          | {:bare, boolean()}
          | {:extra_args, [String.t()]}
          | {:env, %{optional(String.t()) => String.t()}}
          | {:api_key, String.t()}
          | {:api_url, String.t()}

  @type opts :: [opt()]

  @doc """
  Builds the command and arguments for launching a CLI subprocess.

  Returns `{executable, args, env}` where `executable` is a string path or name,
  `args` is a list of string arguments, and `env` is a map of environment
  variables to set in the child process.

  Raises `ArgumentError` if any path-like option or env key/value fails
  validation (null bytes, control chars, malformed env keys).

  ## Options

    * `:executable` - CLI binary name or path (default: `"claude"`)
    * `:model` - model to use (e.g. `"sonnet"`, `"opus"`)
    * `:system_prompt` - custom system prompt
    * `:allowed_tools` - list of allowed tool names
    * `:permission_mode` - permission mode string
    * `:permission_prompt_tool` - who answers permission prompts: `"stdio"` for
      the host over the control channel, or the name of an MCP tool.
      `CrowdControl.Agent.ClaudeCode` sets `"stdio"` itself when `:can_use_tool`
      is given
    * `:permission_prompts` - `"host"` (default: wait for the prompt tool) or
      `"none"` (deny anything that would prompt; CLI 2.1.259+)
    * `:max_budget_usd` - spending ceiling as a number
    * `:session_id` - session ID for new sessions
    * `:resume` - session ID to resume
    * `:continue` - `true` to continue the most recent session
    * `:add_dir` - additional project directory (string or list of strings, sanitized + expanded)
    * `:include_partial_messages` - `true` to include streaming deltas
    * `:no_session_persistence` - `true` to skip saving to disk
    * `:settings_file` - path to a settings JSON file (sanitized + expanded)
    * `:settings_json` - inline settings JSON (string or map)
    * `:settings` - **deprecated**; use `:settings_file` or `:settings_json`. Heuristic: a
      string starting with `{` is treated as inline JSON, otherwise as a file path
    * `:setting_sources` - list of setting sources (e.g. `["user", "project", "local"]`)
    * `:mcp_config` - MCP config path(s) (sanitized + expanded), inline
      `%{"mcpServers" => ...}` map(s), or a list mixing both. Each map becomes
      one JSON argv token, and every server in it must name its `"type"`: the
      CLI silently skips a typeless entry. Inline maps land in argv, so keep
      credentials in a config file or the environment, not in a map
    * `:strict_mcp_config` - `true` to only use MCP servers from `:mcp_config`
    * `:agents` - JSON string or map defining custom agents
    * `:plugin_dir` - path to a plugin directory (sanitized + expanded)
    * `:bare` - `true` for minimal mode
    * `:extra_args` - list of additional string arguments
    * `:env` - map of environment variables (keys must match `~r/\\A[A-Za-z_][A-Za-z0-9_]*\\z/`,
      values must be binaries with no C0 control characters, i.e. `[\\x00-\\x1f]`)
    * `:api_key` - shorthand for setting `ANTHROPIC_API_KEY`
    * `:api_url` - shorthand for setting `ANTHROPIC_BASE_URL`
  """
  @spec build_command(opts()) :: {String.t(), [String.t()], %{optional(String.t()) => String.t()}}
  def build_command(opts \\ []) do
    executable = Keyword.get(opts, :executable, "claude")
    args = @base_args ++ build_optional_args(opts)
    env = build_env(opts)

    {executable, args, env}
  end

  @doc """
  The lowest Claude Code release this module's flags and the control protocol
  are built against.
  """
  @spec min_version() :: String.t()
  def min_version, do: @min_version

  @doc """
  Every flag `build_command/1` can emit, as
  `%{flag: "--model", operand: true, hidden: false}`.

  `operand` is whether the flag takes a value; `hidden` flags are accepted by
  the CLI but absent from `claude --help`. `mix crowd_control.contract` checks
  each one against a real binary.
  """
  @spec contract_flags() :: [%{flag: String.t(), operand: boolean(), hidden: boolean()}]
  def contract_flags, do: @contract_flags

  defp build_optional_args(opts) do
    []
    |> maybe_add("--model", opts[:model])
    |> maybe_add("--system-prompt", opts[:system_prompt])
    |> maybe_add_list("--allowed-tools", opts[:allowed_tools])
    |> maybe_add("--permission-mode", opts[:permission_mode])
    |> maybe_add_text("--permission-prompt-tool", opts[:permission_prompt_tool])
    |> maybe_add_permission_prompts(opts[:permission_prompts])
    |> maybe_add("--max-budget-usd", opts[:max_budget_usd])
    |> maybe_add("--session-id", opts[:session_id])
    |> maybe_add("--resume", opts[:resume])
    |> maybe_add_paths("--add-dir", opts[:add_dir])
    |> maybe_add_settings(opts)
    |> maybe_add_list("--setting-sources", opts[:setting_sources])
    |> maybe_add_mcp_config(opts[:mcp_config])
    |> maybe_add_agents(opts[:agents])
    |> maybe_add_path("--plugin-dir", opts[:plugin_dir])
    |> maybe_add_flag("--continue", opts[:continue])
    |> maybe_add_flag("--include-partial-messages", opts[:include_partial_messages])
    |> maybe_add_flag("--no-session-persistence", opts[:no_session_persistence])
    |> maybe_add_flag("--strict-mcp-config", opts[:strict_mcp_config])
    |> maybe_add_flag("--bare", opts[:bare])
    |> maybe_add_extra(opts[:extra_args])
    |> Enum.reverse()
  end

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, flag, value), do: [to_string(value), flag | args]

  defp maybe_add_text(args, _flag, nil), do: args

  defp maybe_add_text(args, flag, value) when is_binary(value) and value != "" do
    validate_no_control_chars!(value, inspect(flag))
    [value, flag | args]
  end

  defp maybe_add_text(_args, flag, other),
    do: raise(ArgumentError, "#{flag} must be a non-empty binary, got: #{inspect(other)}")

  defp maybe_add_permission_prompts(args, nil), do: args

  defp maybe_add_permission_prompts(args, value) when value in @permission_prompts,
    do: [value, "--permission-prompts" | args]

  defp maybe_add_permission_prompts(_args, other) do
    raise ArgumentError,
          ":permission_prompts must be one of #{inspect(@permission_prompts)}, " <>
            "got: #{inspect(other)}"
  end

  defp maybe_add_list(args, _flag, nil), do: args
  defp maybe_add_list(args, flag, values), do: [Enum.join(values, ","), flag | args]

  defp maybe_add_paths(args, _flag, nil), do: args

  defp maybe_add_paths(args, flag, values) when is_list(values) do
    sanitized = Enum.map(values, &sanitize_path!/1)
    Enum.reverse(sanitized) ++ [flag | args]
  end

  defp maybe_add_paths(args, flag, value), do: [sanitize_path!(value), flag | args]

  defp maybe_add_path(args, _flag, nil), do: args
  defp maybe_add_path(args, flag, value), do: [sanitize_path!(value), flag | args]

  defp maybe_add_flag(args, _flag, nil), do: args
  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, flag, true), do: [flag | args]

  defp maybe_add_mcp_config(args, nil), do: args

  defp maybe_add_mcp_config(args, configs) do
    tokens = configs |> List.wrap() |> Enum.map(&mcp_config_token!/1)
    Enum.reverse(tokens) ++ ["--mcp-config" | args]
  end

  defp mcp_config_token!(path) when is_binary(path), do: sanitize_path!(path)

  defp mcp_config_token!(config) when is_map(config) and not is_struct(config) do
    validate_mcp_servers!(config)
    JSON.encode!(config)
  end

  defp mcp_config_token!(other) do
    raise ArgumentError,
          ":mcp_config entries must be paths or maps, got: #{inspect(other)}"
  end

  defp validate_mcp_servers!(config) do
    servers =
      case fetch_either(config, "mcpServers", :mcpServers) do
        {:ok, servers} when is_map(servers) -> servers
        _ -> raise ArgumentError, "an inline :mcp_config map needs an \"mcpServers\" map"
      end

    Enum.each(servers, fn {name, server} ->
      case is_map(server) and fetch_either(server, "type", :type) do
        {:ok, type}
        when (is_binary(type) and type != "") or type in [:sdk, :stdio, :http, :sse, :ws] ->
          :ok

        _ ->
          raise ArgumentError,
                "MCP server #{inspect(name)} in :mcp_config has no \"type\"; " <>
                  "Claude Code skips a typeless server instead of failing"
      end
    end)
  end

  # Inline maps come from Elixir code, so accept atom or string keys alike.
  defp fetch_either(map, key, atom_key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, atom_key)
    end
  end

  defp maybe_add_agents(args, nil), do: args

  defp maybe_add_agents(args, agents) when is_map(agents),
    do: [JSON.encode!(agents), "--agents" | args]

  defp maybe_add_agents(args, agents) when is_binary(agents) do
    validate_no_control_chars!(agents, ":agents")
    [agents, "--agents" | args]
  end

  defp maybe_add_extra(args, nil), do: args

  defp maybe_add_extra(args, extra) when is_list(extra) do
    Enum.each(extra, fn arg ->
      unless is_binary(arg),
        do: raise(ArgumentError, "extra_args entries must be binaries, got: #{inspect(arg)}")

      validate_no_control_chars!(arg, ":extra_args")
    end)

    Enum.reverse(extra) ++ args
  end

  defp maybe_add_settings(args, opts) do
    cond do
      file = opts[:settings_file] -> [sanitize_path!(file), "--settings" | args]
      json = opts[:settings_json] -> [normalize_settings_json!(json), "--settings" | args]
      raw = opts[:settings] -> add_deprecated_settings(args, raw)
      true -> args
    end
  end

  defp add_deprecated_settings(args, raw) do
    Logger.warning(
      "CrowdControl: :settings option is deprecated; use :settings_file or :settings_json"
    )

    [resolve_legacy_settings!(raw), "--settings" | args]
  end

  defp resolve_legacy_settings!(raw) when is_map(raw), do: JSON.encode!(raw)

  defp resolve_legacy_settings!(raw) when is_binary(raw) do
    if String.starts_with?(String.trim_leading(raw), "{") do
      normalize_settings_json!(raw)
    else
      sanitize_path!(raw)
    end
  end

  defp resolve_legacy_settings!(other),
    do: raise(ArgumentError, ":settings must be a binary or map, got: #{inspect(other)}")

  defp normalize_settings_json!(json) when is_map(json), do: JSON.encode!(json)

  defp normalize_settings_json!(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, _} -> json
      {:error, reason} -> raise ArgumentError, "invalid :settings_json: #{inspect(reason)}"
    end
  end

  defp normalize_settings_json!(other),
    do: raise(ArgumentError, ":settings_json must be binary or map, got: #{inspect(other)}")

  @doc """
  Sanitizes a filesystem path. Rejects non-binaries, null bytes, and
  C0 control characters (`[\\x00-\\x1f]`). Returns the expanded absolute path.

  Raises `ArgumentError` on invalid input.
  """
  @spec sanitize_path!(term()) :: String.t()
  def sanitize_path!(path) when is_binary(path) do
    validate_no_control_chars!(path, "path")
    Path.expand(path)
  end

  def sanitize_path!(other),
    do: raise(ArgumentError, "path must be a binary, got: #{inspect(other)}")

  # NEVER echo the offending value. This runs on env values -- including
  # :api_key -- and build_env/1 is called from Session.init/1, so a raise here
  # becomes a GenServer crash report that carries the secret into Logger,
  # erl_crash.dump, and any error-reporting handler. Reading a key out of a file
  # leaves a trailing newline, which is enough to trigger it. Report the
  # position and size instead; that is sufficient to debug the input.
  defp validate_no_control_chars!(value, label) when is_binary(value) do
    case :binary.match(value, @control_bytes) do
      :nomatch ->
        :ok

      {pos, _} ->
        kind = if :binary.at(value, pos) == 0, do: "a null byte", else: "a control character"

        raise ArgumentError,
              "#{label} contains #{kind} at byte #{pos} " <>
                "(#{byte_size(value)} bytes); value redacted"
    end
  end

  @doc """
  Builds the environment variable map from options.

  Merges `:api_key` and `:api_url` shorthands with the `:env` map.
  Explicit `:env` entries take precedence over shorthands.

  Validates every key against `~r/\\A[A-Za-z_][A-Za-z0-9_]*\\z/` and ensures
  values are binaries with no C0 control characters (`[\\x00-\\x1f]`),
  raising `ArgumentError` on violation to prevent shell injection through the
  env-file mechanism. (DEL `\\x7f` and Unicode separators are left to
  `shell_escape/1`, which renders every surviving byte inert.)
  """
  @spec build_env(opts()) :: %{optional(String.t()) => String.t()}
  def build_env(opts) do
    env =
      %{}
      |> put_shorthand!("ANTHROPIC_API_KEY", opts[:api_key], :api_key)
      |> put_shorthand!("ANTHROPIC_BASE_URL", opts[:api_url], :api_url)
      |> merge_env_opt!(opts[:env])

    validate_env!(env)
    env
  end

  defp put_shorthand!(map, _key, nil, _label), do: map
  defp put_shorthand!(map, key, value, _label) when is_binary(value), do: Map.put(map, key, value)

  defp put_shorthand!(_map, _key, other, label),
    do: raise(ArgumentError, "#{inspect(label)} must be a binary, got: #{inspect(other)}")

  defp merge_env_opt!(base, nil), do: base
  defp merge_env_opt!(base, env) when is_map(env), do: Map.merge(base, env)

  defp merge_env_opt!(_base, other),
    do: raise(ArgumentError, ":env must be a map, got: #{inspect(other)}")

  defp validate_env!(env) do
    Enum.each(env, fn {key, value} ->
      unless is_binary(key) and Regex.match?(@env_key_re, key) do
        raise ArgumentError,
              "env key must match #{inspect(Regex.source(@env_key_re))}, got: #{inspect(key)}"
      end

      unless is_binary(value) do
        raise ArgumentError, "env value for #{key} must be a binary, got: #{inspect(value)}"
      end

      validate_no_control_chars!(value, "env value for #{key}")
    end)
  end
end
