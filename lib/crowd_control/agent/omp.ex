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
  | failed `prompt` response | `{:result, "error_prompt_failed", map}` |
  | anything else | `{:unknown, map}` |

  omp acknowledges a `prompt` command before the turn runs, so the completion
  signal is `agent_end` — and only when `isTerminal` is not `false`, since a
  `false` means maintenance or async delivery will resume the session. An
  `agent_end` is turned into a Claude-shaped result map: `"result"` is the final
  assistant text, `"total_cost_usd"` the summed cost of the turn's assistant
  messages, plus `"usage"`, `"num_turns"`, `"duration_ms"` and `"stop_reason"`.

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

  Claude-Code-only options (`:mcp_config`, `:strict_mcp_config`, `:agents`,
  `:plugin_dir`, `:settings`, `:settings_file`, `:settings_json`,
  `:setting_sources`, `:max_budget_usd`, `:session_id`, `:bare`) have no omp
  equivalent and raise `ArgumentError` rather than being dropped silently.
  `:include_partial_messages` is accepted and ignored: RPC mode always streams
  deltas as `message_update` frames.
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

    executable = Keyword.get(opts, :executable, "omp")
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

  # --- argv ---

  defp reject_unsupported!(opts) do
    Enum.each(@unsupported, fn {key, hint} ->
      if not is_nil(opts[key]) do
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

  defp classify(%{"type" => "agent_end", "isTerminal" => false} = map), do: {:stream_event, map}
  defp classify(%{"type" => "agent_end"} = map), do: {:result, "success", result(map)}

  defp classify(%{"type" => "message_end", "message" => %{"role" => "assistant"}} = map),
    do: {:assistant, map}

  defp classify(%{"type" => "message_end", "message" => %{"role" => "user"}} = map),
    do: {:user, map}

  defp classify(%{"type" => "message_update"} = map), do: {:stream_event, map}
  defp classify(map), do: {:unknown, map}

  defp system_init(data) do
    model = Map.get(data, "model") || %{}

    %{
      "type" => "system",
      "subtype" => "init",
      "agent" => "omp",
      "session_id" => data["sessionId"],
      "session_file" => data["sessionFile"],
      "model" => model["id"],
      "provider" => model["provider"],
      "context_window" => model["contextWindow"],
      "thinking_level" => data["thinkingLevel"],
      "tools" => data |> Map.get("dumpTools", []) |> Enum.map(& &1["name"])
    }
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
