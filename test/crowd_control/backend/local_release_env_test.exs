defmodule CrowdControl.Backend.LocalReleaseEnvTest do
  # Not async: the release environment has to be in the BEAM's own OS env for
  # the spawned child to inherit it, and System.put_env/2 is VM-global.
  use ExUnit.Case, async: false

  alias CrowdControl.Backend.Local
  alias CrowdControl.Backend.Shell

  @release_root "/opt/cc_fake_release"
  @release_path "#{@release_root}/erts-15.2/bin:#{@release_root}/bin"

  setup do
    previous = System.get_env()

    System.put_env(%{
      "RELEASE_COOKIE" => "cookie-#{System.unique_integer([:positive])}",
      "RELEASE_ROOT" => @release_root,
      "BINDIR" => "#{@release_root}/erts-15.2/bin",
      "PATH" => "#{@release_path}:#{previous["PATH"]}"
    })

    on_exit(fn ->
      Enum.each(~w(RELEASE_COOKIE RELEASE_ROOT BINDIR), &System.delete_env/1)
      System.put_env("PATH", previous["PATH"])
    end)

    %{cookie: System.get_env("RELEASE_COOKIE"), original_path: previous["PATH"]}
  end

  describe "release env scrub (blocker: the distribution cookie inherited by the CLI)" do
    test "the child sees no release vars and no release PATH; explicit :env survives", ctx do
      output = run_env(Local.provision([]), %{"RELEASE_NODE" => "x"})

      refute output =~ ctx.cookie
      refute output =~ ~r/^RELEASE_COOKIE=/m
      refute output =~ ~r/^RELEASE_ROOT=/m
      refute output =~ ~r/^BINDIR=/m
      assert output =~ ~r/^RELEASE_NODE=x$/m

      [path] = Regex.run(~r/^PATH=(.*)$/m, output, capture: :all_but_first)
      refute path =~ @release_root
      assert path == ctx.original_path
    end

    test "the scrub applies with an empty :env too", ctx do
      output = run_env(Local.provision([]), %{})

      refute output =~ ctx.cookie
      refute output =~ ~r/^RELEASE_ROOT=/m
      refute output =~ @release_root
    end

    test "release_env: :inherit opts out", ctx do
      output = run_env(Local.provision(release_env: :inherit), %{})

      assert output =~ "RELEASE_COOKIE=#{ctx.cookie}"
      assert output =~ @release_path
    end

    test "an unknown :release_env is refused before anything is spawned" do
      assert {:error, {:invalid_option, {:release_env, :nope}}} =
               Local.provision(release_env: :nope)
    end
  end

  describe "Shell.release_scrub/1" do
    test "enumerates RELEASE_* names, skips names sh cannot unset, and leaves PATH alone without RELEASE_ROOT" do
      env = %{
        "RELEASE_COOKIE" => "c",
        "RELEASE_NODE" => "n",
        "RELEASE_bad-name" => "x",
        "EMU" => "beam",
        "PROGNAME" => "erl",
        "ROOTDIR" => "/r",
        "NOT_RELEASE_X" => "kept",
        "PATH" => "/r/bin:/usr/bin"
      }

      assert {unset, nil} = Shell.release_scrub(env)
      assert unset == ~w(EMU PROGNAME RELEASE_COOKIE RELEASE_NODE ROOTDIR)
    end

    test "strips only RELEASE_ROOT's bin and erts-*/bin from PATH" do
      env = %{
        "RELEASE_ROOT" => "/app/",
        "PATH" => "/app/erts-15.2/bin:/app/bin/:/app/lib/x/bin:/app-other/bin:/usr/bin"
      }

      assert {["RELEASE_ROOT"], "/app/lib/x/bin:/app-other/bin:/usr/bin"} =
               Shell.release_scrub(env)
    end
  end

  defp run_env({:ok, handle}, env) do
    {:ok, handle} = Local.exec(handle, "/usr/bin/env", [], env)
    output = read_all(handle.proc, [])
    Local.destroy(handle)
    output
  end

  defp read_all(proc, acc) do
    case NetRunner.Process.read(proc) do
      {:ok, data} -> read_all(proc, [acc, data])
      _eof_or_error -> IO.iodata_to_binary(acc)
    end
  end
end
