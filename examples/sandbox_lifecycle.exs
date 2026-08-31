# What a sandbox actually is, one step at a time, with the bytes visible.
#
#     mix run examples/sandbox_lifecycle.exs
#
# This drives `CrowdControl.Backend.Docker` directly — below `CrowdControl.Session`
# — because the interesting parts are the ones a session hides: the FIFO, the tee
# file, the byte offset, and what happens to a sandbox whose CLI dies.
#
# Prerequisites: the optional `:req` dependency and a reachable Docker daemon.
# `alpine` is enough; no custom image, and no API key, because the "CLI" here is a
# shell loop that echoes JSON lines. That substitution is the point: the backend
# does not care what the CLI is, only that it reads stdin and writes stdout.
#
# See docs/sandboxes.md for why the topology is shaped this way.

alias CrowdControl.Backend
alias CrowdControl.Backend.Docker
alias CrowdControl.Store

defmodule Narrate do
  def step(n, text), do: IO.puts("\n\e[1m#{n}. #{text}\e[0m")
  def fact(label, value), do: IO.puts("     #{String.pad_trailing(label, 22)} #{value}")
end

# A stand-in for a real CLI: read a line, emit a JSON line. Exactly the contract
# `Agent.ClaudeCode` and `Agent.Omp` speak, minus the model.
echo_cli = ["-c", ~S|while IFS= read -r l; do printf '{"echo":"%s"}\n' "$l"; done|]

session_key = Store.new_key()
opts = [image: "alpine:latest", owner: "example-lifecycle", session_key: session_key]

Narrate.step(1, "provision/1 — create the sandbox, before any CLI exists")
{:ok, handle} = Docker.provision(opts)
Narrate.fact("container", String.slice(handle.container_id, 0, 12))
Narrate.fact("fifo", handle.fifo_path)
Narrate.fact("tee file", handle.tee_path)

# PID 1 is not the CLI. It creates the FIFO, then waits for a status file — which
# is what lets a dead CLI stop the container instead of stranding it Running.
Narrate.fact("alive?", inspect(Docker.alive?(handle)))

Narrate.step(2, "exec/4 — start the CLI, detached, writing through tee")
{:ok, handle} = Docker.exec(handle, "/bin/sh", echo_cli, %{})
Process.sleep(500)

# Called twice, this would truncate the tee file and invalidate every persisted
# cursor, so the backend refuses.
Narrate.fact("second exec/4", inspect(elem(Docker.exec(handle, "/bin/sh", echo_cli, %{}), 1)))

Narrate.step(3, "start_reader/3 + write/2 — a prompt in, JSON lines out")

test = self()

relay =
  spawn(fn ->
    loop = fn loop ->
      receive do
        {:"$gen_cast", msg} ->
          send(test, {:cast, msg})
          loop.(loop)
      end
    end

    loop.(loop)
  end)

{:ok, _reader} = Docker.start_reader(handle, relay, Backend.new_cursor())

for word <- ~w(alpha beta gamma) do
  :ok = Docker.write(handle, word <> "\n")
end

# Collect what the session would have seen.
collect = fn collect, acc ->
  receive do
    {:cast, {:stdout_data, bytes}} -> collect.(collect, acc <> bytes)
  after
    2_000 -> acc
  end
end

delivered = collect.(collect, "")
Narrate.fact("bytes delivered", byte_size(delivered))
Narrate.fact("content", inspect(delivered))

Narrate.step(4, "byte-exact resume — reattach mid-stream and lose nothing")

# Cut the stream at a byte offset that lands *inside* a line. A reader resuming
# here must reconstruct the line rather than re-deliver or skip bytes: `offset`
# counts bytes already handed to the session, `buffer` holds the partial line.
cut = div(byte_size(delivered), 2)
Narrate.fact("resume at byte", "#{cut} of #{byte_size(delivered)}")
Narrate.fact("consumed already", inspect(binary_part(delivered, 0, cut)))

cursor = %{byte_offset: cut, buffer: ""}
{:ok, handle} = Docker.reattach(handle, cursor)
{:ok, _reader2} = Docker.start_reader(handle, relay, cursor)

resumed = collect.(collect, "")
Narrate.fact("resumed bytes", byte_size(resumed))
Narrate.fact("resumed content", inspect(resumed))

if binary_part(delivered, cut, byte_size(delivered) - cut) == resumed do
  IO.puts("\n     \e[32m✓ the resumed stream is exactly the tail of the original —")
  IO.puts("       no byte duplicated, none lost\e[0m")
else
  IO.puts("\n     \e[31m✗ resume was not byte-exact\e[0m")
end

Narrate.step(5, "a dead CLI is observable — the sandbox stops, it does not strand")

# Kill only the CLI, leaving the launcher shell alone. PID 1 is polling for the
# status file the launcher writes once `tee` has drained.
{_, 0} =
  System.cmd("docker", [
    "exec",
    handle.container_id,
    "/bin/sh",
    "-c",
    "kill -9 $(ps -o pid,args | grep '[I]FS= read' | grep -v cc.launcher | awk '{print $1}')"
  ])

assert_eof = fn ->
  receive do
    {:cast, :eof} -> "yes"
  after
    30_000 -> "NO — this is the bug that used to hang sessions forever"
  end
end

Narrate.fact("session got :eof", assert_eof.())

wait_gone = fn wait_gone, tries ->
  cond do
    not Docker.alive?(handle) -> :stopped
    tries == 0 -> :still_running
    true -> Process.sleep(500) && wait_gone.(wait_gone, tries - 1)
  end
end

Narrate.fact("container stopped?", inspect(wait_gone.(wait_gone, 60) == :stopped))

# 137 = 128 + SIGKILL: the CLI's own status, relayed by PID 1 rather than invented.
Narrate.fact("await_exit/2", inspect(Docker.await_exit(handle, 30_000)))

Narrate.step(6, "destroy/1 — idempotent teardown")
Narrate.fact("first call", inspect(Docker.destroy(handle)))
Narrate.fact("second call", inspect(Docker.destroy(handle)))

IO.puts("""

Recap — the four facts that make this work:

  * the FIFO is held open read-write (`exec 3<> fifo`), so a detaching writer is
    never seen as EOF by the CLI;
  * output is duplicated to an append-only file by `tee`, so the stream is
    re-readable and resume is `tail -c +N -f` rather than a replay protocol;
  * a cursor is a byte offset plus a partial-line buffer, which is what makes a
    mid-line reattach exact;
  * PID 1 relays the CLI's exit status, so a dead CLI ends the session and stops
    the sandbox instead of billing forever.

docs/sandboxes.md explains each in full, including the Kubernetes and HTTP-agent
variants of the same design.
""")
