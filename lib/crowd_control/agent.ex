defmodule CrowdControl.Agent do
  @moduledoc """
  Adapter behaviour for a coding-agent CLI.

  A session talks to exactly one CLI, and every CLI differs in two places:
  the argv it is launched with, and the newline-delimited JSON it speaks on
  stdin/stdout. Everything else in `CrowdControl.Session` -- buffering,
  cursors, backpressure, retention, backends -- is agent-agnostic.

  Built-in adapters:

    * `CrowdControl.Agent.ClaudeCode` (`:claude`, `:claude_code`, `:open_code`) --
      Claude Code's `--output-format stream-json` wire format, also spoken by the
      `open-code` CLI.
    * `CrowdControl.Agent.Omp` (`:omp`) -- [Oh My Pi](https://omp.sh/) in
      `--mode rpc`, its newline-delimited JSON-RPC protocol.

  Adapters normalize their wire format into `t:CrowdControl.Protocol.message/0`,
  so a subscriber written against Claude Code works unchanged against omp: the
  session id still arrives as `{:system_init, %{"session_id" => id}}` and the
  end of a turn still arrives as `{:result, subtype, map}`.

  ## Selecting an adapter

  Pass `:agent` (an alias atom or a module implementing this behaviour):

      CrowdControl.run("hi", agent: :omp)

  When `:agent` is omitted it is inferred from the `:executable` basename
  (`"omp"` => `CrowdControl.Agent.Omp`), defaulting to
  `CrowdControl.Agent.ClaudeCode`.
  """

  @type env :: %{optional(String.t()) => String.t()}

  @doc """
  Builds `{executable, args, env}` for launching the CLI.

  Raises `ArgumentError` on options the adapter cannot express.
  """
  @callback build_command(keyword()) :: {String.t(), [String.t()], env()}

  @doc """
  Frames written to the CLI's stdin immediately after exec, before any prompt.

  Used for protocol handshakes; return `[]` when the CLI needs none.
  """
  @callback init_frames(keyword()) :: [binary()]

  @doc """
  Encodes a user prompt as a stdin frame.

  `seq` is a per-session counter starting at 0, so adapters that need request
  ids can mint stable ones without extra state.
  """
  @callback encode_prompt(prompt :: binary(), seq :: non_neg_integer(), keyword()) :: binary()

  @doc "Decodes one line of CLI stdout into a tagged message."
  @callback decode_line(binary()) :: CrowdControl.Protocol.message()

  @typedoc """
  One file an adapter needs inside the sandbox: an absolute in-sandbox path,
  its bytes, and its octal mode.
  """
  @type sandbox_file :: {Path.t(), iodata(), non_neg_integer()}

  @doc """
  Files this adapter needs written *inside* the sandbox before its CLI starts.

  Optional; an adapter that does not implement it stages nothing, which is why
  `CrowdControl.Agent.ClaudeCode` needs no change.

  A CLI that reads configuration from disk — `CrowdControl.Agent.Omp` resolving
  a custom provider's `baseUrl` out of `models.yml` — has a problem no argv or
  environment variable solves on a remote substrate: the file has to exist on
  the *sandbox's* filesystem, and a host temp directory is not visible there.
  Rendering is the adapter's job; writing is the backend's, since only the
  backend knows how bytes cross into its substrate.

  Must be pure and deterministic: it is called once per exec, after
  `c:CrowdControl.Backend.provision/1` (there is no sandbox to write to before
  that) and again on nothing else. Refuse a malformed option in
  `c:build_command/1` instead, which runs before a sandbox has been created
  and billed.
  """
  @callback sandbox_files(keyword()) :: [sandbox_file()]

  @typedoc """
  An optional feature an adapter declares through `c:capabilities/0`.

    * `:control` - speaks the stream-json control protocol (`c:encode_control/2`)
    * `:interrupt` - can stop a running turn without killing the CLI
    * `:sdk_mcp` - can host in-BEAM MCP servers over the control channel
  """
  @type capability :: :control | :interrupt | :sdk_mcp

  @typedoc """
  A control frame for `c:encode_control/2`:

    * `{:request, request_id, request}` - a host-originated request; `request`
      carries its `"subtype"`
    * `{:response, request_id, {:ok, map} | {:error, message}}` - the answer to
      a CLI-originated request
    * `{:permission, request_id, decision}` - the answer to `can_use_tool`; see
      `t:CrowdControl.Protocol.permission_decision/0`
  """
  @type control ::
          {:request, CrowdControl.Protocol.request_id(), map()}
          | {:response, CrowdControl.Protocol.request_id(),
             CrowdControl.Protocol.control_result()}
          | {:permission, CrowdControl.Protocol.request_id(),
             CrowdControl.Protocol.permission_decision()}

  @doc """
  The optional features this adapter supports. Optional; an adapter that does
  not implement it supports none (`CrowdControl.Agent.Omp`).
  """
  @callback capabilities() :: [capability()]

  @doc """
  Encodes a control frame for the CLI's stdin. Optional; required with the
  `:control` capability.
  """
  @callback encode_control(control(), keyword()) :: binary()

  @doc """
  Frames to write when a session reattaches to a CLI that is still running.
  Optional; an adapter that does not implement it writes nothing.

  They must re-register exactly what `c:init_frames/1` registered for the same
  opts, so they are deterministic in the opts and carry no fresh ids.
  """
  @callback reattach_frames(keyword()) :: [binary()]

  @optional_callbacks sandbox_files: 1, capabilities: 0, encode_control: 2, reattach_frames: 1

  @doc """
  The sandbox files `module` needs, or `[]` when it declares none.

  Probed rather than required, so an adapter opts in by defining
  `c:sandbox_files/1` and every other adapter is unaffected.
  """
  @spec sandbox_files(module(), keyword()) :: [sandbox_file()]
  def sandbox_files(module, opts) when is_atom(module) and is_list(opts) do
    if exports?(module, :sandbox_files, 1), do: module.sandbox_files(opts), else: []
  end

  @doc """
  Whether `module` declares `capability` through `c:capabilities/0`.

      iex> CrowdControl.Agent.capable?(CrowdControl.Agent.ClaudeCode, :control)
      true
      iex> CrowdControl.Agent.capable?(CrowdControl.Agent.Omp, :control)
      false
  """
  @spec capable?(module(), capability()) :: boolean()
  def capable?(module, capability) when is_atom(module) and is_atom(capability) do
    exports?(module, :capabilities, 0) and capability in module.capabilities()
  end

  @doc """
  The frames `module` writes on reattach, or `[]` when it declares none.
  """
  @spec reattach_frames(module(), keyword()) :: [binary()]
  def reattach_frames(module, opts) when is_atom(module) and is_list(opts) do
    if exports?(module, :reattach_frames, 1), do: module.reattach_frames(opts), else: []
  end

  defp exports?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  @aliases %{
    claude: CrowdControl.Agent.ClaudeCode,
    claude_code: CrowdControl.Agent.ClaudeCode,
    open_code: CrowdControl.Agent.ClaudeCode,
    opencode: CrowdControl.Agent.ClaudeCode,
    omp: CrowdControl.Agent.Omp
  }

  @executables %{"omp" => CrowdControl.Agent.Omp}

  @doc """
  Resolves the adapter module for a set of session options.

  Explicit `:agent` wins; otherwise the `:executable` basename decides; otherwise
  `CrowdControl.Agent.ClaudeCode`.

      iex> CrowdControl.Agent.resolve(agent: :omp)
      CrowdControl.Agent.Omp

      iex> CrowdControl.Agent.resolve(executable: "/opt/homebrew/bin/omp")
      CrowdControl.Agent.Omp

      iex> CrowdControl.Agent.resolve([])
      CrowdControl.Agent.ClaudeCode
  """
  @spec resolve(keyword()) :: module()
  def resolve(opts) when is_list(opts) do
    case Keyword.get(opts, :agent) do
      nil -> infer(opts[:executable])
      other -> from_alias!(other)
    end
  end

  defp from_alias!(name) when is_atom(name) and not is_nil(name) do
    case Map.fetch(@aliases, name) do
      {:ok, module} ->
        module

      :error ->
        # Not an alias: accept any module that actually implements the
        # behaviour. Checking exports (rather than trusting the atom) turns a
        # typo into an argument error here instead of an UndefinedFunctionError
        # inside a GenServer init hundreds of lines later.
        if agent_module?(name) do
          name
        else
          raise ArgumentError,
                ":agent must be one of #{inspect(Map.keys(@aliases))} or a module " <>
                  "implementing CrowdControl.Agent, got: #{inspect(name)}"
        end
    end
  end

  defp from_alias!(other),
    do: raise(ArgumentError, ":agent must be an atom or module, got: #{inspect(other)}")

  defp agent_module?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :build_command, 1) and
      function_exported?(module, :init_frames, 1) and
      function_exported?(module, :encode_prompt, 3) and
      function_exported?(module, :decode_line, 1)
  end

  defp infer(executable) when is_binary(executable),
    do: Map.get(@executables, Path.basename(executable), CrowdControl.Agent.ClaudeCode)

  defp infer(_), do: CrowdControl.Agent.ClaudeCode
end
