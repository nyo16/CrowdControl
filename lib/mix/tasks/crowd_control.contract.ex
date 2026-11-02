defmodule Mix.Tasks.CrowdControl.Contract do
  @shortdoc "Checks a Claude Code binary against the flags and frames CrowdControl uses"

  @moduledoc """
  Checks a Claude Code binary against what `CrowdControl.CLI` and
  `CrowdControl.Agent.ClaudeCode` assume about it, so a CLI release that renames
  a flag or moves a control-protocol field fails here instead of in a session.

      mix crowd_control.contract
      CC_CONTRACT_BIN=/opt/claude/bin/claude CC_CONTRACT_VERSION=2.1.292 mix crowd_control.contract

  ## Inputs

    * `CC_CONTRACT_BIN` (or `--bin`) - the binary to check; defaults to `claude`
      on `PATH`
    * `CC_CONTRACT_VERSION` (or `--version`) - optional; the exact version the
      binary must report, for a CI job that installs a pinned release

  ## Checks

    1. `--version` is at least `CrowdControl.CLI.min_version/0` (and equals
       `CC_CONTRACT_VERSION` when given).
    2. Every flag in `CrowdControl.CLI.contract_flags/0` is listed by `--help`,
       or, for a hidden flag, the parser answers its bare use with an
       "argument missing" error rather than "unknown option".
    3. A live control probe. The binary is started with the argv the Claude
       Code adapter builds for a session with
       `:can_use_tool`, `:hooks` and `:sdk_mcp_servers`, and is sent that
       session's `initialize` frame twice, then an `interrupt`. Both
       `initialize` replies must succeed with `pending_permission_requests` at
       envelope level, and the `interrupt` reply must carry `still_queued`.

  The probe sends no prompt, so it makes no model call and needs no API key: it
  runs with a throwaway `CLAUDE_CONFIG_DIR` and with every credential variable
  removed from the child's environment.

  Exits non-zero, listing every mismatch, when any check fails.
  """

  use Mix.Task

  alias CrowdControl.Agent.ClaudeCode
  alias CrowdControl.{CLI, Protocol}

  @switches [bin: :string, version: :string]

  @cmd_timeout 30_000
  @frame_timeout 30_000

  # Removed from the probe's environment: the probe must prove it needs no
  # API access, and a credential has no business in a throwaway child.
  @scrubbed_env ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
                   ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR)

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    bin = resolve_bin(opts[:bin] || System.get_env("CC_CONTRACT_BIN"))
    expected = opts[:version] || System.get_env("CC_CONTRACT_VERSION")

    Mix.shell().info("Checking #{bin} against CrowdControl's CLI contract")

    failures =
      check_version(bin, expected) ++ check_flags(bin) ++ check_probe(bin)

    case failures do
      [] ->
        Mix.shell().info("CLI contract holds")

      failures ->
        Mix.raise(
          "CLI contract broken (#{length(failures)} mismatch(es)):\n" <>
            Enum.map_join(failures, "\n", &("  * " <> &1))
        )
    end
  end

  defp resolve_bin(nil) do
    System.find_executable("claude") ||
      Mix.raise("claude not found on PATH; set CC_CONTRACT_BIN to the binary to check")
  end

  defp resolve_bin(path) do
    cond do
      File.regular?(path) -> path
      found = System.find_executable(path) -> found
      true -> Mix.raise("CC_CONTRACT_BIN #{inspect(path)} is not an executable")
    end
  end

  # --- 1. version ---

  defp check_version(bin, expected) do
    {output, _status} = cmd(bin, ["--version"])
    min = CLI.min_version()

    case Regex.run(~r/\d+\.\d+\.\d+/, output) do
      [have] ->
        Mix.shell().info("  version #{have} (minimum #{min})")

        List.wrap(
          if Version.compare(have, min) == :lt,
            do: "version #{have} is below the minimum #{min}"
        ) ++
          List.wrap(
            if expected && have != expected,
              do: "version #{have} is not the expected #{expected}"
          )

      nil ->
        ["--version printed no version: #{inspect(String.slice(output, 0, 200))}"]
    end
  end

  # --- 2. flags ---

  defp check_flags(bin) do
    {help, _status} = cmd(bin, ["--help"])

    Enum.flat_map(CLI.contract_flags(), fn
      %{flag: flag, hidden: false} ->
        if listed?(help, flag), do: [], else: ["flag #{flag} is not listed by --help"]

      %{flag: flag, hidden: true, operand: true} ->
        check_hidden_flag(bin, flag)

      %{flag: flag, hidden: true, operand: false} ->
        ["flag #{flag} is hidden and takes no operand, so the contract cannot prove it"]
    end)
  end

  # Word-bounded, so `--settings` is not satisfied by `--setting-sources` and
  # `--allowed-tools` is found in `--allowedTools, --allowed-tools <tools...>`.
  defp listed?(help, flag),
    do: Regex.match?(~r/(?<![\w-])#{Regex.escape(flag)}(?![\w-])/, help)

  # `claude -p --flag` with no operand: a parser that knows the flag complains
  # that its argument is missing; one that does not says "unknown option".
  defp check_hidden_flag(bin, flag) do
    {output, _status} = cmd(bin, ["--print", flag])

    if output =~ "argument missing" and output =~ flag and not (output =~ "unknown option"),
      do: [],
      else: ["hidden flag #{flag} is not recognised: #{inspect(String.slice(output, 0, 200))}"]
  end

  # --- 3. control probe ---

  # Never invoked: the probe sends no prompt, so nothing asks for approval.
  @doc false
  def unreachable_callback(_request, _context), do: :ok

  defp probe_opts(bin) do
    callback = {__MODULE__, :unreachable_callback, []}

    [
      executable: bin,
      can_use_tool: callback,
      hooks: %{"PreToolUse" => [%{matcher: "Bash", hooks: [callback], timeout: 30}]},
      sdk_mcp_servers: %{"contract" => :probe},
      permission_prompts: "host",
      strict_mcp_config: true,
      no_session_persistence: true,
      setting_sources: [""]
    ]
  end

  defp check_probe(bin) do
    opts = probe_opts(bin)
    {executable, args, _env} = ClaudeCode.build_command(opts)
    [init] = ClaudeCode.init_frames(opts)
    tmp = Path.join(System.tmp_dir!(), "cc-contract-#{System.unique_integer([:positive])}")
    config_dir = Path.join(tmp, "config")
    File.mkdir_p!(config_dir)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4 * 1024 * 1024},
        {:args, args},
        {:cd, tmp},
        {:env, probe_env(config_dir)}
      ])

    try do
      run_probe(port, init)
    after
      close(port)
      File.rm_rf(tmp)
    end
  end

  defp probe_env(config_dir) do
    Enum.map(@scrubbed_env, &{String.to_charlist(&1), false}) ++
      [
        {~c"CLAUDE_CONFIG_DIR", String.to_charlist(config_dir)},
        {~c"DISABLE_AUTOUPDATER", ~c"1"},
        {~c"DISABLE_TELEMETRY", ~c"1"},
        {~c"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", ~c"1"}
      ]
  end

  defp run_probe(port, init) do
    init_id = ClaudeCode.init_request_id()

    first = request(port, init, init_id)
    second = request(port, init, init_id)

    interrupt =
      request(
        port,
        Protocol.encode_control_request("contract_interrupt", %{"subtype" => "interrupt"}),
        "contract_interrupt"
      )

    check_init(first, "first initialize") ++
      check_init(second, "repeated initialize") ++ check_interrupt(interrupt)
  end

  defp check_init({:ok, {:ok, response}, envelope}, label) do
    Mix.shell().info("  #{label}: success")

    cond do
      not is_list(Map.get(envelope, "pending_permission_requests")) ->
        ["#{label}: no pending_permission_requests list at envelope level"]

      Map.has_key?(response, "pending_permission_requests") ->
        ["#{label}: pending_permission_requests moved inside response"]

      true ->
        []
    end
  end

  defp check_init({:ok, {:error, message}, _envelope}, label),
    do: ["#{label} was refused: #{message}"]

  defp check_init({:error, reason}, label), do: ["#{label}: #{reason}"]

  defp check_interrupt({:ok, {:ok, %{"still_queued" => queued}}, _envelope})
       when is_list(queued) do
    Mix.shell().info("  interrupt: still_queued")
    []
  end

  defp check_interrupt({:ok, {:ok, response}, _envelope}),
    do: ["interrupt reply has no still_queued list: #{inspect(response)}"]

  defp check_interrupt({:ok, {:error, message}, _envelope}),
    do: ["interrupt was refused: #{message}"]

  defp check_interrupt({:error, reason}), do: ["interrupt: #{reason}"]

  defp request(port, frame, id) do
    Port.command(port, frame)
    deadline = System.monotonic_time(:millisecond) + @frame_timeout
    await_response(port, id, deadline, "")
  end

  # Other frames (the CLI's own `mcp_message` handshake for the SDK server,
  # `system` notices, keep-alives) are skipped: the probe answers nothing.
  defp await_response(port, id, deadline, partial) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await_response(port, id, deadline, partial <> chunk)

      {^port, {:data, {:eol, chunk}}} ->
        case Protocol.decode_line(partial <> chunk) do
          {:control_response, ^id, result, envelope} -> {:ok, result, envelope}
          _other -> await_response(port, id, deadline, "")
        end

      {^port, {:exit_status, status}} ->
        {:error, "the CLI exited with status #{status} before answering #{id}"}
    after
      wait -> {:error, "no control_response for #{id} within #{@frame_timeout} ms"}
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- helpers ---

  # System.cmd/3 has no timeout, and a binary that misreads its argv as a
  # prompt would wait on stdin forever. A port can be closed, which also
  # closes the child's stdin.
  defp cmd(bin, args) do
    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    collect(port, "", System.monotonic_time(:millisecond) + @cmd_timeout)
  end

  defp collect(port, acc, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, acc <> data, deadline)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      wait ->
        close(port)
        {acc, :timeout}
    end
  end
end
