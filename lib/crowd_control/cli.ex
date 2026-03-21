defmodule CrowdControl.CLI do
  @moduledoc """
  Builds CLI commands for Claude Code and Open Code executables.
  """

  @base_args [
    "--print",
    "--output-format",
    "stream-json",
    "--input-format",
    "stream-json",
    "--verbose"
  ]

  @doc """
  Builds the command and arguments for launching a CLI subprocess.

  Returns `{executable, args}` where `executable` is a string path/name
  and `args` is a list of string arguments.

  ## Options

    * `:executable` - CLI binary name or path (default: `"claude"`)
    * `:model` - model to use (e.g. `"sonnet"`, `"opus"`)
    * `:system_prompt` - custom system prompt
    * `:allowed_tools` - list of allowed tool names
    * `:permission_mode` - permission mode string
    * `:max_budget_usd` - spending ceiling as a number
    * `:session_id` - session ID for new sessions
    * `:resume` - session ID to resume
    * `:continue` - `true` to continue the most recent session
    * `:add_dir` - additional project directory
    * `:include_partial_messages` - `true` to include streaming deltas
    * `:no_session_persistence` - `true` to skip saving to disk
    * `:extra_args` - list of additional string arguments
  """
  def build_command(opts \\ []) do
    executable = Keyword.get(opts, :executable, "claude")
    args = @base_args ++ build_optional_args(opts)

    {executable, args}
  end

  defp build_optional_args(opts) do
    []
    |> maybe_add("--model", opts[:model])
    |> maybe_add("--system-prompt", opts[:system_prompt])
    |> maybe_add_list("--allowed-tools", opts[:allowed_tools])
    |> maybe_add("--permission-mode", opts[:permission_mode])
    |> maybe_add("--max-budget-usd", opts[:max_budget_usd])
    |> maybe_add("--session-id", opts[:session_id])
    |> maybe_add("--resume", opts[:resume])
    |> maybe_add("--add-dir", opts[:add_dir])
    |> maybe_add_flag("--continue", opts[:continue])
    |> maybe_add_flag("--include-partial-messages", opts[:include_partial_messages])
    |> maybe_add_flag("--no-session-persistence", opts[:no_session_persistence])
    |> maybe_add_extra(opts[:extra_args])
  end

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_add_list(args, _flag, nil), do: args
  defp maybe_add_list(args, flag, values), do: args ++ [flag, Enum.join(values, ",")]

  defp maybe_add_flag(args, _flag, nil), do: args
  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, flag, true), do: args ++ [flag]

  defp maybe_add_extra(args, nil), do: args
  defp maybe_add_extra(args, extra), do: args ++ extra
end
