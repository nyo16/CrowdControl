defmodule CrowdControl.AgentTest do
  use ExUnit.Case, async: true

  doctest CrowdControl.Agent

  alias CrowdControl.Agent
  alias CrowdControl.Agent.{ClaudeCode, Omp}

  describe "resolve/1" do
    test "defaults to Claude Code" do
      assert Agent.resolve([]) == ClaudeCode
    end

    test "resolves built-in aliases" do
      assert Agent.resolve(agent: :claude) == ClaudeCode
      assert Agent.resolve(agent: :claude_code) == ClaudeCode
      assert Agent.resolve(agent: :open_code) == ClaudeCode
      assert Agent.resolve(agent: :opencode) == ClaudeCode
      assert Agent.resolve(agent: :omp) == Omp
    end

    test "accepts a module implementing the behaviour" do
      assert Agent.resolve(agent: Omp) == Omp
    end

    test "infers omp from the executable basename" do
      assert Agent.resolve(executable: "omp") == Omp
      assert Agent.resolve(executable: "/opt/homebrew/bin/omp") == Omp
    end

    test "an unrecognized executable stays on Claude Code" do
      assert Agent.resolve(executable: "open-code") == ClaudeCode
      assert Agent.resolve(executable: "/usr/local/bin/claude") == ClaudeCode
    end

    test "explicit :agent wins over the executable" do
      assert Agent.resolve(agent: :claude, executable: "omp") == ClaudeCode
    end

    test "rejects an unknown atom rather than failing later inside init" do
      assert_raise ArgumentError, ~r/:agent must be one of/, fn ->
        Agent.resolve(agent: :codex)
      end
    end

    test "rejects a module that does not implement the behaviour" do
      assert_raise ArgumentError, ~r/:agent must be one of/, fn ->
        Agent.resolve(agent: CrowdControl.Store)
      end
    end

    test "rejects a non-atom" do
      assert_raise ArgumentError, ~r/:agent must be an atom or module/, fn ->
        Agent.resolve(agent: "omp")
      end
    end
  end

  describe "ClaudeCode adapter" do
    test "build_command/1 matches CrowdControl.CLI" do
      assert ClaudeCode.build_command(model: "opus") ==
               CrowdControl.CLI.build_command(model: "opus")
    end

    test "needs no handshake frames" do
      assert ClaudeCode.init_frames([]) == []
    end

    test "encode_prompt/3 ignores the sequence number" do
      assert ClaudeCode.encode_prompt("hi", 0, []) == ClaudeCode.encode_prompt("hi", 7, [])

      assert {:user, _} =
               ClaudeCode.decode_line(String.trim(ClaudeCode.encode_prompt("hi", 0, [])))
    end
  end
end
