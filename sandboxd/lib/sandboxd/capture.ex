defmodule Sandboxd.Capture do
  @moduledoc """
  The capture file: every byte the CLI has written to stdout, in order.

  This is byte-for-byte the same artifact as the `tee` file that
  `CrowdControl.Backend.Docker` reads with `tail -c +N`, which is the whole
  reason `CrowdControl.Backend.Sandboxd` can reuse the existing
  `%{byte_offset:, buffer:}` cursor unchanged. A reader resuming at byte N gets
  exactly the bytes from N onward, so a JSON line split across a crash rejoins
  byte-exactly.

  Offsets here are **0-indexed**. `tail -c +N` is 1-indexed, and the resulting
  `byte_offset + 1` is documented at `CrowdControl.Backend.Docker`'s
  `read` command for exactly one reason: getting it wrong duplicates a byte per
  resume and corrupts the line stream. There is no shell here, so there is no
  reason to inherit that hazard.

  ## Never rotated, only capped

  A rotated capture file invalidates every persisted byte offset, which
  silently corrupts resume — the precise failure the offset cursor exists to
  prevent. The parent app's `:max_stream_bytes` destroys the sandbox instead.
  Do not add rotation here.

  ## Why readers are notified, not polling

  Three mechanisms were available for "block until byte N+1 exists":

    * **`:file.position` + poll.** Simple, but adds up to one poll interval of
      latency to every single line of an interactive agent turn. Measured on
      this machine, a 25 ms interval costs a mean ~12 ms per line; an agent
      streaming a few hundred lines pays seconds of pure jitter.
    * **`:file_monitor`.** Not in OTP. It is a third-party package, and this
      release's dependency list is deliberately four packages long.
    * **Notification from the writer.** Chosen. Every byte in this file is
      written by `append/1`, called by `Sandboxd.Exec` with data it just read
      from the CLI, so this process always already knows when new bytes exist.
      Waiters are woken in the same call that writes them: zero added latency,
      no timer, no extra dependency.

  The file is still the source of truth for *bytes* — readers open their own
  handle and read it directly, so serving an offset from an hour ago costs this
  process nothing. Only *liveness* is in memory.
  """

  use GenServer

  require Logger

  @default_path "/var/log/cc/out.jsonl"
  @read_chunk 64 * 1024

  # How long a waiting reader parks before being told "nothing new yet". The
  # HTTP layer needs a bounded wait so it can honour :wait_ms and so a client
  # that vanished does not pin a process forever.
  @default_wait_ms 25_000

  @type status :: %{bytes: non_neg_integer(), final: boolean()}

  # --- Client ---

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The configured capture path: `CC_SANDBOXD_CAPTURE`, else `#{@default_path}`.
  """
  @spec default_path() :: Path.t()
  def default_path, do: System.get_env("CC_SANDBOXD_CAPTURE") || @default_path

  @doc """
  The path this process actually opened.

  Readers ask the server rather than re-deriving `default_path/0`: those two
  can differ (a changed env var, or an explicitly configured path), and a
  reader streaming a *different* file than the writer appends to serves stale
  or empty bytes for every offset the parent app has persisted.
  """
  @spec path() :: Path.t()
  def path, do: GenServer.call(__MODULE__, :path)

  @doc "Append `data` and wake every reader waiting for new bytes."
  @spec append(iodata()) :: :ok | {:error, term()}
  def append(data), do: GenServer.call(__MODULE__, {:append, data})

  @doc """
  Mark the capture complete: the CLI has exited and no more bytes will arrive.

  Distinguishes "EOF, wait for more" from "EOF, that is all there will ever
  be", which is what lets `/v1/stream` terminate a chunked response instead of
  hanging forever on a finished process.
  """
  @spec finalize() :: :ok
  def finalize, do: GenServer.call(__MODULE__, :finalize)

  @doc "Total bytes written, and whether the capture is complete."
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Total bytes written so far."
  @spec bytes() :: non_neg_integer()
  def bytes, do: status().bytes

  @doc """
  Block until more than `offset` bytes exist, the capture is finalized, or
  `timeout` elapses.

  Returns the status either way, so a caller can distinguish "new bytes" from
  "finished" from "still nothing".
  """
  @spec await(non_neg_integer(), timeout()) :: status()
  def await(offset, timeout \\ @default_wait_ms) do
    # +5s so the GenServer.call outlives the server-side wait it is asking for
    # and a timeout surfaces as a status, never as an exit.
    GenServer.call(__MODULE__, {:await, offset, timeout}, timeout + 5_000)
  end

  @doc """
  A stream of the capture file's bytes starting at `offset` (0-indexed).

  Blocks for new bytes while the capture is live. Each element is a binary
  chunk of at most #{@read_chunk} bytes; chunk boundaries carry no meaning,
  since the parent app's `CrowdControl.Session` owns line splitting.

  ## The stream ending does not mean end-of-output

  It halts on two different conditions: the capture is finalized and drained
  (genuinely over), or nothing new arrived within `:wait_ms` (an idle gap in an
  interactive session). Those are deliberately not distinguished here, because
  distinguishing them in-band would require injecting a keepalive byte into a
  stream whose byte offsets are load-bearing.

  A client that sees the stream end therefore asks `GET /v1/status`: still
  alive, or more bytes than it has consumed, means re-request from its current
  offset; otherwise it is EOF. The client already owns exactly that
  cancel-and-re-request loop for backpressure, so this adds no mechanism.
  """
  @spec stream(non_neg_integer(), keyword()) :: Enumerable.t()
  def stream(offset, opts \\ []) when is_integer(offset) and offset >= 0 do
    wait_ms = Keyword.get(opts, :wait_ms, @default_wait_ms)

    Stream.resource(
      fn -> open_reader!(path(), offset) end,
      &next_chunk(&1, wait_ms),
      fn {io, _pos} -> File.close(io) end
    )
  end

  # --- Server ---

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    File.mkdir_p!(Path.dirname(path))

    # :raw for a direct fd with no intermediary process, and *no*
    # :delayed_write: a buffered write is invisible to a reader's own file
    # handle, so `bytes` would advance while the file did not. That is a
    # phantom-offset bug, not a performance win.
    case File.open(path, [:append, :raw, :binary]) do
      {:ok, io} ->
        {:ok, %{path: path, io: io, bytes: existing_bytes(path), final: false, waiters: []}}

      {:error, reason} ->
        {:stop, {:capture_open_failed, path, reason}}
    end
  end

  @impl true
  def handle_call({:append, data}, _from, state) do
    case :file.write(state.io, data) do
      :ok ->
        state = %{state | bytes: state.bytes + IO.iodata_length(data)}
        {:reply, :ok, wake_waiters(state)}

      {:error, reason} = error ->
        Logger.error("capture write failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:finalize, _from, state) do
    {:reply, :ok, wake_waiters(%{state | final: true})}
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status(state), state}

  @impl true
  def handle_call({:await, offset, timeout}, from, state) do
    cond do
      state.bytes > offset or state.final ->
        {:reply, status(state), state}

      timeout <= 0 ->
        {:reply, status(state), state}

      true ->
        timer = Process.send_after(self(), {:await_timeout, from}, timeout)
        {:noreply, %{state | waiters: [{from, offset, timer} | state.waiters]}}
    end
  end

  @impl true
  def handle_info({:await_timeout, from}, state) do
    {expired, still_waiting} =
      Enum.split_with(state.waiters, fn {waiter, _offset, _timer} -> waiter == from end)

    Enum.each(expired, fn {waiter, _offset, _timer} ->
      GenServer.reply(waiter, status(state))
    end)

    {:noreply, %{state | waiters: still_waiting}}
  end

  @impl true
  def terminate(_reason, state), do: File.close(state.io)

  defp status(state), do: %{bytes: state.bytes, final: state.final}

  defp wake_waiters(state) do
    reply = status(state)

    {woken, still_waiting} =
      Enum.split_with(state.waiters, fn {_from, offset, _timer} ->
        state.final or state.bytes > offset
      end)

    Enum.each(woken, fn {from, _offset, timer} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, reply)
    end)

    %{state | waiters: still_waiting}
  end

  # A capture file that already exists (sandboxd restarted under the same
  # sandbox) keeps its bytes: offsets must stay meaningful across our own
  # restart, or the parent's persisted cursor points at the wrong byte.
  defp existing_bytes(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> 0
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp open_reader!(path, offset) do
    io = File.open!(path, [:read, :raw, :binary])
    {io, offset}
  end

  defp next_chunk({io, pos}, wait_ms) do
    case :file.pread(io, pos, @read_chunk) do
      {:ok, data} ->
        {[data], {io, pos + byte_size(data)}}

      :eof ->
        case await(pos, wait_ms) do
          %{bytes: bytes} when bytes > pos -> {[], {io, pos}}
          %{final: true} -> {:halt, {io, pos}}
          _ -> {:halt, {io, pos}}
        end

      {:error, _reason} ->
        {:halt, {io, pos}}
    end
  end
end
