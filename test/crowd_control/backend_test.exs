defmodule CrowdControl.BackendTest do
  use ExUnit.Case, async: true

  alias CrowdControl.Backend
  alias CrowdControl.Backend.{Local, Shell}

  doctest CrowdControl.Backend
  doctest CrowdControl.Backend.Shell

  describe "resolve/1" do
    test "defaults to Backend.Local" do
      assert {Local, []} = Backend.resolve([])
    end

    test "accepts a bare module and strips :backend from the opts" do
      assert {Local, [timeout: 5]} = Backend.resolve(backend: Local, timeout: 5)
    end

    test "merges {module, config} config over the session opts" do
      assert {Local, opts} =
               Backend.resolve(backend: {Local, image: "b", timeout: 9}, image: "a", timeout: 1)

      assert opts[:image] == "b"
      assert opts[:timeout] == 9
    end

    test "rejects anything that is not a module or {module, keyword}" do
      assert_raise ArgumentError, ~r/must be a module/, fn ->
        Backend.resolve(backend: "Elixir.Nope")
      end

      assert_raise ArgumentError, ~r/must be a module/, fn ->
        Backend.resolve(backend: {Local, %{not: :keyword}})
      end
    end
  end

  describe "safe/2" do
    test "returns the value when the function does not exit" do
      assert Backend.safe(fn -> {:ok, 1} end, :fallback) == {:ok, 1}
    end

    test "returns the default on exit" do
      assert Backend.safe(fn -> exit(:boom) end, :fallback) == :fallback

      assert Backend.safe(fn -> GenServer.call(:nonexistent_server, :x) end, :fallback) ==
               :fallback
    end

    test "does NOT swallow ordinary exceptions" do
      # This is the whole point of catching :exit only. A rescue here would turn
      # a typo in a backend into a silent "sandbox unavailable".
      assert_raise ArgumentError, fn -> Backend.safe(fn -> raise ArgumentError end, :fallback) end

      # Built at runtime so the compiler cannot resolve the deliberately
      # undefined module and warn about it.
      missing = String.to_atom("Elixir.NoSuchModuleAnywhere")

      assert_raise UndefinedFunctionError, fn ->
        Backend.safe(fn -> missing.nope() end, :fallback)
      end
    end
  end

  describe "reattachable?/1" do
    test "is false for Backend.Local" do
      refute Backend.reattachable?(Local)
    end

    test "is false for a module that does not export reattachable?/0" do
      refute Backend.reattachable?(Shell)
      refute Backend.reattachable?(NoSuchModuleAtAll)
    end
  end

  describe "new_cursor/0" do
    test "starts at offset zero with an empty buffer" do
      assert Backend.new_cursor() == %{byte_offset: 0, buffer: ""}
    end
  end
end
