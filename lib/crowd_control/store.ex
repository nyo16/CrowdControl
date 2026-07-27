defmodule CrowdControl.Store do
  @moduledoc """
  Behaviour for persisting enough session state to reattach after a restart.

  A remote sandbox outlives the `CrowdControl.Session` that created it. When the
  VM restarts, the only way to find those sandboxes again — and to resume
  reading their output without losing or duplicating a byte — is a record
  written before the crash. That is what a store holds.

  Two implementations ship, neither adding a dependency:

    * `CrowdControl.Store.ETS` — in-memory, the default. Survives a session
      crash but not a node restart.
    * `CrowdControl.Store.DETS` — disk-backed, survives a node restart.

  Callers wanting cross-node durability implement this behaviour over Ecto,
  Redis, or anything else; it is four functions.

  ## Configuration

      config :crowd_control, :store, CrowdControl.Store.ETS

      config :crowd_control, :store, {CrowdControl.Store.DETS, path: "/var/lib/cc/sessions.dets"}

  ## What is stored, and what deliberately is not

  See `t:record/0`. The cursor halves — `:byte_offset` and `:buffer` — are the
  point of the whole thing: `byte_offset` says where to resume reading the
  sandbox's output file, and `:buffer` carries the partial line that was
  in-flight when the session died. Reattaching seeds the buffer and reads from
  the offset, so a line split across the failure is rejoined exactly.

  **Not** stored:

    * `messages` / `message_count` — already a lossy window capped by
      `:max_messages`, and rebuildable by replaying the sandbox's output from
      offset 0 if a caller ever needs it
    * `subscribers` — pids, meaningless after a restart; callers re-`subscribe/1`
    * `timeout_ref`, `reader` — process-local, rebuilt on reattach

  ## Only reattachable backends write

  `CrowdControl.Backend.Local` cannot reattach — a local subprocess dies with
  the VM — so a store write per stdout chunk would be pure overhead. `Session`
  checks `CrowdControl.Backend.reattachable?/1` and skips persistence entirely
  for such backends.

  ## Two different ids

  Records are keyed by the **CrowdControl session key** — a random id minted by
  `CrowdControl.Session` at startup, before the sandbox is provisioned, and
  stamped onto the sandbox as the `crowd_control.session` label. That label is
  what lets `CrowdControl.Reaper` match a running container back to its record.

  The CLI's *own* session id (`:session_id`) is a different thing: it does not
  exist until the CLI emits `system/init`, and it is only useful for `--resume`.
  Keying on it would leave every session unfindable for the first few hundred
  milliseconds of its life — precisely the window in which a crash strands a
  container nobody can reap.
  """

  @typedoc """
  A persisted session.

    * `:key` — the CrowdControl session key; the store key and sandbox label
    * `:session_id` — the **CLI's** own session id, used for `--resume`. `nil`
      until the CLI emits `system/init`.
    * `:backend` — the backend module, so the reaper knows who owns the handle
    * `:handle` — backend-opaque; must survive `:erlang.term_to_binary/1`
    * `:byte_offset` — bytes of sandbox output already delivered to the session
    * `:buffer` — partial line in flight at the last write
    * `:opts` — the session opts, replayed on reattach
    * `:owner` — this node's owner id; scopes reaping (see `CrowdControl.Reaper`)
    * `:updated_at` — `System.system_time(:millisecond)`
  """
  @type t :: %{
          required(:key) => String.t(),
          required(:session_id) => String.t() | nil,
          required(:backend) => module(),
          required(:handle) => term(),
          required(:byte_offset) => non_neg_integer(),
          required(:buffer) => binary(),
          required(:opts) => keyword(),
          required(:owner) => String.t(),
          required(:updated_at) => integer(),
          optional(atom()) => term()
        }

  @doc "Insert or replace the record for `key`."
  @callback put(key :: String.t(), t()) :: :ok

  @doc "Fetch a record, or `:error` if absent."
  @callback get(key :: String.t()) :: {:ok, t()} | :error

  @doc "Remove a record. Absent is success."
  @callback delete(key :: String.t()) :: :ok

  @doc "Every record currently held."
  @callback all() :: [t()]

  @default_store CrowdControl.Store.ETS

  @doc """
  The configured store as `{module, opts}`.

  Accepts a bare module or a `{module, opts}` tuple, mirroring
  `CrowdControl.Backend.resolve/1`.
  """
  @spec resolve() :: {module(), keyword()}
  def resolve do
    case Application.get_env(:crowd_control, :store, @default_store) do
      {module, opts} when is_atom(module) and is_list(opts) ->
        {module, opts}

      module when is_atom(module) and not is_nil(module) ->
        {module, []}

      other ->
        raise ArgumentError,
              "config :crowd_control, :store must be a module or {module, keyword}, " <>
                "got: #{inspect(other)}"
    end
  end

  @doc "The configured store module."
  @spec impl() :: module()
  def impl, do: resolve() |> elem(0)

  @doc """
  This node's owner id.

  Every sandbox is labelled with it, and `CrowdControl.Reaper` only ever
  destroys sandboxes carrying its own. Two nodes with independent stores
  therefore cannot reap each other's work. Defaults to `to_string(node())`.

      config :crowd_control, :owner_id, "prod-worker-1"
  """
  @spec owner_id() :: String.t()
  def owner_id do
    case Application.get_env(:crowd_control, :owner_id) do
      nil -> to_string(node())
      id when is_binary(id) -> id
      other -> raise ArgumentError, ":owner_id must be a binary, got: #{inspect(other)}"
    end
  end

  @doc """
  Build a record from session state.

  Stamps `:owner` and `:updated_at` so callers cannot forget them.
  """
  @spec build(keyword()) :: t()
  def build(fields) do
    %{
      key: Keyword.fetch!(fields, :key),
      session_id: Keyword.get(fields, :session_id),
      backend: Keyword.fetch!(fields, :backend),
      handle: Keyword.fetch!(fields, :handle),
      byte_offset: Keyword.get(fields, :byte_offset, 0),
      buffer: Keyword.get(fields, :buffer, ""),
      opts: Keyword.get(fields, :opts, []),
      owner: Keyword.get(fields, :owner) || owner_id(),
      updated_at: Keyword.get(fields, :updated_at) || System.system_time(:millisecond)
    }
  end

  # --- Convenience dispatch to the configured store ---

  @doc "Write via the configured store."
  @spec put(String.t(), t()) :: :ok
  def put(key, record), do: impl().put(key, record)

  @doc "Read via the configured store."
  @spec get(String.t()) :: {:ok, t()} | :error
  def get(key), do: impl().get(key)

  @doc "Delete via the configured store."
  @spec delete(String.t()) :: :ok
  def delete(key), do: impl().delete(key)

  @doc """
  Credential-bearing option keys, stripped before anything is persisted.
  """
  @spec secret_keys() :: [atom()]
  def secret_keys, do: [:api_key, :session_token, :env, :proxy_token, :auth_token]

  @doc """
  Remove credentials from an options keyword list.

  Store records outlive the process that wrote them, and with
  `CrowdControl.Store.DETS` they outlive the VM on disk. Nothing about
  reattaching a session needs its API key — the sandbox already holds whatever
  environment it was started with — so the key has no business being written
  down.

      iex> CrowdControl.Store.scrub_opts(api_key: "sk-real", timeout: 5000)
      [timeout: 5000]
  """
  @spec scrub_opts(keyword()) :: keyword()
  def scrub_opts(opts) when is_list(opts), do: Keyword.drop(opts, secret_keys())
  def scrub_opts(other), do: other

  @doc """
  Mint a new session key.

  Hex so it is safe as a container label value and a filename component.
  """
  @spec new_key() :: String.t()
  def new_key, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc "List via the configured store."
  @spec all() :: [t()]
  def all, do: impl().all()
end
