defmodule CrowdControl.Protocol do
  @moduledoc """
  Pure functions for the Claude Code stream-json wire format.

  Messages are newline-delimited JSON objects on stdin/stdout.

  ## Control frames

  Besides conversation messages, the stream carries the control protocol: either
  side may send a `control_request`, and the receiver answers with exactly one
  `control_response` that echoes its `request_id`. The id sits *inside*
  `response`, not at the top level:

      {"type":"control_request","request_id":"…","request":{"subtype":"interrupt"}}
      {"type":"control_response","response":{"subtype":"success","request_id":"…","response":{}}}

  The CLI withdraws one of its own pending requests with
  `{"type":"control_cancel_request","request_id":"…"}` (no reply), and emits
  `{"type":"keep_alive"}` heartbeats that receivers must ignore.

  Subtypes stay binaries: they arrive from a subprocess and are never turned
  into atoms.
  """

  @type request_id :: String.t()

  @type control_result :: {:ok, map()} | {:error, String.t()}

  @typedoc """
  A `can_use_tool` answer for `encode_permission/2`.

    * `{:allow, input}` - run the tool with `input` (the original or an edited
      copy; it is always sent as `updatedInput`)
    * `{:allow, input, permissions}` - also apply permission updates
      (`updatedPermissions`, a list of `PermissionUpdate` maps)
    * `{:deny, message}` - refuse; the turn continues with `message` as the
      tool's error result
    * `{:deny, message, interrupt: true}` - refuse and stop the turn
  """
  @type permission_decision ::
          {:allow, map()}
          | {:allow, map(), [map()]}
          | {:deny, String.t()}
          | {:deny, String.t(), [{:interrupt, boolean()}]}

  @type message ::
          {:system_init, map()}
          | {:assistant, map()}
          | {:user, map()}
          | {:result, String.t(), map()}
          | {:stream_event, map()}
          | {:control_request, request_id(), subtype :: String.t(), request :: map()}
          | {:control_response, request_id(), control_result(), envelope :: map()}
          | {:control_cancel, request_id()}
          | :keep_alive
          | {:unknown, map()}
          | {:invalid_json, String.t()}

  @doc """
  Splits a binary buffer into complete lines and a remainder.

  Returns `{complete_lines, remainder}` where `complete_lines` is a list
  of binaries (without the trailing newline) and `remainder` is the
  incomplete trailing fragment (possibly empty).
  """
  @spec split_lines(binary()) :: {[binary()], binary()}
  def split_lines(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [only] -> {[], only}
      parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
    end
  end

  @doc """
  Decodes a single JSON line into a tagged tuple.

  Returns one of `t:message/0`; see `classify/1` for the object shapes.
  `{:invalid_json, raw_line}` when the input is not a JSON object.

  Does not raise; callers can safely pass arbitrary subprocess output.
  """
  @spec decode_line(binary()) :: message()
  def decode_line(json_string) when is_binary(json_string) do
    case JSON.decode(json_string) do
      {:ok, map} when is_map(map) -> classify(map)
      {:ok, _other} -> {:invalid_json, json_string}
      {:error, _reason} -> {:invalid_json, json_string}
    end
  end

  @doc """
  Classifies one decoded stream-json object.

  Returns one of:
    - `{:system_init, map}`
    - `{:assistant, map}`
    - `{:user, map}`
    - `{:result, subtype, map}`
    - `{:stream_event, map}`
    - `{:control_request, request_id, subtype, request}` for a CLI-originated
      request such as `can_use_tool`, `hook_callback` or `mcp_message`
    - `{:control_response, request_id, {:ok, response} | {:error, message}, envelope}`;
      `response` is `%{}` when the CLI sent none, and `envelope` is the whole
      `response` object of the frame, so envelope-level fields such as
      `pending_permission_requests` (on an `initialize` reply) stay reachable
    - `{:control_cancel, request_id}`
    - `:keep_alive`
    - `{:unknown, map}` for anything else, including control frames whose ids
      or subtypes are not strings

  Does not raise on any map.
  """
  @spec classify(map()) :: message()
  def classify(%{"type" => "system", "subtype" => "init"} = map), do: {:system_init, map}
  def classify(%{"type" => "assistant"} = map), do: {:assistant, map}
  def classify(%{"type" => "user"} = map), do: {:user, map}

  def classify(%{"type" => "result", "subtype" => subtype} = map),
    do: {:result, subtype, map}

  def classify(%{"type" => "stream_event"} = map), do: {:stream_event, map}

  def classify(
        %{
          "type" => "control_request",
          "request_id" => id,
          "request" => %{"subtype" => subtype} = request
        } = map
      ) do
    if is_binary(id) and is_binary(subtype),
      do: {:control_request, id, subtype, request},
      else: {:unknown, map}
  end

  def classify(%{"type" => "control_response", "response" => %{"request_id" => id} = env} = map)
      when is_binary(id) do
    case control_result(env) do
      {:ok, result} -> {:control_response, id, result, env}
      :error -> {:unknown, map}
    end
  end

  def classify(%{"type" => "control_cancel_request", "request_id" => id}) when is_binary(id),
    do: {:control_cancel, id}

  def classify(%{"type" => "keep_alive"}), do: :keep_alive
  def classify(map) when is_map(map), do: {:unknown, map}

  # "absent or {} for requests that are merely acknowledged"
  defp control_result(%{"subtype" => "success"} = env) do
    case Map.get(env, "response") do
      response when is_map(response) -> {:ok, {:ok, response}}
      _absent_or_null -> {:ok, {:ok, %{}}}
    end
  end

  defp control_result(%{"subtype" => "error"} = env) do
    case Map.get(env, "error") do
      message when is_binary(message) -> {:ok, {:error, message}}
      _other -> {:ok, {:error, ""}}
    end
  end

  defp control_result(_env), do: :error

  @doc """
  Encodes a user prompt as a stream-json stdin message.

  Returns a newline-terminated JSON string.
  """
  @spec encode_user_message(binary()) :: binary()
  def encode_user_message(prompt) when is_binary(prompt) do
    message = %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => prompt}
    }

    JSON.encode!(message) <> "\n"
  end

  @doc """
  Encodes a host-originated `control_request` (`initialize`, `interrupt`,
  `set_model`, …).

  `request` must carry its `"subtype"`. Returns a newline-terminated JSON string.

      iex> CrowdControl.Protocol.encode_control_request("req_1", %{"subtype" => "interrupt"})
      ~s({"request":{"subtype":"interrupt"},"request_id":"req_1","type":"control_request"}\\n)
  """
  @spec encode_control_request(request_id(), map()) :: binary()
  def encode_control_request(request_id, %{"subtype" => subtype} = request)
      when is_binary(request_id) and is_binary(subtype) do
    encode(%{"type" => "control_request", "request_id" => request_id, "request" => request})
  end

  @doc """
  Encodes the answer to a CLI-originated `control_request`.

  `{:ok, response}` becomes a `success` frame, `{:error, message}` an `error`
  frame. The `request_id` sits inside `response`. Returns a newline-terminated
  JSON string.
  """
  @spec encode_control_response(request_id(), control_result()) :: binary()
  def encode_control_response(request_id, {:ok, response})
      when is_binary(request_id) and is_map(response) do
    encode(%{
      "type" => "control_response",
      "response" => %{"subtype" => "success", "request_id" => request_id, "response" => response}
    })
  end

  def encode_control_response(request_id, {:error, message})
      when is_binary(request_id) and is_binary(message) do
    encode(%{
      "type" => "control_response",
      "response" => %{"subtype" => "error", "request_id" => request_id, "error" => message}
    })
  end

  @doc """
  Encodes the answer to a `can_use_tool` request; see `t:permission_decision/0`.

  An allow always carries `updatedInput`, even when the input is unchanged:
  older CLIs reject an allow without it. `interrupt` is sent only when true.
  """
  @spec encode_permission(request_id(), permission_decision()) :: binary()
  def encode_permission(request_id, decision) when is_binary(request_id),
    do: encode_control_response(request_id, {:ok, permission_response(decision)})

  defp permission_response({:allow, input}) when is_map(input),
    do: %{"behavior" => "allow", "updatedInput" => input}

  defp permission_response({:allow, input, permissions})
       when is_map(input) and is_list(permissions),
       do: %{"behavior" => "allow", "updatedInput" => input, "updatedPermissions" => permissions}

  defp permission_response({:deny, message}) when is_binary(message),
    do: %{"behavior" => "deny", "message" => message}

  defp permission_response({:deny, message, opts}) when is_binary(message) and is_list(opts) do
    if Keyword.get(opts, :interrupt, false) == true,
      do: %{"behavior" => "deny", "message" => message, "interrupt" => true},
      else: %{"behavior" => "deny", "message" => message}
  end

  defp permission_response(other),
    do: raise(ArgumentError, "invalid permission decision: #{inspect(other)}")

  defp encode(frame), do: JSON.encode!(frame) <> "\n"
end
