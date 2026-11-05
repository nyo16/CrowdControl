defmodule Mix.Tasks.CrowdControl.ContractTest do
  # The fake binary reads its behaviour from the environment it inherits, which
  # is process-global, and so is Mix.shell/1.
  use ExUnit.Case, async: false

  alias Mix.Tasks.CrowdControl.Contract

  @fake Path.expand("../../support/fake_contract_cli.sh", __DIR__)
  @fake_env ~w(FAKE_CONTRACT_VERSION FAKE_CONTRACT_FLAGS FAKE_CONTRACT_HIDDEN
               FAKE_CONTRACT_PENDING_INSIDE CC_CONTRACT_BIN CC_CONTRACT_VERSION)

  setup do
    Mix.shell(Mix.Shell.Process)

    # CC_CONTRACT_* steer the task itself, so a developer's own exports would
    # leak into every test. Clear them for the test and put them back after.
    saved = contract_env()
    Enum.each(saved, fn {name, _} -> System.delete_env(name) end)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Enum.each(@fake_env, &System.delete_env/1)
      Enum.each(contract_env(), fn {name, _} -> System.delete_env(name) end)
      System.put_env(saved)
    end)

    listed =
      for %{flag: flag, hidden: false} <- CrowdControl.CLI.contract_flags(), do: flag

    System.put_env("FAKE_CONTRACT_FLAGS", Enum.join(listed, " "))
    %{listed: listed}
  end

  test "a binary that honours the whole contract passes" do
    Contract.run(["--bin", @fake])
    assert_received {:mix_shell, :info, ["CLI contract holds"]}
  end

  test "CC_CONTRACT_BIN selects the binary" do
    System.put_env("CC_CONTRACT_BIN", @fake)
    Contract.run([])
    assert_received {:mix_shell, :info, ["CLI contract holds"]}
  end

  test "a binary whose help lacks a flag fails, naming that flag", %{listed: listed} do
    System.put_env("FAKE_CONTRACT_FLAGS", Enum.join(listed -- ["--permission-prompts"], " "))

    error = assert_raise Mix.Error, fn -> Contract.run(["--bin", @fake]) end
    assert error.message =~ "flag --permission-prompts is not listed by --help"
    assert error.message =~ "1 mismatch"
  end

  test "a prefix of a flag does not count as listing it", %{listed: listed} do
    System.put_env(
      "FAKE_CONTRACT_FLAGS",
      Enum.join((listed -- ["--settings"]) ++ ["--settings-file"], " ")
    )

    error = assert_raise Mix.Error, fn -> Contract.run(["--bin", @fake]) end
    assert error.message =~ "flag --settings is not listed"
  end

  test "a hidden flag the parser does not know fails" do
    System.put_env("FAKE_CONTRACT_HIDDEN", "--something-else")

    error = assert_raise Mix.Error, fn -> Contract.run(["--bin", @fake]) end
    assert error.message =~ "hidden flag --permission-prompt-tool is not recognised"
  end

  test "a version below the minimum fails" do
    System.put_env("FAKE_CONTRACT_VERSION", "2.1.200")

    error = assert_raise Mix.Error, fn -> Contract.run(["--bin", @fake]) end

    assert error.message =~
             "version 2.1.200 is below the minimum #{CrowdControl.CLI.min_version()}"
  end

  test "a version other than the pinned one fails" do
    System.put_env("CC_CONTRACT_VERSION", "2.1.300")

    error = assert_raise Mix.Error, fn -> Contract.run(["--bin", @fake]) end
    assert error.message =~ "version 2.1.292 is not the expected 2.1.300"
  end

  test "pending_permission_requests inside response fails the probe" do
    System.put_env("FAKE_CONTRACT_PENDING_INSIDE", "1")

    error = assert_raise Mix.Error, fn -> Contract.run(["--bin", @fake]) end

    assert error.message =~
             "first initialize: no pending_permission_requests list at envelope level"

    assert error.message =~ "repeated initialize"
  end

  defp contract_env do
    for {name, _} = pair <- System.get_env(), String.starts_with?(name, "CC_CONTRACT_"), do: pair
  end
end
