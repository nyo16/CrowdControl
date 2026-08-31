defmodule Sandboxd.SandboxCase do
  @moduledoc """
  Starts a `Sandboxd.Capture` and `Sandboxd.Exec` over a temp capture file.

  Both are named singletons — there is exactly one sandbox per agent, which is
  the whole design — so every case using them is `async: false` and restarts
  them per test rather than sharing state.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Sandboxd.SandboxCase
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "sandboxd_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "out.jsonl")

    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!({Sandboxd.Capture, path: path})
    start_supervised!(Sandboxd.Exec)

    {:ok, capture_path: path, capture_dir: dir}
  end

  @doc "Run `fun` with `CC_SANDBOXD_TOKEN`'s in-memory equivalent set."
  def with_token(token, fun) do
    previous = Sandboxd.Auth.token()
    Sandboxd.Auth.put_token(token)

    try do
      fun.()
    after
      Sandboxd.Auth.put_token(previous)
    end
  end

  @doc "Block until the capture reports at least `bytes` bytes, or fail."
  def await_bytes(bytes, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_bytes(bytes, deadline)
  end

  defp do_await_bytes(bytes, deadline) do
    current = Sandboxd.Capture.bytes()

    cond do
      current >= bytes ->
        current

      System.monotonic_time(:millisecond) > deadline ->
        raise "timed out waiting for #{bytes} captured bytes, saw #{current}"

      true ->
        Process.sleep(10)
        do_await_bytes(bytes, deadline)
    end
  end

  @doc "Block until the capture is finalized, or fail."
  def await_final(timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_final(deadline)
  end

  defp do_await_final(deadline) do
    if Sandboxd.Capture.status().final do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        raise "timed out waiting for the capture to be finalized"
      end

      Process.sleep(10)
      do_await_final(deadline)
    end
  end
end
