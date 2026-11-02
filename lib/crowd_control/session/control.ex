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
  @default_max_pending 64

  @typedoc "An MFA callback: called as `apply(m, f, [request, context | extra])`."
  @type callback :: {module(), atom(), list()}

  @type status :: :received | :dispatched | :deferred
  @type key :: {String.t(), non_neg_integer() | nil}
  @typedoc """
  `approved` marks an MCP `tools/call` that passed the gate, so a re-dispatch
  after reattach does not need the approval it already consumed.
  """
  @type entry :: %{
          required(:subtype) => String.t(),
          required(:request) => map(),
          required(:status) => status(),
          optional(:approved) => true
        }

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
          max_pending: pos_integer(),
          cap_logged_turn: non_neg_integer() | nil,
          allowed_tools: [String.t()],
          permission_mode: String.t() | nil,
          granted_tools: MapSet.t(String.t()),
          approvals: [{String.t(), map()}],
          outbound: %{
            String.t() => %{from: term(), timer: reference() | nil, mode: String.t() | nil}
          },
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
            max_pending: @default_max_pending,
            cap_logged_turn: nil,
            allowed_tools: [],
            permission_mode: nil,
            granted_tools: MapSet.new(),
            approvals: [],
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
      interrupt_grace: interrupt_grace!(opts, features, Agent.capable?(agent, :interrupt)),
      max_pending: max_pending!(opts),
      allowed_tools: allowed_tools(opts),
      permission_mode: permission_mode(opts)
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

  defp callback!({m, f, a} = mfa, key) when is_atom(m) and is_atom(f) and is_list(a) do
    check_extra_args!(a, inspect(key))
    mfa
  end

  defp callback!(fun, key) when is_function(fun) do
    raise ArgumentError,
          "#{inspect(key)} must be an MFA tuple {module, function, extra_args}, not a fun: " <>
            "session options are persisted, and a closure cannot be"
  end

  defp callback!(other, key) do
    raise ArgumentError,
          "#{inspect(key)} must be an MFA tuple {module, function, extra_args}, got: #{inspect(other)}"
  end

  @doc """
  Raises `ArgumentError` when an MFA's `extra_args` hold a fun, pid,
  reference or port, at any depth. Session options are persisted to
  CrowdControl.Store, and none of those survive a restart -- a closure can also
  capture a secret. `label` names the option in the message.
  """
  @spec check_extra_args!(list(), String.t()) :: :ok
  def check_extra_args!(args, label) when is_list(args) do
    case unpersistable(args) do
      nil ->
        :ok

      bad ->
        raise ArgumentError,
              "#{label} extra_args must be plain data: they are persisted to " <>
                "CrowdControl.Store, and #{inspect(bad)} cannot be"
    end
  end

  defp unpersistable(term)
       when is_function(term) or is_pid(term) or is_reference(term) or is_port(term),
       do: term

  defp unpersistable([head | tail]), do: unpersistable(head) || unpersistable(tail)
  defp unpersistable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> unpersistable()
  defp unpersistable(map) when is_map(map), do: map |> Map.to_list() |> unpersistable()
  defp unpersistable(_plain), do: nil

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
        Enum.each(servers, &sdk_server!/1)
        servers

      other ->
        raise ArgumentError, ":sdk_mcp_servers must be a map, got: #{inspect(other)}"
    end
  end

  defp sdk_server!({name, %SdkMcp{tools: tools}}) do
    Enum.each(tools, fn %{name: tool, call: {_m, _f, args}} ->
      check_extra_args!(args, "sdk_mcp_servers #{inspect(name)} tool #{inspect(tool)} :call")
    end)
  end

  defp sdk_server!({name, other}) do
    raise ArgumentError,
          ":sdk_mcp_servers #{inspect(name)} must be a CrowdControl.SdkMcp.tool_server/2 " <>
            "spec, got: #{inspect(other)}"
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

  defp max_pending!(opts) do
    case Keyword.get(opts, :max_pending_control) do
      nil ->
        @default_max_pending

      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              ":max_pending_control must be a positive integer, got: #{inspect(other)}"
    end
  end

  # `--allowedTools` and `--permission-mode` are CLI options; malformed values
  # are the CLI's to refuse, so here they only fail to pre-approve anything.
  defp allowed_tools(opts) do
    case Keyword.get(opts, :allowed_tools) do
      tools when is_list(tools) -> Enum.filter(tools, &is_binary/1)
      _absent -> []
    end
  end

  defp permission_mode(opts) do
    case Keyword.get(opts, :permission_mode) do
      mode when is_binary(mode) -> mode
      _absent -> nil
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

  # --- the SDK MCP tool gate ---
  #
  # Control requests arrive on a stream the sandbox can write to, so a forged
  # `mcp_message` could otherwise run a host-side tool the CLI never approved.
  # With `:can_use_tool` configured, a `tools/call` runs only when the CLI
  # would have let the model make it: the tool is pre-approved (the CLI never
  # asks about it), or a permission request for it was allowed this turn and
  # the call carries exactly the input that allow sent back.

  @doc """
  Whether an MCP `tools/call` for `server` may run. Returns the control state
  with any one-shot approval consumed and the entry marked approved, or
  `{:refused, tool_name}`. A session without `:can_use_tool` is not gated.
  """
  @spec gate(t(), entry(), String.t(), SdkMcp.jsonrpc()) ::
          {:ok, t(), entry()} | {:refused, String.t()}
  def gate(%__MODULE__{can_use_tool: nil} = control, entry, _server, _message),
    do: {:ok, control, entry}

  def gate(%__MODULE__{} = control, %{approved: true} = entry, _server, _message),
    do: {:ok, control, entry}

  def gate(%__MODULE__{} = control, entry, server, message) do
    case SdkMcp.tool_call(message) do
      # No tool name: SdkMcp answers with an error and runs nothing.
      {nil, _arguments} ->
        {:ok, control, entry}

      {tool, arguments} ->
        name = "mcp__#{server}__#{tool}"
        approval = {name, arguments}

        cond do
          pre_approved?(control, server, name) ->
            {:ok, control, Map.put(entry, :approved, true)}

          approval in control.approvals ->
            control = %{control | approvals: List.delete(control.approvals, approval)}
            {:ok, control, Map.put(entry, :approved, true)}

          true ->
            {:refused, name}
        end
    end
  end

  defp pre_approved?(control, server, name) do
    control.permission_mode == "bypassPermissions" or
      Enum.any?(control.allowed_tools, &covers?(&1, server, name)) or
      Enum.any?(control.granted_tools, &covers?(&1, server, name))
  end

  # The forms Claude Code accepts for an MCP tool in an allow rule: the tool's
  # full name, or the whole server.
  defp covers?(rule, server, name),
    do: rule == name or rule == "mcp__" <> server or rule == "mcp__" <> server <> "__*"

  @doc """
  Records what a written answer means for the gate: an allow for an MCP tool
  is a one-shot approval of that exact input, and its permission updates may
  grant allow rules (`addRules`) or switch the mode (`setMode`) for the rest of
  the session.
  """
  @spec answered(t(), entry(), reply()) :: t()
  def answered(control, %{subtype: "can_use_tool", request: request}, {:permission, decision}) do
    case decision do
      {:allow, input} -> approve(control, request, input)
      {:allow, input, updates} -> control |> approve(request, input) |> apply_updates(updates)
      _deny -> control
    end
  end

  def answered(control, _entry, _reply), do: control

  defp approve(control, %{"tool_name" => "mcp__" <> _ = name}, input),
    do: %{control | approvals: [{name, input} | control.approvals]}

  defp approve(control, _request, _input), do: control

  # Permission updates are the caller's own data and may use atom keys, which
  # encode to the same JSON; anything unrecognised grants nothing.
  defp apply_updates(control, updates) do
    Enum.reduce(updates, control, fn
      update, acc when is_map(update) -> apply_update(acc, update)
      _other, acc -> acc
    end)
  end

  defp apply_update(control, update) do
    case {field(update, "type", :type), field(update, "behavior", :behavior)} do
      {"addRules", "allow"} ->
        %{control | granted_tools: Enum.reduce(rules(update), control.granted_tools, &grant/2)}

      {"setMode", _behavior} ->
        set_mode(control, field(update, "mode", :mode))

      _other ->
        control
    end
  end

  defp rules(update) do
    case field(update, "rules", :rules) do
      rules when is_list(rules) -> rules
      _other -> []
    end
  end

  # A rule with content (`Bash(git:*)`) allows only matching calls, so the CLI
  # still asks about the rest; only a bare tool rule pre-approves the tool.
  defp grant(rule, granted) when is_map(rule) do
    case {field(rule, "toolName", :toolName), field(rule, "ruleContent", :ruleContent)} do
      {name, nil} when is_binary(name) -> MapSet.put(granted, name)
      _other -> granted
    end
  end

  defp grant(_rule, granted), do: granted

  defp field(map, name, atom), do: Map.get(map, name, Map.get(map, atom))

  @doc "The CLI's permission mode changed (`setMode`, or an acknowledged `set_permission_mode`)."
  @spec set_mode(t(), term()) :: t()
  def set_mode(control, mode) when is_binary(mode), do: %{control | permission_mode: mode}
  def set_mode(control, _mode), do: control

  @doc "One-shot approvals last until the turn's result."
  @spec end_turn(t()) :: t()
  def end_turn(%__MODULE__{approvals: []} = control), do: control
  def end_turn(%__MODULE__{} = control), do: %{control | approvals: []}

  # --- persistence ---

  @doc """
  The part of the state `CrowdControl.Store` keeps: pending entries (no task
  refs), the turn deadline as wall-clock milliseconds or a paused remainder,
  and what the gate has learnt this session, which the CLI still honours after
  a host restart.
  """
  @spec to_store(t()) :: map()
  def to_store(%__MODULE__{} = control) do
    %{
      pending: control.pending,
      turn_deadline_at: control.turn_deadline_at,
      paused_remaining_ms: control.paused_remaining_ms,
      gate: %{
        permission_mode: control.permission_mode,
        granted_tools: control.granted_tools,
        approvals: control.approvals
      }
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
    |> restore_gate(Map.get(stored, :gate))
  end

  def restore(%__MODULE__{} = control, _absent), do: control

  defp restore_gate(control, %{} = gate) do
    %{
      control
      | permission_mode: Map.get(gate, :permission_mode, control.permission_mode),
        granted_tools: Map.get(gate, :granted_tools, control.granted_tools),
        approvals: Map.get(gate, :approvals, control.approvals)
    }
  end

  defp restore_gate(control, _absent), do: control
end
