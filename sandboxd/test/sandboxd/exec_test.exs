defmodule Sandboxd.ExecTest do
  use Sandboxd.SandboxCase, async: false

  alias Sandboxd.Capture
  alias Sandboxd.Exec

  describe "env delivery (blocker: a secret readable by ps inside the sandbox)" do
    test "the CLI receives env vars" do
      :ok = Exec.exec("/bin/sh", ["-c", ~s|printf %s "$CC_TEST_VAR"|], %{"CC_TEST_VAR" => "seen"})
      await_final()

      assert captured() == "seen"
    end

    test "no env value appears in the CLI's own argv" do
      # ps works inside a sandbox, and the code running there is model-driven and
      # untrusted, so a secret in argv is a secret handed to it. The wrapper
      # shell execs the CLI, so by the time this runs the env file is already
      # sourced and removed and the process image is the CLI itself.
      secret = "top-secret-value-#{:erlang.unique_integer([:positive])}"

      :ok =
        Exec.exec(
          "/bin/sh",
          ["-c", ~s|printf 'ARGV:%s:\\n' "$(ps -ww -o args= -p $$)"|],
          %{"SECRET_ENV" => secret}
        )

      await_final()

      argv = captured()
      assert argv =~ "ARGV:"
      refute argv =~ secret
    end

    test "env values needing shell quoting survive intact" do
      # Single-quoting is the only POSIX quoting with no escapes inside it, so
      # the only hazard is a literal quote. These values would break a naive
      # `export K=v` interpolation.
      hostile = ~s|it's "quoted" $(echo pwned) `echo pwned` \\ end|

      :ok = Exec.exec("/bin/sh", ["-c", ~s|printf %s "$HOSTILE"|], %{"HOSTILE" => hostile})
      await_final()

      assert captured() == hostile
    end

    test "the env file is removed before the CLI is exec'd" do
      # The wrapper sources the file then rm's it, so a CLI that later leaks its
      # own filesystem — or a crash dump, or a later process in the sandbox —
      # finds no credentials on disk. The 0700 directory outlives it and is
      # removed at shutdown; only the file holds secrets.
      :ok =
        Exec.exec(
          "/bin/sh",
          ["-c", "ls #{System.tmp_dir!()}/sandboxd_env_*/env.sh 2>/dev/null | wc -l"],
          %{"CC_TEST_VAR" => "x"}
        )

      await_final()

      assert String.trim(captured()) == "0"
    end

    test "no temp env directory survives shutdown" do
      :ok = Exec.exec("/bin/sh", ["-c", "sleep 5"], %{"CC_TEST_VAR" => "x"})
      Process.sleep(50)
      :ok = Exec.shutdown()

      assert env_dirs() == []
    end

    test "an empty env creates no env file" do
      :ok = Exec.exec("/bin/echo", ["direct"], %{})
      await_final()

      assert captured() == "direct\n"
      assert env_dirs() == []
    end
  end

  describe "release env scrub (blocker: sandboxd's distribution cookie inherited by the CLI)" do
    @release_root "/opt/cc_fake_release"
    @release_path "#{@release_root}/erts-15.2/bin:#{@release_root}/bin"

    setup do
      original_path = System.get_env("PATH")
      cookie = "cookie-#{System.unique_integer([:positive])}"

      System.put_env(%{
        "RELEASE_COOKIE" => cookie,
        "RELEASE_ROOT" => @release_root,
        "BINDIR" => "#{@release_root}/erts-15.2/bin",
        "PATH" => "#{@release_path}:#{original_path}"
      })

      on_exit(fn ->
        Enum.each(~w(RELEASE_COOKIE RELEASE_ROOT BINDIR), &System.delete_env/1)
        System.put_env("PATH", original_path)
      end)

      %{cookie: cookie, original_path: original_path}
    end

    test "the CLI sees no release vars and no release PATH; explicit env survives", ctx do
      :ok = Exec.exec("/usr/bin/env", [], %{"RELEASE_NODE" => "x"})
      await_final()
      output = captured()

      refute output =~ ctx.cookie
      refute output =~ ~r/^RELEASE_COOKIE=/m
      refute output =~ ~r/^RELEASE_ROOT=/m
      refute output =~ ~r/^BINDIR=/m
      assert output =~ ~r/^RELEASE_NODE=x$/m

      [path] = Regex.run(~r/^PATH=(.*)$/m, output, capture: :all_but_first)
      assert path == ctx.original_path
    end

    test "the scrub applies with an empty env too, still without an env file", ctx do
      :ok = Exec.exec("/usr/bin/env", [], %{})
      await_final()
      output = captured()

      refute output =~ ctx.cookie
      refute output =~ @release_root
      assert env_dirs() == []
    end
  end

  # The same cases as CrowdControl.Backend.Shell.release_scrub/1's in the parent
  # app; the two copies must agree.
  describe "release_scrub/1" do
    test "enumerates RELEASE_* names, skips names sh cannot unset, leaves PATH alone without RELEASE_ROOT" do
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

      assert {unset, nil} = Exec.release_scrub(env)
      assert unset == ~w(EMU PROGNAME RELEASE_COOKIE RELEASE_NODE ROOTDIR)
    end

    test "strips only RELEASE_ROOT's bin and erts-*/bin from PATH" do
      env = %{
        "RELEASE_ROOT" => "/app/",
        "PATH" => "/app/erts-15.2/bin:/app/bin/:/app/lib/x/bin:/app-other/bin:/usr/bin"
      }

      assert {["RELEASE_ROOT"], "/app/lib/x/bin:/app-other/bin:/usr/bin"} =
               Exec.release_scrub(env)
    end

    test "matches the parent app's doctest" do
      env = %{
        "RELEASE_ROOT" => "/app",
        "RELEASE_COOKIE" => "secret",
        "BINDIR" => "/app/erts-15.0/bin",
        "PATH" => "/app/erts-15.0/bin:/app/bin:/usr/bin:/bin",
        "HOME" => "/root"
      }

      assert Exec.release_scrub(env) ==
               {["BINDIR", "RELEASE_COOKIE", "RELEASE_ROOT"], "/usr/bin:/bin"}
    end
  end

  describe "one exec per lifetime (blocker: two streams behind one cursor)" do
    test "a second exec is refused" do
      :ok = Exec.exec("/bin/echo", ["one"], %{})
      assert {:error, :already_executed} = Exec.exec("/bin/echo", ["two"], %{})
    end

    test "refusal stands after the first CLI exits" do
      :ok = Exec.exec("/bin/echo", ["one"], %{})
      await_final()

      assert {:error, :already_executed} = Exec.exec("/bin/echo", ["two"], %{})
      assert captured() == "one\n"
    end
  end

  describe "status/0 (blocker: a session that never learns the CLI died)" do
    test "reports not-started before any exec" do
      assert %{alive: false, exit_status: nil, bytes: 0, started: false} = Exec.status()
    end

    test "reports alive while the CLI runs" do
      :ok = Exec.exec("/bin/sh", ["-c", "sleep 5"], %{})
      assert %{alive: true, started: true, exit_status: nil} = Exec.status()
    end

    test "reports the exit status and finalizes the capture when the CLI exits" do
      :ok = Exec.exec("/bin/sh", ["-c", "exit 3"], %{})
      await_final()

      assert %{alive: false, exit_status: 3, started: true} = Exec.status()
      assert Capture.status().final
    end

    test "finalizes the capture even when the CLI is killed rather than exiting" do
      :ok = Exec.exec("/bin/sh", ["-c", "sleep 30"], %{})
      Process.sleep(50)
      :ok = Exec.shutdown()

      # An unfinalized capture leaves every streaming client parked on a process
      # that can never write again.
      assert Capture.status().final
    end
  end

  describe "write/1 (blocker: a lost prompt)" do
    test "is refused before exec, instead of vanishing" do
      assert {:error, :not_started} = Exec.write("hello\n")
    end

    test "reaches the CLI's stdin" do
      :ok = Exec.exec("/bin/cat", [], %{})
      :ok = Exec.write("round-trip\n")

      await_bytes(11)
      assert captured() =~ "round-trip"
    end

    test "repeated writes all arrive, in order" do
      :ok = Exec.exec("/bin/cat", [], %{})
      for n <- 1..5, do: :ok = Exec.write("line-#{n}\n")

      await_bytes(35)
      assert captured() == Enum.map_join(1..5, "", &"line-#{&1}\n")
    end
  end

  describe "shutdown/0 (blocker: an orphaned CLI holding the sandbox open)" do
    test "is idempotent" do
      :ok = Exec.exec("/bin/sh", ["-c", "sleep 30"], %{})
      assert :ok = Exec.shutdown()
      assert :ok = Exec.shutdown()
    end

    test "is safe before any exec" do
      assert :ok = Exec.shutdown()
    end
  end

  defp captured, do: Capture.stream(0, wait_ms: 50) |> Enum.join()

  defp env_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "sandboxd_env_"))
  end
end
