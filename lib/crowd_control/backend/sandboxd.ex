defmodule CrowdControl.Backend.Sandboxd do
  @moduledoc """
  Drives a CLI through the `sandboxd` agent over HTTP, on any substrate.

  Requires the optional `:req` dependency and a `CrowdControl.Provider`:

      CrowdControl.run("hello",
        backend:
          {CrowdControl.Backend.Sandboxd,
           provider: {CrowdControl.Provider.Docker, image: "crowd_control/sandbox:dev", egress: :allow}}
      )

  ## Why this exists next to `CrowdControl.Backend.Docker`

  `Backend.Docker` is a *transport* bolted to a *substrate*: it knows both how
  to create a container and how to move bytes through a FIFO and a `tee` file.
  `Backend.Kubernetes` had to reimplement the second half for pods. A VM has no
  exec API at all, so a third substrate meant a third transport.

  This backend splits those apart. Bytes always move the same way — one HTTP
  protocol to one agent — and `CrowdControl.Provider` owns the substrate. A new
  substrate is provisioning code and nothing else.

  `Backend.Docker` is not deprecated and is not going anywhere. It works with
  any image that has `sh` and `tail`; this one needs an image containing our
  agent. Which trade you want is yours to make.

  ## Callback mapping

  | Callback | Implementation |
  |---|---|
  | `provision/1` | `c:CrowdControl.Provider.acquire/1`, which returns only once `GET /v1/health` answers |
  | `exec/4` | `c:CrowdControl.Agent.sandbox_files/1` via `PUT /v1/files`, then `POST /v1/exec` with env in the JSON **body** |
  | `start_reader/3` | `GET /v1/stream?offset=N` with `Req` `into: :self` — plain bytes, no demux |
  | `write/2` | `POST /v1/stdin` `{data: base64}` |
  | `await_exit/2` | `GET /v1/status?wait_ms=…`, long-polled server-side |
  | `alive?/1` | `GET /v1/health` |
  | `destroy/1` | `c:CrowdControl.Provider.release/1`, idempotent |
  | `list_live/1` | `c:CrowdControl.Provider.list_live/1`, so `CrowdControl.Reaper` needs no change |
  | `reattach/2` | `c:CrowdControl.Provider.reconnect/1`, then `start_reader/3` at the persisted offset |
  | `scrub/1` | drop the endpoint, scrub the config, then `c:CrowdControl.Provider.scrub/1` |

  ## Agent configuration files land here before the CLI starts

  A CLI that reads configuration from disk cannot be configured by argv or by
  environment alone: `CrowdControl.Agent.Omp` resolves a custom provider's
  `baseUrl` out of `models.yml`, and on a remote substrate a host temp
  directory is not visible to it. `exec/4` asks the resolved
  `CrowdControl.Agent` adapter for its `c:CrowdControl.Agent.sandbox_files/1`
  and `PUT`s each one before the `POST /v1/exec`, so the file is there when the
  CLI opens it. See `push_file/4`.

  ## Live and resume are the same code path

  `start_reader/3` at offset 0 *is* the resume path. The agent's capture file is
  byte-for-byte the same artifact as `Backend.Docker`'s `tee` file, so the
  cursor stays `%{byte_offset:, buffer:}` and a line split across a crash
  rejoins byte-exactly. Offsets are 0-indexed here; `tail -c +N` is 1-indexed,
  and that `+ 1` is a documented hazard this transport simply does not have.

  ## The stream ending is not end-of-output

  `/v1/stream` ends either because the CLI is finished or because nothing new
  arrived within the agent's idle window. Those cannot be distinguished in-band
  without injecting a keepalive byte into a stream whose offsets are
  load-bearing, so the reader asks `GET /v1/status`: still alive, or more bytes
  than it has consumed, means re-request from the current offset. Otherwise it
  is EOF.

  ## Backpressure

  Identical in shape to `Backend.Docker`'s, because the underlying problem is
  identical: `Req into: :self` gives no backpressure, chunks pile into the
  reader's mailbox whether or not `CrowdControl.Session` keeps up, and `Req`
  has no pause primitive. It has cancellation, and this read is resumable by
  construction, so "pause" is cancel and "resume" is re-requesting from the
  offset already delivered. No new mechanism, and nothing is lost or duplicated
  because the offset is exact.

  ## Nothing secret is persisted

  The handle goes into `CrowdControl.Store`. The endpoint does not: it holds a
  derived token, a base URL whose port is reassigned on every reconnect, and
  possibly a live tunnel. `scrub/1` drops it wholesale and the token is
  re-derived from the persisted `session_key` on reattach. Rotating
  `:sandboxd_secret` therefore fails reattach closed with
  `{:sandboxd, :unauthorized}`, which is the intended trade against a live
  credential at rest.
  """

  @behaviour CrowdControl.Backend

  @compile {:no_warn_undefined, Req}

  require Logger

  alias CrowdControl.Agent
  alias CrowdControl.Backend.Sandboxd.API
  alias CrowdControl.Provider
  alias CrowdControl.Store

  @default_max_inflight 4 * 1024 * 1024
  @status_wait_ms 25_000

  defstruct [
    :provider,
    :provider_handle,
    :endpoint,
    :session_key,
    :owner,
    config: []
  ]

  @type t :: %__MODULE__{
          provider: module() | nil,
          provider_handle: term(),
          endpoint: CrowdControl.Provider.Endpoint.t() | nil,
          session_key: String.t() | nil,
          owner: String.t() | nil,
          config: keyword()
        }

  @doc false
  @spec reattachable?() :: true
  def reattachable?, do: true

  # --- provision ---

  @impl true
  def provision(opts) do
    with :ok <- ensure_req!() do
      {provider, provider_opts} = Provider.resolve(opts)

      case provider.acquire(provider_opts) do
        {:ok, provider_handle, endpoint} ->
          {:ok,
           %__MODULE__{
             provider: provider,
             provider_handle: provider_handle,
             endpoint: endpoint,
             session_key: opts[:session_key],
             owner: opts[:owner] || Store.owner_id(),
             config: opts
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- exec / write ---

  @impl true
  def exec(%__MODULE__{endpoint: nil}, _executable, _args, _env),
    do: {:error, {:sandboxd, :not_provisioned}}

  def exec(%__MODULE__{} = handle, executable, args, env) do
    with :ok <- stage_agent_files(handle),
         :ok <- API.exec(handle.endpoint, executable, args, env) do
      {:ok, handle}
    end
  end

  # This is the only seam with both halves of the problem in hand: the sandbox
  # does not exist until provision/1 has returned, and the CLI must not start
  # until its configuration is on the sandbox's filesystem. Session's
  # provision -> exec -> reader sequence therefore leaves exactly one point
  # where staging can happen, and Backend.Kubernetes.exec/4 already stages its
  # env file here for the same reason.
  #
  # Errors are propagated rather than logged-and-continued on purpose: a CLI
  # launched without its config does not fail, it silently talks to the wrong
  # provider. Session's exec_or_destroy/5 turns this {:error, _} into a torn
  # down sandbox, which is the only safe outcome.
  defp stage_agent_files(handle) do
    handle.config
    |> Agent.resolve()
    |> Agent.sandbox_files(handle.config)
    |> Enum.reduce_while(:ok, fn {path, body, mode}, :ok ->
      case push_file(handle, path, body, mode) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def write(%__MODULE__{endpoint: nil}, _data), do: {:error, {:sandboxd, :not_provisioned}}
  def write(%__MODULE__{} = handle, data), do: API.write(handle.endpoint, data)

  # --- reader ---

  @impl true
  def start_reader(%__MODULE__{endpoint: nil}, _session_pid, _cursor),
    do: {:error, {:sandboxd, :not_provisioned}}

  def start_reader(%__MODULE__{} = handle, session_pid, cursor) do
    state = %{
      handle: handle,
      session: session_pid,
      offset: cursor.byte_offset,
      inflight: 0,
      max_inflight: handle.config[:max_inflight_bytes] || @default_max_inflight,
      resp: nil
    }

    # spawn_link, not spawn: the Backend reader contract requires the session to
    # die with a dead reader rather than silently going deaf.
    {:ok, spawn_link(fn -> init_reader(state) end)}
  end

  # trap_exit is a correctness requirement, not hygiene.
  #
  # `Finch.HTTP1.Pool.async_request/3` spawn_links its worker task to *this*
  # process, so an abnormal task exit would otherwise kill the reader before it
  # could cast `:eof` — measured: `exit(task, :boom)` takes the reader down with
  # reason `:boom` and the session never learns the stream ended. Link-propagated
  # `:kill` arrives as a trappable `{:EXIT, pid, :killed}`, so trapping covers
  # every case. (Cancellation is already safe: Finch unlinks before exiting.)
  #
  # Second-order consequence, which the EXIT clauses below must handle: once
  # trapping, this process no longer dies with the session it is linked to, so it
  # has to stop on the session's own exit or readers outlive their sessions.
  defp init_reader(state) do
    Process.flag(:trap_exit, true)
    reader_loop(state)
  end

  defp reader_loop(state) do
    case API.stream(state.handle.endpoint, state.offset) do
      {:ok, resp} -> consume(%{state | resp: resp})
      {:error, reason} -> fail(state, reason)
    end
  end

  defp consume(state) do
    receive do
      {:cc_ack, bytes} ->
        state |> ack(bytes) |> consume()

      {:EXIT, pid, reason} ->
        on_exit_signal(state, pid, reason, &consume/1)

      message ->
        case Req.parse_message(state.resp, message) do
          {:ok, parts} ->
            handle_parts(state, parts)

          # A mid-stream transport failure. Without this clause a CaseClauseError
          # would kill this spawn_linked reader and take the session with it —
          # the "session left hanging" the reader contract exists to prevent.
          {:error, reason} ->
            fail(state, API.stream_error(reason))

          # Load-bearing, not defensive. A chunk already dispatched by a task
          # being cancelled can land after Req has drained the mailbox, carrying
          # the *previous* response ref. Measured at ~0.03% of cancels, rising as
          # chunks get smaller. Counting it as data would duplicate those bytes;
          # crashing on it would drop the stream. Dropping it is correct, because
          # the resumed request re-sends exactly those bytes.
          :unknown ->
            consume(state)
        end
    end
  end

  # The session going away is not a failure and needs no :eof — there is nobody
  # left to tell. Anything else exiting abnormally is the Finch task dying, which
  # is a transport failure and must produce exactly one :eof.
  defp on_exit_signal(state, pid, reason, continue) do
    cond do
      pid == state.session -> :ok
      reason == :normal -> continue.(state)
      true -> fail(state, {:stream_task_exit, reason})
    end
  end

  defp handle_parts(state, parts) do
    state = Enum.reduce(parts, state, &apply_part/2)

    cond do
      :done in parts -> on_stream_end(state)
      state.inflight >= state.max_inflight -> pause(state)
      true -> consume(state)
    end
  end

  defp apply_part({:data, data}, state), do: deliver(state, data)
  defp apply_part(:done, state), do: state

  defp apply_part(other, state) do
    # Anything Req grows a new part shape for should be visible rather than
    # silently dropped: a swallowed error part looks exactly like a stalled
    # stream.
    Logger.debug("sandboxd reader ignoring unrecognized stream part: #{inspect(other)}")
    state
  end

  defp deliver(state, data) do
    GenServer.cast(state.session, {:stdout_data, data})

    delivered = byte_size(data)
    %{state | offset: state.offset + delivered, inflight: state.inflight + delivered}
  end

  defp ack(state, bytes), do: %{state | inflight: max(state.inflight - bytes, 0)}

  # The response ended. That is not necessarily EOF — the agent also ends an
  # idle stream — so the authoritative answer comes from GET /v1/status.
  defp on_stream_end(state) do
    case API.status(state.handle.endpoint, 0) do
      {:ok, %{alive: false, bytes: bytes}} when bytes <= state.offset ->
        GenServer.cast(state.session, :eof)

      {:ok, _status} ->
        reader_loop(%{state | resp: nil})

      {:error, reason} ->
        fail(state, reason)
    end
  end

  # Over the watermark: drop the stream and wait for the session to catch up.
  defp pause(state) do
    _ = Req.cancel_async_response(state.resp)
    await_drain(%{state | resp: nil})
  end

  defp await_drain(state) do
    receive do
      {:cc_ack, bytes} ->
        state = ack(state, bytes)

        # Resume at half the watermark rather than at zero, so a busy session
        # does not thrash between cancel and re-open on every chunk.
        if state.inflight <= div(state.max_inflight, 2) do
          reader_loop(state)
        else
          await_drain(state)
        end

      {:EXIT, pid, reason} ->
        on_exit_signal(state, pid, reason, &await_drain/1)

      # An orphan chunk from the cancelled request, or a late :done from it.
      # There is no live response to parse against here, and the bytes will be
      # re-sent from `offset` when the stream reopens, so it is dropped.
      _other ->
        await_drain(state)
    end
  end

  # :eof exactly once, including on transport error, so the session is never
  # left hanging on a stream that will never produce another byte.
  defp fail(state, reason) do
    Logger.warning("sandboxd reader stopped: #{inspect(reason)}")
    GenServer.cast(state.session, :eof)
  end

  # --- lifecycle ---

  @impl true
  def await_exit(%__MODULE__{endpoint: nil}, _timeout), do: :timeout

  def await_exit(%__MODULE__{} = handle, timeout) do
    deadline = deadline_for(timeout)
    do_await_exit(handle, deadline)
  end

  defp deadline_for(:infinity), do: :infinity
  defp deadline_for(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp do_await_exit(handle, deadline) do
    # The agent's long poll is woken by the capture being finalized, which
    # happens the moment the CLI exits — so this parks rather than spins, and
    # still returns promptly.
    case API.status(handle.endpoint, wait_slice(deadline)) do
      {:ok, %{alive: false, started: true, exit_status: status}} ->
        {:ok, status}

      {:ok, _alive_or_unstarted} ->
        if expired?(deadline), do: :timeout, else: do_await_exit(handle, deadline)

      {:error, _reason} ->
        # An unreachable agent is an exited-but-unknown CLI, which the behaviour
        # spells `{:ok, nil}`. Reporting :timeout would make Session wait out
        # its full timeout on a sandbox that is already gone.
        {:ok, nil}
    end
  end

  defp wait_slice(:infinity), do: @status_wait_ms

  defp wait_slice(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    remaining |> min(@status_wait_ms) |> max(0)
  end

  defp expired?(:infinity), do: false
  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  @impl true
  def alive?(%__MODULE__{endpoint: nil}), do: false
  def alive?(%__MODULE__{} = handle), do: API.health(handle.endpoint) == :ok

  @impl true
  def destroy(%__MODULE__{provider: nil}), do: :ok

  def destroy(%__MODULE__{} = handle) do
    handle.provider.release(handle.provider_handle)
  end

  @impl true
  def list_live(opts) do
    {provider, provider_opts} = Provider.resolve(opts)
    owner = opts[:owner] || Store.owner_id()

    case provider.list_live(provider_opts) do
      {:ok, handles} ->
        {:ok, Enum.map(handles, &wrap_provider_handle(&1, provider, opts, owner))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The reaper keys orphans on handle.session_key and re-checks handle.owner, so
  # both have to be lifted out of the provider handle and onto this one.
  defp wrap_provider_handle(provider_handle, provider, opts, owner) do
    %__MODULE__{
      provider: provider,
      provider_handle: provider_handle,
      endpoint: nil,
      session_key: Map.get(provider_handle, :session_key),
      owner: Map.get(provider_handle, :owner) || owner,
      config: opts
    }
  end

  @impl true
  def reattach(%__MODULE__{provider: nil}, _cursor), do: {:error, {:sandboxd, :not_provisioned}}

  def reattach(%__MODULE__{} = handle, _cursor) do
    # The resource persisted; the path did not. reconnect/1 rebuilds the
    # endpoint — including a host port that Docker reassigns on every start —
    # and start_reader/3 then resumes at the persisted offset.
    case handle.provider.reconnect(handle.provider_handle) do
      {:ok, provider_handle, endpoint} ->
        {:ok, %{handle | provider_handle: provider_handle, endpoint: endpoint}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def scrub(%__MODULE__{} = handle) do
    %{
      handle
      | # Wholesale, not field-by-field: the endpoint is entirely ephemeral, and
        # a future field on it would otherwise leak by omission.
        endpoint: nil,
        config: Store.scrub_opts(handle.config),
        provider_handle: Provider.scrub(handle.provider, handle.provider_handle)
    }
  end

  @doc """
  Age of the sandbox in milliseconds, delegated to the provider.

  `CrowdControl.Reaper` uses this for the grace period that keeps a
  mid-provision sandbox from being reaped before its store record exists.
  """
  @spec age_ms(t()) :: non_neg_integer() | nil
  def age_ms(%__MODULE__{provider: nil}), do: nil
  def age_ms(%__MODULE__{} = handle), do: Provider.age_ms(handle.provider, handle.provider_handle)

  @doc """
  Write a file inside the sandbox.

  Exists for `CrowdControl.Agent.Omp`'s `:agent_dir` obligation: a rendered
  provider config has to land *inside* the sandbox, and on a remote substrate a
  host temp directory is not visible there. It is deliberately not
  `c:CrowdControl.Backend.push_workspace/2` — this ships one rendered file, not
  a workspace, and general workspace transfer stays out of scope.

  `exec/4` calls this for each `c:CrowdControl.Agent.sandbox_files/1` entry, so
  an adapter does not have to reach for it. It stays public because a caller
  driving this backend directly has no other way in.
  """
  @spec push_file(t(), Path.t(), iodata(), non_neg_integer()) :: :ok | {:error, term()}
  def push_file(handle, path, body, mode \\ 0o600)

  def push_file(%__MODULE__{endpoint: nil}, _path, _body, _mode),
    do: {:error, {:sandboxd, :not_provisioned}}

  def push_file(%__MODULE__{} = handle, path, body, mode) do
    API.put_file(handle.endpoint, path, body, mode)
  end

  defp ensure_req! do
    if Code.ensure_loaded?(Req) do
      :ok
    else
      raise """
      CrowdControl.Backend.Sandboxd requires the optional :req dependency.

      Add it to your deps:

          {:req, "~> 0.5"}
      """
    end
  end
end
