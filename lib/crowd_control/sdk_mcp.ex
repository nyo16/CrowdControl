defmodule CrowdControl.SdkMcp do
  @moduledoc """
  In-BEAM MCP tool servers, reached by Claude Code over the control channel.

  A server built here runs inside the BEAM, not as a subprocess: the CLI sends
  each MCP JSON-RPC message as an `mcp_message` control request, and the session
  answers with the server's reply. Pass servers to a session under
  `:sdk_mcp_servers`, keyed by the name the CLI should know them by:

      server =
        CrowdControl.SdkMcp.tool_server("app", [
          %{
            name: "lookup_order",
            description: "Look up an order by id",
            input_schema: %{
              "type" => "object",
              "properties" => %{"id" => %{"type" => "string"}},
              "required" => ["id"]
            },
            call: {MyApp.Tools, :lookup_order, []},
            idempotent: true
          }
        ])

      CrowdControl.run("Where is order 42?", sdk_mcp_servers: %{"app" => server})

  The model then sees the tool as `mcp__app__lookup_order`.

  ## Tools

  Each tool is a map:

    * `:name` - required, unique within the server
    * `:call` - required, an MFA `{module, function, extra_args}`, called as
      `apply(module, function, [arguments | extra_args])` with the tool's
      JSON arguments (a string-keyed map). Funs are refused: session options
      are persisted, and a closure cannot be.
    * `:description` - optional, defaults to `""`
    * `:input_schema` - optional JSON Schema, defaults to an empty object schema
    * `:idempotent` - optional, defaults to `false`. A session that reattaches
      to a CLI with a tool call still in flight re-runs the call only when this
      is `true`; otherwise it answers with a JSON-RPC error, because the first
      run may or may not have completed.

  The call returns:

    * `{:ok, text}` - a single text content block
    * `{:ok, [block]}` - a list of MCP content blocks, sent as-is
    * `{:ok, %{} = result}` - a complete MCP `CallToolResult`, sent as-is
    * `{:error, text}` - a tool error the model sees (`isError: true`)

  A call that raises, throws or exits, or returns anything else, becomes the
  JSON-RPC error `-32603`.

  `handle/2` is the whole protocol: `initialize`, `ping`, `tools/list`,
  `tools/call`, and an empty acknowledgement for notifications. It touches no
  process state, so a session can run it wherever it likes.
  """

  @enforce_keys [:name, :tools]
  defstruct [:name, :tools, version: "1.0.0"]

  @typedoc "One tool; see the module doc."
  @type tool :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          call: {module(), atom(), list()},
          idempotent: boolean()
        }

  @type t :: %__MODULE__{name: String.t(), tools: [tool()], version: String.t()}

  @typedoc "A decoded JSON-RPC 2.0 message."
  @type jsonrpc :: map()

  # Echoed back when the client names none.
  @protocol_version "2025-06-18"

  @method_not_found -32_601
  @invalid_request -32_600
  @invalid_params -32_602
  @internal_error -32_603

  @doc """
  Builds a server named `name` (reported as its `serverInfo.name`) from a list
  of tool maps. Raises `ArgumentError` on a malformed tool or a duplicate name.
  """
  @spec tool_server(String.t(), [map()]) :: t()
  def tool_server(name, tools) when is_binary(name) and name != "" and is_list(tools) do
    tools = Enum.map(tools, &tool!/1)

    case tools |> Enum.frequencies_by(& &1.name) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil ->
        %__MODULE__{name: name, tools: tools}

      {dup, _} ->
        raise ArgumentError, "tool_server #{inspect(name)}: duplicate tool #{inspect(dup)}"
    end
  end

  def tool_server(name, tools) do
    raise ArgumentError,
          "tool_server expects a non-empty name and a list of tools, got: " <>
            "#{inspect(name)}, #{inspect(tools)}"
  end

  defp tool!(%{name: name, call: call} = tool) when is_binary(name) and name != "" do
    description = Map.get(tool, :description, "")
    schema = Map.get(tool, :input_schema, %{"type" => "object", "properties" => %{}})
    idempotent = Map.get(tool, :idempotent, false)

    unless mfa?(call) do
      raise ArgumentError,
            "tool #{inspect(name)} :call must be an MFA tuple {module, function, extra_args}, " <>
              "got: #{inspect(call)}"
    end

    unless is_binary(description),
      do: raise(ArgumentError, "tool #{name} :description must be a binary")

    unless is_map(schema), do: raise(ArgumentError, "tool #{name} :input_schema must be a map")

    unless is_boolean(idempotent),
      do: raise(ArgumentError, "tool #{name} :idempotent must be a boolean")

    %{
      name: name,
      description: description,
      input_schema: schema,
      call: call,
      idempotent: idempotent
    }
  end

  defp tool!(other) do
    raise ArgumentError,
          "a tool needs at least a binary :name and a :call MFA, got: #{inspect(other)}"
  end

  defp mfa?({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: true
  defp mfa?(_other), do: false

  @doc """
  Answers one JSON-RPC message.

  Always returns a JSON-RPC map: a notification (no `"id"`) gets
  `%{"jsonrpc" => "2.0", "result" => %{}}`, because the control request that
  carried it still needs an answer.

      iex> server = CrowdControl.SdkMcp.tool_server("app", [])
      iex> CrowdControl.SdkMcp.handle(server, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}}
  """
  @spec handle(t(), jsonrpc()) :: jsonrpc()
  def handle(%__MODULE__{} = server, %{"method" => method} = message) when is_binary(method) do
    case Map.fetch(message, "id") do
      :error -> %{"jsonrpc" => "2.0", "result" => %{}}
      {:ok, id} -> request(server, method, id, Map.get(message, "params"))
    end
  end

  def handle(%__MODULE__{}, message) do
    id = if is_map(message), do: Map.get(message, "id")
    error_response(id, @invalid_request, "Invalid Request")
  end

  @doc """
  Whether answering `message` twice is harmless: true for everything except a
  `tools/call` of a tool that is not declared `idempotent: true` (or is
  unknown).
  """
  @spec idempotent?(t(), jsonrpc()) :: boolean()
  def idempotent?(%__MODULE__{} = server, %{"method" => "tools/call"} = message) do
    case find_tool(server, get_in_params(message, "name")) do
      %{idempotent: true} -> true
      _other -> false
    end
  end

  def idempotent?(%__MODULE__{}, _message), do: true

  @doc """
  A JSON-RPC error response for `id`.

      iex> CrowdControl.SdkMcp.error_response(7, -32603, "boom")
      %{"jsonrpc" => "2.0", "id" => 7, "error" => %{"code" => -32603, "message" => "boom"}}
  """
  @spec error_response(term(), integer(), String.t()) :: jsonrpc()
  def error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp request(server, "initialize", id, params) do
    version =
      case params do
        %{"protocolVersion" => v} when is_binary(v) -> v
        _ -> @protocol_version
      end

    result(id, %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => server.name, "version" => server.version}
    })
  end

  defp request(_server, "ping", id, _params), do: result(id, %{})

  defp request(server, "tools/list", id, _params) do
    tools =
      Enum.map(server.tools, fn tool ->
        %{
          "name" => tool.name,
          "description" => tool.description,
          "inputSchema" => tool.input_schema
        }
      end)

    result(id, %{"tools" => tools})
  end

  defp request(server, "tools/call", id, params) do
    name = if is_map(params), do: Map.get(params, "name")

    case find_tool(server, name) do
      nil ->
        error_response(id, @invalid_params, "Unknown tool: #{inspect(name)}")

      tool ->
        arguments =
          case params do
            %{"arguments" => args} when is_map(args) -> args
            _ -> %{}
          end

        call_tool(tool, id, arguments)
    end
  end

  defp request(_server, method, id, _params),
    do: error_response(id, @method_not_found, "Method not found: #{method}")

  defp call_tool(%{call: {m, f, a}} = tool, id, arguments) do
    case apply(m, f, [arguments | a]) do
      {:ok, text} when is_binary(text) ->
        result(id, %{"content" => [%{"type" => "text", "text" => text}]})

      {:ok, content} when is_list(content) ->
        result(id, %{"content" => content})

      {:ok, %{} = call_result} ->
        result(id, call_result)

      {:error, text} when is_binary(text) ->
        result(id, %{"content" => [%{"type" => "text", "text" => text}], "isError" => true})

      _other ->
        error_response(id, @internal_error, "tool #{tool.name} returned an invalid result")
    end
  catch
    _kind, _reason -> error_response(id, @internal_error, "tool #{tool.name} crashed")
  end

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp find_tool(_server, name) when not is_binary(name), do: nil
  defp find_tool(server, name), do: Enum.find(server.tools, &(&1.name == name))

  defp get_in_params(%{"params" => %{} = params}, key), do: Map.get(params, key)
  defp get_in_params(_message, _key), do: nil
end
