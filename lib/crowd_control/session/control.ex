defmodule CrowdControl.Session.Control do
  @moduledoc false
  # The control-protocol half of CrowdControl.Session's state, plus the pure
  # functions over it: option validation, the pending-request map, decision
  # shapes, and the form persisted to CrowdControl.Store. Everything with a side
  # effect (writes, timers, tasks, broadcasts) stays in Session.
  #
  # `pending` is keyed `{request_id, byte_offset}`: the CLI promises request ids
  # unique only among its in-flight requests, and the offset of the line that
  # carried the request makes a capture replay recognisable. Entries recovered
  # from an `initialize` reply have no line, so their offset is `nil`.

  alias CrowdControl.{Agent, SdkMcp}
  alias CrowdControl.Agent.ClaudeCode

  @default_interrupt_grace 30_000

  @typedoc "An MFA callback: called as `apply(m, f, [request, context | extra])`."
  @type callback :: {module(), atom(), list()}

  @type status :: :received | :dispatched | :deferred
  @type key :: {String.t(), non_neg_integer() | nil}
  @type entry :: %{subtype: String.t(), request: map(), status: status()}

  @typedoc "An answer ready to encode: `c:CrowdControl.Agent.encode_control/2` minus the id."
  @type reply ::
          {:permission, CrowdControl.Protocol.permission_decision()}
          | {:response, CrowdControl.Protocol.control_result()}

  @type t :: %__MODULE__{
          capable?: boolean(),
          features?: boolean(),
          can_use_tool: callback() | nil,
          on_control_request: callback() | nil,
          hooks: %{String.t() => callback()},
          sdk_servers: %{String.t() => SdkMcp.t()},
          permission_timeout: pos_integer() | :infinity,
          interrupt_grace: non_neg_integer(),
          pending: %{key() => entry()},
          outbound: %{String.t() => %{from: term(), timer: reference() | nil}},
          tasks: %{key() => {pid(), reference()}},
          permission_timers: %{key() => reference()},
          turn_deadline_at: integer() | nil,
          paused_remaining_ms: non_neg_integer() | nil,
          grace_ref: reference() | nil,
          reconciling: boolean(),
          seq: non_neg_integer()
        }

  defstruct capable?: false,
            features?: false,
            can_use_tool: nil,
            on_control_request: nil,
            hooks: %{},
            sdk_servers: %{},
            permission_timeout: :infinity,
            interrupt_grace: 0,
            pending: %{},
            outbound: %{},
            tasks: %{},
            permission_timers: %{},
            turn_deadline_at: nil,
            paused_remaining_ms: nil,
            grace_ref: nil,
            reconciling: false,
            seq: 0

  @doc """
  Validated control configuration for a session's opts. Raises `ArgumentError`
  on a fun callback (session opts are persisted, and a closure cannot be) or any
  other malformed control option, so a bad option fails before provisioning.
  """
  @spec new(keyword(), module()) :: t()
  def new(opts, agent) do
    capable = Agent.capable?(agent, :control)
    features = capable and features?(opts)

    %__MODULE__{
      capable?: capable,
      features?: features,
      can_use_tool: callback_opt!(opts, :can_use_tool),
      on_control_request: callback_opt!(opts, :on_control_request),
      # `:hooks` is a ClaudeCode map only on a control-capable agent; omp keeps
      # its own path-list meaning of the same key.
      hooks: if(capable, do: hooks!(opts), else: %{}),
      sdk_servers: sdk_servers!(opts),
      permission_timeout: permission_timeout!(opts),
      interrupt_grace: interrupt_grace!(opts, features, Agent.capable?(agent, :interrupt))
    }
  end

  # The options that make ClaudeCode send `initialize`: the ones that need a
  # control-protocol CLI.
  defp features?(opts) do
    opts[:can_use_tool] != nil or nonempty_map?(opts[:hooks]) or
      nonempty_map?(opts[:sdk_mcp_servers])
  end

  defp nonempty_map?(value), do: is_map(value) and map_size(value) > 0

  defp callback_opt!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      callback -> callback!(callback, key)
    end
  end

  defp callback!({m, f, a} = mfa, _key) when is_atom(m) and is_atom(f) and is_list(a), do: mfa

  defp callback!(fun, key) when is_function(fun) do
    raise ArgumentError,
          "#{inspect(key)} must be an MFA tuple {module, function, extra_args}, not a fun: " <>
            "session options are persisted, and a closure cannot be"
  end

  defp callback!(other, key) do
    raise ArgumentError,
          "#{inspect(key)} must be an MFA tuple {module, function, extra_args}, got: #{inspect(other)}"
  end

  defp hooks!(opts) do
    opts
    |> ClaudeCode.hook_callbacks()
    |> Map.new(fn {id, callback} -> {id, callback!(callback, :hooks)} end)
  end

  defp sdk_servers!(opts) do
    case Keyword.get(opts, :sdk_mcp_servers) do
      nil ->
        %{}

      servers when is_map(servers) ->
        Enum.each(servers, fn
          {_name, %SdkMcp{}} ->
            :ok

          {name, other} ->
            raise ArgumentError,
                  ":sdk_mcp_servers #{inspect(name)} must be a CrowdControl.SdkMcp.tool_server/2 " <>
                    "spec, got: #{inspect(other)}"
        end)

        servers

      other ->
        raise ArgumentError, ":sdk_mcp_servers must be a map, got: #{inspect(other)}"
    end
  end

  defp permission_timeout!(opts) do
    case Keyword.get(opts, :permission_timeout) do
      nil ->
        :infinity

      :infinity ->
        :infinity

      ms when is_integer(ms) and ms > 0 ->
        ms

      other ->
        raise ArgumentError,
              ":permission_timeout must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  # Only an agent that can stop a turn without dying gets a grace period; for
  # the rest a deadline destroys at once, as it always has. The 30 s default
  # applies to sessions that use control features, so a plain Claude session's
  # deadline is unchanged unless it asks for a grace explicitly.
  defp interrupt_grace!(opts, features, interruptible) do
    case Keyword.get(opts, :interrupt_grace) do
      nil when features and interruptible ->
        @default_interrupt_grace

      nil ->
        0

      ms when is_integer(ms) and ms >= 0 ->
        if interruptible, do: ms, else: 0

      other ->
        raise ArgumentError,
              ":interrupt_grace must be a non-negative integer, got: #{inspect(other)}"
    end
  end

  # --- pending requests ---

  @doc "The pending entry carrying `request_id`, as `{key, entry}`, or nil."
  @spec find(t(), String.t()) :: {key(), entry()} | nil
  def find(%__MODULE__{pending: pending}, request_id) do
    Enum.find(pending, fn {{id, _offset}, _entry} -> id == request_id end)
  end

  @doc "Pending entries in the order their lines arrived; recovered ones last."
  @spec ordered(t()) :: [{key(), entry()}]
  def ordered(%__MODULE__{pending: pending}),
    do: Enum.sort_by(pending, fn {{_id, offset}, _entry} -> offset end)

  @doc "Received entries ready to dispatch. Permission requests wait out a reconcile."
  @spec dispatchable(t()) :: [{key(), entry()}]
  def dispatchable(%__MODULE__{} = control) do
    for {_key, %{status: :received} = entry} = pair <- ordered(control),
        not (control.reconciling and entry.subtype == "can_use_tool"),
        do: pair
  end

  @spec dispatchable?(t()) :: boolean()
  def dispatchable?(%__MODULE__{pending: pending}) when map_size(pending) == 0, do: false
  def dispatchable?(%__MODULE__{} = control), do: dispatchable(control) != []

  @doc """
  Whether a human may be holding the turn: any permission request, or a hook
  callback that was deferred. The turn timer is paused while this is true.
  """
  @spec blocked?(t()) :: boolean()
  def blocked?(%__MODULE__{pending: pending}) when map_size(pending) == 0, do: false

  def blocked?(%__MODULE__{pending: pending}),
    do: Enum.any?(pending, fn {_k, e} -> blocking?(e) end)

  defp blocking?(%{subtype: "can_use_tool"}), do: true
  defp blocking?(%{subtype: "hook_callback", status: :deferred}), do: true
  defp blocking?(_entry), do: false

  @doc "Pending requests as the public `Session.pending_requests/1` shape."
  @spec list(t()) :: [map()]
  def list(%__MODULE__{} = control) do
    for {{id, _offset}, entry} <- ordered(control) do
      %{request_id: id, subtype: entry.subtype, request: entry.request, status: entry.status}
    end
  end

  @doc "Mints a host-side request id, `req_<n>_<hex>`."
  @spec next_request_id(t()) :: {String.t(), t()}
  def next_request_id(%__MODULE__{seq: seq} = control) do
    hex = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    {"req_#{seq + 1}_#{hex}", %{control | seq: seq + 1}}
  end

  # --- decisions ---

  @doc "Calls an MFA callback with the request and its context."
  @spec call(callback(), map(), map()) :: term()
  def call({m, f, a}, request, context), do: apply(m, f, [request, context | a])

  @doc """
  Turns a callback's (or `respond/3`'s) decision into a reply for `entry`:
  a permission decision for `can_use_tool`, `{:ok, map} | {:error, binary}` for
  every other subtype. `:defer` and anything malformed come back as atoms.
  """
  @spec reply(entry(), term()) :: reply() | :defer | :invalid
  def reply(_entry, :defer), do: :defer

  def reply(%{subtype: "can_use_tool"}, decision),
    do: if(permission_decision?(decision), do: {:permission, decision}, else: :invalid)

  def reply(_entry, {:ok, response} = result) when is_map(response), do: {:response, result}
  def reply(_entry, {:error, message} = result) when is_binary(message), do: {:response, result}
  def reply(_entry, _other), do: :invalid

  defp permission_decision?({:allow, input}) when is_map(input), do: true

  defp permission_decision?({:allow, input, permissions})
       when is_map(input) and is_list(permissions),
       do: true

  defp permission_decision?({:deny, message}) when is_binary(message), do: true

  defp permission_decision?({:deny, message, opts}) when is_binary(message) and is_list(opts),
    do: Keyword.keyword?(opts)

  defp permission_decision?(_other), do: false

  @doc """
  The reply when no callback produced a usable answer, so the CLI is never left
  waiting: a deny for a permission request, a JSON-RPC `-32603` for an MCP
  message, an error response for anything else.
  """
  @spec failure(entry(), String.t()) :: reply()
  def failure(%{subtype: "can_use_tool"}, message), do: {:permission, {:deny, message}}

  def failure(%{subtype: "mcp_message", request: request}, message),
    do: mcp_reply(SdkMcp.error_response(jsonrpc_id(request), -32_603, message))

  def failure(_entry, message), do: {:response, {:error, message}}

  @doc "Wraps a JSON-RPC message as the answer to an `mcp_message` request."
  @spec mcp_reply(SdkMcp.jsonrpc()) :: reply()
  def mcp_reply(jsonrpc), do: {:response, {:ok, %{"mcp_response" => jsonrpc}}}

  @doc "The JSON-RPC id of an `mcp_message` request's message, or nil."
  @spec jsonrpc_id(map()) :: term()
  def jsonrpc_id(%{"message" => %{"id" => id}}), do: id
  def jsonrpc_id(_request), do: nil

  @doc "The `behavior` reported by the decision telemetry event."
  @spec behavior(reply() | :cancel) :: :allow | :deny | :error | :cancelled
  def behavior({:permission, {:allow, _input}}), do: :allow
  def behavior({:permission, {:allow, _input, _permissions}}), do: :allow
  def behavior({:permission, _deny}), do: :deny
  def behavior({:response, {:error, _message}}), do: :error
  def behavior({:response, {:ok, _response}}), do: :allow
  def behavior(:cancel), do: :cancelled

  # --- persistence ---

  @doc """
  The part of the state `CrowdControl.Store` keeps: pending entries (no task
  refs) and the turn deadline as wall-clock milliseconds or a paused remainder.
  """
  @spec to_store(t()) :: map()
  def to_store(%__MODULE__{} = control) do
    %{
      pending: control.pending,
      turn_deadline_at: control.turn_deadline_at,
      paused_remaining_ms: control.paused_remaining_ms
    }
  end

  @doc """
  Restores persisted state. An entry that was mid-callback is `:received`
  again: its task died with the old session, so it has to run again. A deferred
  entry stays deferred; subscribers see it again on `subscribe/1`.
  """
  @spec restore(t(), map() | nil) :: t()
  def restore(%__MODULE__{} = control, %{pending: pending} = stored) when is_map(pending) do
    pending =
      Map.new(pending, fn
        {key, %{status: :deferred} = entry} -> {key, entry}
        {key, entry} -> {key, %{entry | status: :received}}
      end)

    %{
      control
      | pending: pending,
        turn_deadline_at: Map.get(stored, :turn_deadline_at),
        paused_remaining_ms: Map.get(stored, :paused_remaining_ms)
    }
  end

  def restore(%__MODULE__{} = control, _absent), do: control
end
