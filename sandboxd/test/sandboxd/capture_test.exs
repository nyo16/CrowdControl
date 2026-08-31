defmodule Sandboxd.CaptureTest do
  # Named singleton, so no async.
  use Sandboxd.SandboxCase, async: false

  alias Sandboxd.Capture

  describe "offset resume (blocker: a duplicated or dropped byte per resume)" do
    test "streaming from 0 returns every byte in order" do
      data = numbered_lines(1..200)
      :ok = Capture.append(data)
      :ok = Capture.finalize()

      assert Capture.stream(0) |> Enum.join() == data
    end

    test "streaming from N returns exactly the bytes from N onward" do
      data = numbered_lines(1..200)
      :ok = Capture.append(data)
      :ok = Capture.finalize()

      for offset <- [0, 1, 7, 100, byte_size(data) - 1, byte_size(data)] do
        assert Capture.stream(offset) |> Enum.join() ==
                 binary_part(data, offset, byte_size(data) - offset),
               "offset #{offset} did not resume byte-exactly"
      end
    end

    test "offsets are 0-indexed, not 1-indexed like tail -c +N" do
      :ok = Capture.append("abcdef")
      :ok = Capture.finalize()

      # tail -c +1 is the whole file, so a 1-indexed cursor here would drop
      # nothing at offset 1 and silently duplicate a byte on every resume.
      assert Capture.stream(1) |> Enum.join() == "bcdef"
    end

    test "a split-then-resume reassembles byte-exactly" do
      data = numbered_lines(1..500)
      :ok = Capture.append(data)
      :ok = Capture.finalize()

      cut = 3_001
      head = Capture.stream(0) |> Enum.join() |> binary_part(0, cut)
      tail = Capture.stream(cut) |> Enum.join()

      assert :crypto.hash(:sha256, head <> tail) == :crypto.hash(:sha256, data)
    end

    test "bytes survive a Capture restart, because the parent persists offsets",
         %{capture_path: path} do
      :ok = Capture.append("first-half:")
      stop_supervised!(Sandboxd.Capture)
      start_supervised!({Capture, path: path})

      assert Capture.bytes() == byte_size("first-half:")
      :ok = Capture.append("second-half")
      :ok = Capture.finalize()

      assert Capture.stream(0) |> Enum.join() == "first-half:second-half"
    end
  end

  describe "path/0 (blocker: a reader streaming a different file than the writer)" do
    test "reports the path actually opened, not the env default", %{capture_path: path} do
      assert Capture.path() == path
      refute Capture.path() == Capture.default_path()
    end
  end

  describe "await/2 (blocker: a polling reader's per-line latency)" do
    test "returns immediately when bytes already exceed the offset" do
      :ok = Capture.append("hello")
      assert %{bytes: 5, final: false} = Capture.await(0, 5_000)
    end

    test "is woken by the writer in the same call that writes" do
      task = Task.async(fn -> Capture.await(0, 5_000) end)
      # No sleep-then-poll: if append/1 did not wake waiters, this test would
      # hang for the full 5s and fail on the assertion below, not pass slowly.
      Process.sleep(20)
      :ok = Capture.append("x")

      assert %{bytes: 1, final: false} = Task.await(task, 1_000)
    end

    test "is woken by finalize, so a stream on a dead process does not park" do
      task = Task.async(fn -> Capture.await(0, 5_000) end)
      Process.sleep(20)
      :ok = Capture.finalize()

      assert %{bytes: 0, final: true} = Task.await(task, 1_000)
    end

    test "returns the current status when it times out, never an exit" do
      assert %{bytes: 0, final: false} = Capture.await(0, 30)
    end

    test "a zero timeout is a non-blocking poll" do
      assert %{bytes: 0, final: false} = Capture.await(0, 0)
    end
  end

  describe "stream termination (blocker: a client parked on a dead sandbox)" do
    test "halts once the capture is finalized and drained" do
      :ok = Capture.append("done")
      :ok = Capture.finalize()

      assert Capture.stream(0) |> Enum.to_list() |> IO.iodata_to_binary() == "done"
    end

    test "halts on an idle gap rather than holding the connection forever" do
      :ok = Capture.append("partial")

      # Not finalized: the stream ends because nothing new arrived, which the
      # client resolves with GET /v1/status rather than assuming EOF.
      assert Capture.stream(0, wait_ms: 30) |> Enum.join() == "partial"
      refute Capture.status().final
    end

    test "delivers bytes written while the stream is already open" do
      task = Task.async(fn -> Capture.stream(0, wait_ms: 500) |> Enum.join() end)

      Process.sleep(30)
      :ok = Capture.append("early-")
      Process.sleep(30)
      :ok = Capture.append("late")
      :ok = Capture.finalize()

      assert Task.await(task, 3_000) == "early-late"
    end
  end

  defp numbered_lines(range) do
    # Numbered lines make any gap or duplication visible in a diff, rather than
    # hiding inside a run of identical bytes.
    Enum.map_join(range, "", fn n -> "line-#{n}-#{String.duplicate("x", 8)}\n" end)
  end
end
