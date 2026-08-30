defmodule CrowdControl.Backend.Docker do
  @moduledoc """
  Runs the CLI inside a Docker container over the Engine API.

  Requires the optional `:req` dependency:

      {:req, "~> 0.5"}

  ## How I/O works, and why there is no hijacked stream

  The obvious way to drive a container's stdin/stdout is
  `POST /containers/{id}/attach`, which needs a hijacked TCP connection that
  `Req` cannot speak. This backend avoids that entirely by routing both
  directions through the filesystem:

      provision  POST /containers/create
                 entrypoint: mkfifo <fifo> && mkdir -p <teedir> && sleep infinity

      exec       POST /containers/{id}/exec  (started detached)
                 sh -c 'exec 3<> <fifo>; <cli> ... <&3 | tee <teefile>'

      write      POST /containers/{id}/exec  (started detached)
                 sh -c 'printf %s <escaped> >> <fifo>'

      read       POST /containers/{id}/exec  (started attached)
                 tail -c +<byte_offset + 1> -f <teefile>

      destroy    DELETE /containers/{id}?force=true&v=true

  Reading a file with `tail` returns a plain HTTP 200 with
  `Content-Type: application/vnd.docker.raw-stream`, which `Req` streams
  happily. No `101 Upgrade`, no raw socket handling, no `Mint.WebSocket`.

  Two details are load-bearing and were both established empirically:

    * **The FIFO is held open read-write** (`exec 3<> <fifo>`). A plain
      `< <fifo>` redirect sees EOF the moment the first writer detaches, which
      collapses the pipeline and kills the container — so the second prompt of
      every session would be lost.
    * **`tail -c +N` is 1-indexed**, hence `byte_offset + 1`. Off by one here
      duplicates a byte per resume, which corrupts the JSON line stream.

  ## Live and resume are the same code path

  `start_reader/3` is `reattach/2` at offset 0. There is no separate resume
  implementation to keep correct: reading from a persisted offset is the only
  thing that differs, and `CrowdControl.Session` re-seeds the partial-line
  buffer itself. A line split across a crash therefore rejoins byte-exactly.

  ## The tee file is capped, never rotated

  `:max_stream_bytes` destroys the sandbox when output exceeds it. Rotating the
  tee file instead would invalidate every persisted byte offset and silently
  corrupt resume — the exact failure the offset cursor exists to prevent. A hard
  cap is the correct answer for a bounded resource. Do not "fix" this later.

  ## Options

    * `:image` — container image (required)
    * `:docker_host` — default `unix:///var/run/docker.sock`
    * `:network_mode` — default `"none"`; **required** when `:proxy_url` or
      `:api_url` is set (see Isolation below)
    * `:cpus` — fractional CPU limit, e.g. `1.5`
    * `:memory` — byte limit, e.g. `512 * 1024 * 1024`
    * `:tee_path` — default `/var/log/cc/out.jsonl`
    * `:fifo_path` — default `/var/run/cc.fifo`
    * `:max_stream_bytes` — cap on total output; `nil` (default) is unbounded
    * `:max_inflight_bytes` — reader backpressure watermark, default 4 MiB
    * `:proxy_url`, `:session_token` — see the egress proxy contract in
      `SECURITY.md`

  Hardening (see Isolation):

    * `:cap_drop` — default `["ALL"]`
    * `:security_opt` — default `["no-new-privileges:true"]`
    * `:pids_limit` — default `512`
    * `:user` — e.g. `"1000:1000"`; unset means the image's own user
    * `:readonly_rootfs` — default `false`
    * `:tmpfs` — mounts used when `:readonly_rootfs` is on

  ## Isolation

  `:network_mode` defaults to `"none"` — a provisioned sandbox has no network
  at all. Reaching an egress proxy requires widening it, and that is the moment
  the isolation boundary weakens, so **the backend refuses to guess**: setting
  `:proxy_url` or `:api_url` without an explicit `:network_mode` returns
  `{:error, {:docker, :network_mode_required}}`.

  Name a network that routes only to your proxy. Never `bridge` — it grants
  general outbound access, which makes the proxy advisory rather than
  enforcing, and a sandbox can simply route around it.

  Capability hardening is **on by default** (`CapDrop: ALL`,
  `no-new-privileges`, `PidsLimit: 512`) because the code running in here is
  model-driven and untrusted, and none of the three breaks an ordinary CLI.
  Note that `:memory` and `:cpus` do not bound PIDs, so the fork-bomb ceiling
  has to be set separately — that is what `:pids_limit` is for.

  `:user` and `:readonly_rootfs` are **opt-in**, because both genuinely break
  images that expect root or write outside the tmpfs mounts. Enable them where
  your image supports it; `SECURITY.md` recommends both.

  ## Secrets never enter argv

  Environment variables are passed through the exec API's first-class `Env`
  array. They are deliberately **not** interpolated into the `sh -c` command
  string as `export KEY=...`, which would place every secret in the shell's
  argv — readable by `ps` *inside* the container (where untrusted model-driven
  code runs) and retrievable afterwards from `GET /exec/{id}/json`. This is the
  remote equivalent of `Backend.Local`'s env-file indirection, and
  `docker_test.exs` greps the container's own `ps` output to keep it honest.

  `Backend.Local`'s env-file mechanism is never used here: the exec API's
  `Env` array already solves the same problem without writing a file into the
  sandbox.
  """

  @behaviour CrowdControl.Backend

  # :req is optional, so this module must still compile without it. provision/1
  # raises a clear message at runtime when it is genuinely missing.
  @compile {:no_warn_undefined, Req}

  require Logger

  alias CrowdControl.Backend.Docker.{API, Demux, HostConfig}
  alias CrowdControl.Backend.Shell
  alias CrowdControl.Store

  @default_tee "/var/log/cc/out.jsonl"
  @default_fifo "/var/run/cc.fifo"
  @default_network "none"
  @default_max_inflight 4 * 1024 * 1024
  defstruct [
    :container_id,
    :image,
    :tee_path,
    :fifo_path,
    :session_key,
    :owner,
    config: []
  ]

  @type t :: %__MODULE__{
          container_id: String.t() | nil,
          image: String.t() | nil,
          tee_path: String.t(),
          fifo_path: String.t(),
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
    with :ok <- ensure_req!(),
         :ok <- validate_network!(opts),
         {:ok, image} <- fetch_image(opts) do
      handle = %__MODULE__{
        image: image,
        tee_path: opts[:tee_path] || @default_tee,
        fifo_path: opts[:fifo_path] || @default_fifo,
        session_key: opts[:session_key],
        owner: opts[:owner] || Store.owner_id(),
        config: opts
      }

      with {:ok, id} <- create_container(handle),
           :ok <- start_container(handle, id) do
        {:ok, %{handle | container_id: id}}
      end
    end
  end

  defp create_container(handle) do
    body =
      %{
        "Image" => handle.image,
        "Entrypoint" => ["/bin/sh", "-c", entrypoint_script(handle)],
        "Env" => [],
        "Labels" => %{
          "crowd_control.session" => to_string(handle.session_key),
          "crowd_control.owner" => handle.owner,
          "crowd_control.created_at" => to_string(System.system_time(:millisecond))
        },
        "HostConfig" => host_config(handle)
      }
      |> maybe_put("User", handle.config[:user])

    case API.request(handle.config, :post, "/containers/create", json: body) do
      {:ok, %{"Id" => id}} -> {:ok, id}
      {:ok, other} -> {:error, {:docker, {:unexpected_create_response, other}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_container(handle, id) do
    case API.request(handle.config, :post, "/containers/#{id}/start") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # Roll back the created-but-unstarted container rather than leaking it.
        _ = destroy(%{handle | container_id: id})
        {:error, reason}
    end
  end

  defp entrypoint_script(handle) do
    tee_dir = Path.dirname(handle.tee_path)

    "mkfifo -m 600 #{Shell.escape(handle.fifo_path)} && " <>
      "mkdir -p #{Shell.escape(tee_dir)} && " <>
      "sleep infinity"
  end

  # Hardening lives in Backend.Docker.HostConfig, shared verbatim with
  # Provider.Docker. Two copies of these defaults would drift, and a sandbox
  # that silently lost CapDrop: ALL is indistinguishable from one that did not.
  defp host_config(handle) do
    HostConfig.build(handle.config, network_mode: network_mode(handle.config))
  end

  # Deliberately never infers `"bridge"`. Reaching an egress proxy does require
  # widening the network, but `bridge` grants general outbound access, which
  # makes the proxy advisory rather than enforcing -- a sandbox can simply route
  # around it. Picking that silently, as a default, in exactly the scenario
  # SECURITY.md warns about, is worse than refusing to start. The caller must
  # name a network that reaches only their proxy.
  defp validate_network!(config) do
    cond do
      config[:network_mode] ->
        :ok

      config[:proxy_url] || config[:api_url] ->
        {:error, {:docker, :network_mode_required}}

      true ->
        :ok
    end
  end

  defp network_mode(config), do: config[:network_mode] || @default_network

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- exec ---

  @impl true
  def exec(%__MODULE__{container_id: id} = handle, executable, args, env) when is_binary(id) do
    command = cli_command(handle, executable, args)
    env = apply_credentials(env, handle.config)

    with {:ok, exec_id} <-
           create_exec(handle, ["/bin/sh", "-c", command], attach: false, env: env),
         :ok <- start_exec_detached(handle, exec_id) do
      {:ok, handle}
    end
  end

  def exec(%__MODULE__{}, _executable, _args, _env), do: {:error, :not_provisioned}

  # `exec 3<> fifo` holds a read-write fd open for the life of the pipeline, so
  # no writer detaching is ever observable as EOF by the CLI. Verified: the
  # plain `< fifo` form dies on the first prompt and takes the container with it.
  # Env deliberately does NOT appear here. Interpolating `export KEY=secret; ...`
  # into the command string would put every secret into the `sh` process's argv,
  # visible to `ps` inside the container and readable back out of
  # `GET /exec/{id}/json`. The exec API takes a first-class `Env` array instead
  # (see create_exec/3), which is the remote equivalent of Backend.Local's
  # env-file indirection. docker_test.exs greps the container's `ps` output to
  # keep this honest.
  defp cli_command(handle, executable, args) do
    argv = Enum.map_join([executable | args], " ", &Shell.escape/1)

    "exec 3<> #{Shell.escape(handle.fifo_path)}; " <>
      "#{argv} <&3 | tee #{Shell.escape(handle.tee_path)}"
  end

  @doc """
  Rewrite the CLI's credential env for egress-proxy mode.

  Delegates to `CrowdControl.Backend.Credentials.apply_credentials/2`, which
  `Backend.Kubernetes` shares — see that module for why there is exactly one
  implementation. Kept here as part of the Docker backend's public API.
  """
  @spec apply_credentials(map(), keyword()) :: map()
  defdelegate apply_credentials(env, config), to: CrowdControl.Backend.Credentials

  defp create_exec(handle, cmd, opts) do
    attach = Keyword.get(opts, :attach, true)

    body =
      %{
        "AttachStdout" => attach,
        "AttachStderr" => false,
        "AttachStdin" => false,
        "Tty" => false,
        "Cmd" => cmd
      }
      |> put_env(Keyword.get(opts, :env, %{}))

    case API.request(handle.config, :post, "/containers/#{handle.container_id}/exec", json: body) do
      {:ok, %{"Id" => id}} -> {:ok, id}
      {:ok, other} -> {:error, {:docker, {:unexpected_exec_response, other}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_env(body, env) when map_size(env) == 0, do: body

  defp put_env(body, env) do
    Map.put(body, "Env", Enum.map(env, fn {k, v} -> "#{k}=#{v}" end))
  end

  defp start_exec_detached(handle, exec_id) do
    case API.request(handle.config, :post, "/exec/#{exec_id}/start",
           json: %{"Detach" => true, "Tty" => false}
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- write ---

  @impl true
  def write(%__MODULE__{container_id: id} = handle, data) when is_binary(id) do
    payload = IO.iodata_to_binary(data)

    # The prompt is attacker-influenced input crossing an `sh -c` boundary.
    # Shell.escape/1 is the same escaper Backend.Local uses for env values and
    # the one security_test.exs is the oracle for -- deliberately not a second
    # implementation.
    command = "printf %s #{Shell.escape(payload)} >> #{Shell.escape(handle.fifo_path)}"

    with {:ok, exec_id} <- create_exec(handle, ["/bin/sh", "-c", command], attach: false) do
      start_exec_detached(handle, exec_id)
    end
  end

  def write(%__MODULE__{}, _data), do: {:error, :not_provisioned}

  # --- read / reattach ---

  @impl true
  def start_reader(handle, session_pid, cursor), do: do_read(handle, session_pid, cursor)

  @impl true
  def reattach(%__MODULE__{container_id: id} = handle, _cursor) when is_binary(id) do
    # Confirm the container is still there before the caller commits to it; the
    # reader is started separately via start_reader/3.
    case API.request(handle.config, :get, "/containers/#{id}/json") do
      {:ok, _} -> {:ok, handle}
      {:error, reason} -> {:error, reason}
    end
  end

  def reattach(%__MODULE__{}, _cursor), do: {:error, :not_provisioned}

  # start_reader/3 and reattach are the same read: only the starting offset
  # differs, so this is written once.
  defp do_read(%__MODULE__{container_id: id} = handle, session_pid, cursor) when is_binary(id) do
    offset = Map.get(cursor, :byte_offset, 0)

    # The reader is spawn_linked per the Backend reader contract: if it dies,
    # the session must die with it rather than go silently deaf.
    #
    # It also traps exits, because `Req`'s `into: :self` machinery spawn_links
    # its own worker task to *this* process: an abnormal task exit would
    # otherwise kill the reader before it could cast `:eof`, and Session never
    # monitors the reader, so the session would go down with no end-of-stream
    # at all. Measured while building Backend.Sandboxd, which has the identical
    # exposure; the fix is the same in both.
    reader =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        reader_loop(%{
          handle: handle,
          session: session_pid,
          offset: offset,
          demux: Demux.new(),
          inflight: 0,
          resp: nil,
          max_inflight: handle.config[:max_inflight_bytes] || @default_max_inflight
        })
      end)

    {:ok, reader}
  end

  defp do_read(%__MODULE__{}, _session_pid, _cursor), do: {:error, :not_provisioned}

  # Backpressure, the honest version.
  #
  # net_runner's NIF read gives free backpressure; `Req into: :self` gives none
  # -- chunks pile into the reader's mailbox whether or not Session keeps up.
  # Req has no pause primitive, but it does have cancellation, and this
  # backend's read is *resumable by construction*: reading is just
  # `tail -c +<offset>` over the tee file. So "pause" is implemented as cancel,
  # and "resume" as re-issuing the read from the offset already delivered. No
  # bytes are lost or duplicated because the offset is exact.
  defp reader_loop(state) do
    case open_stream(state) do
      {:ok, state} -> consume(state)
      {:error, reason} -> fail(state, reason)
    end
  end

  defp open_stream(state) do
    cmd = ["tail", "-c", "+#{state.offset + 1}", "-f", state.handle.tee_path]

    with {:ok, exec_id} <- create_exec(state.handle, cmd, attach: true),
         {:ok, resp} <-
           API.stream(state.handle.config, :post, "/exec/#{exec_id}/start",
             json: %{"Detach" => false, "Tty" => false},
             into: :self
           ) do
      {:ok, attach_stream(state, resp)}
    end
  end

  @doc false
  # Bind a reader state to a NEW connection.
  #
  # Demux state MUST be dropped here. Docker's 8-byte frame headers are
  # per-connection, but `state.offset` is a position in the tee *file*. If a
  # backpressure cancel landed mid-frame, the leftover header bytes belong to a
  # connection that no longer exists; carrying them forward prepends them to the
  # new connection's first frame and desyncs the parser permanently. The payload
  # those bytes described was never delivered (offset only advances on delivery),
  # so re-reading from `offset` re-sends it in fresh frames — nothing is lost by
  # discarding the remainder.
  #
  # Exposed (doc-false) so the invariant is testable without a live daemon and a
  # precisely-timed mid-frame cancellation. See docker_unit_test.exs.
  def attach_stream(state, resp) do
    %{state | resp: resp, demux: Demux.new()}
  end

  defp fail(state, reason) do
    Logger.warning("Docker reader stopped: #{inspect(reason)}")
    GenServer.cast(state.session, :eof)
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

          # A mid-stream transport failure. Without this clause the CaseClauseError
          # would kill this spawn_linked reader and take the session down with it —
          # exactly the "session left hanging" the Backend reader contract requires
          # us to prevent by casting :eof instead.
          {:error, reason} ->
            fail(state, reason)

          :unknown ->
            consume(state)
        end
    end
  end

  defp handle_parts(state, parts) do
    state = Enum.reduce(parts, state, &apply_part/2)

    cond do
      :done in parts -> GenServer.cast(state.session, :eof)
      state.inflight >= state.max_inflight -> pause(state)
      true -> consume(state)
    end
  end

  defp apply_part({:data, data}, state), do: deliver(state, data)
  defp apply_part(:done, state), do: state

  defp apply_part(other, state) do
    # Anything Req grows a new part shape for should be visible rather than
    # silently dropped -- a swallowed error part would look like a stalled stream.
    Logger.debug("Docker reader ignoring unrecognized stream part: #{inspect(other)}")
    state
  end

  defp deliver(state, data) do
    {payloads, demux} = Demux.feed(state.demux, data)

    Enum.each(payloads, &GenServer.cast(state.session, {:stdout_data, &1}))

    delivered = payloads |> Enum.map(&byte_size/1) |> Enum.sum()

    %{
      state
      | demux: demux,
        # The offset advances only by bytes actually handed to the session, so a
        # resume never re-reads what was already delivered nor skips what was
        # buffered mid-frame.
        offset: state.offset + delivered,
        inflight: state.inflight + delivered
    }
  end

  defp ack(state, bytes), do: %{state | inflight: max(state.inflight - bytes, 0)}

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

      # An orphan chunk or a late :done from the cancelled request. There is no
      # live response to parse it against, and the bytes are re-sent from
      # `offset` when the stream reopens, so it is dropped.
      _other ->
        await_drain(state)
    after
      # The session went away or stopped acking; nothing left to read for.
      60_000 ->
        GenServer.cast(state.session, :eof)
    end
  end

  # The session going away is not a failure and needs no :eof — there is nobody
  # left to tell. Anything else exiting abnormally is Req's own stream task
  # dying, which is a transport failure and must produce exactly one :eof.
  defp on_exit_signal(state, pid, reason, continue) do
    cond do
      pid == state.session -> :ok
      reason == :normal -> continue.(state)
      true -> fail(state, {:stream_task_exit, reason})
    end
  end

  # --- lifecycle ---

  @impl true
  def await_exit(%__MODULE__{container_id: id} = handle, _timeout) when is_binary(id) do
    case API.request(handle.config, :get, "/containers/#{id}/json") do
      {:ok, %{"State" => %{"Running" => false, "ExitCode" => code}}} -> {:ok, code}
      {:ok, _} -> :timeout
      {:error, {:docker, {:not_found, _}}} -> {:ok, nil}
      {:error, _} -> :timeout
    end
  end

  def await_exit(%__MODULE__{}, _timeout), do: :timeout

  @impl true
  def alive?(%__MODULE__{container_id: id} = handle) when is_binary(id) do
    case API.request(handle.config, :get, "/containers/#{id}/json") do
      {:ok, %{"State" => %{"Running" => running}}} -> !!running
      _ -> false
    end
  end

  def alive?(%__MODULE__{}), do: false

  @impl true
  def destroy(%__MODULE__{container_id: nil}), do: :ok

  def destroy(%__MODULE__{container_id: id} = handle) do
    case API.request(handle.config, :delete, "/containers/#{id}", params: [force: true, v: true]) do
      {:ok, _} ->
        :ok

      # 404 means it is already gone, which is the desired end state. The
      # behaviour requires destroy/1 to be idempotent and Session calls it from
      # several teardown paths.
      {:error, {:docker, {:not_found, _}}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Docker destroy failed for #{String.slice(id, 0, 12)}: #{inspect(reason)}")
        :ok
    end
  end

  @impl true
  def scrub(%__MODULE__{} = handle) do
    # The handle carries the config it was provisioned from, which may include
    # :api_key and :session_token. Store records can be written to disk and
    # outlive the VM, and reattaching needs none of this -- the container
    # already holds whatever environment it was started with.
    %{handle | config: CrowdControl.Store.scrub_opts(handle.config)}
  end

  @impl true
  def list_live(opts) do
    owner = opts[:owner] || Store.owner_id()

    # Scoped to this owner, never global. An unscoped list would let one node's
    # reaper destroy another node's containers.
    filters = JSON.encode!(%{"label" => ["crowd_control.owner=#{owner}"]})

    case API.request(opts, :get, "/containers/json", params: [filters: filters, all: false]) do
      {:ok, containers} when is_list(containers) ->
        {:ok, Enum.map(containers, &handle_from_container(&1, opts, owner))}

      {:ok, other} ->
        {:error, {:docker, {:unexpected_list_response, other}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_from_container(container, opts, owner) do
    labels = Map.get(container, "Labels") || %{}

    %__MODULE__{
      container_id: container["Id"],
      image: container["Image"],
      tee_path: opts[:tee_path] || @default_tee,
      fifo_path: opts[:fifo_path] || @default_fifo,
      session_key: labels["crowd_control.session"],
      owner: labels["crowd_control.owner"] || owner,
      config: opts
    }
  end

  @doc """
  Milliseconds since the container was created, from its label.

  `nil` when the label is missing or unparseable. `CrowdControl.Reaper` uses
  this for the grace period that keeps a mid-provision container from being
  reaped before its store record exists.
  """
  @spec age_ms(t()) :: non_neg_integer() | nil
  def age_ms(%__MODULE__{} = handle), do: age_from_config(handle)

  defp age_from_config(%__MODULE__{config: config, container_id: id}) do
    case API.request(config, :get, "/containers/#{id}/json") do
      {:ok, %{"Config" => %{"Labels" => %{"crowd_control.created_at" => created}}}} ->
        case Integer.parse(created) do
          {ms, ""} -> max(System.system_time(:millisecond) - ms, 0)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # --- Private ---

  defp fetch_image(opts) do
    case opts[:image] do
      image when is_binary(image) and image != "" -> {:ok, image}
      _ -> {:error, {:docker, :image_required}}
    end
  end

  defp ensure_req! do
    if Code.ensure_loaded?(Req) do
      :ok
    else
      raise """
      CrowdControl.Backend.Docker requires the optional :req dependency.

      Add it to your deps:

          {:req, "~> 0.5"}
      """
    end
  end
end
