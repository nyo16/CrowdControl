defmodule CrowdControl.SessionReleaseEnvTest do
  # Not async: the release environment has to be in the BEAM's own OS env for
  # the `--version` probe to inherit it, and System.put_env/2 is VM-global.
  use ExUnit.Case, async: false

  alias CrowdControl.Session

  @release_root "/opt/cc_fake_release"
  @release_path "#{@release_root}/erts-15.2/bin:#{@release_root}/bin"

  # Callback extra_args are persisted, so they hold no pid; nothing calls it.
  def defer(_request, _context), do: :defer

  setup do
    # A failed init/1 exits the linked caller too.
    Process.flag(:trap_exit, true)
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

    dir = Path.join(System.tmp_dir!(), "cc-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # A CLI too old for a control session: the probe fails the start before
    # anything is spawned, and the env it saw is left behind in `dump`.
    cli = Path.join(dir, "claude")
    dump = Path.join(dir, "env")

    File.write!(cli, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      env > "$PROBE_DUMP"
      echo "2.1.0 (Claude Code)"
    fi
    """)

    File.chmod!(cli, 0o755)

    %{
      cookie: System.get_env("RELEASE_COOKIE"),
      original_path: previous["PATH"],
      cli: cli,
      dump: dump
    }
  end

  defp start(ctx, opts) do
    Session.start_link(
      [
        executable: ctx.cli,
        can_use_tool: {__MODULE__, :defer, []},
        env: %{"PROBE_DUMP" => ctx.dump, "RELEASE_NODE" => "x"}
      ] ++ opts
    )
  end

  describe "the local --version probe (W-12)" do
    test "sees no release vars and no release PATH; explicit :env survives", ctx do
      assert {:error, {:cli_version, "2.1.0", _need}} = start(ctx, [])
      output = File.read!(ctx.dump)

      refute output =~ ctx.cookie
      refute output =~ ~r/^RELEASE_COOKIE=/m
      refute output =~ ~r/^RELEASE_ROOT=/m
      refute output =~ ~r/^BINDIR=/m
      assert output =~ ~r/^RELEASE_NODE=x$/m

      [path] = Regex.run(~r/^PATH=(.*)$/m, output, capture: :all_but_first)
      refute path =~ @release_root
      assert path == ctx.original_path
    end

    test "release_env: :inherit opts out", ctx do
      assert {:error, {:cli_version, "2.1.0", _need}} = start(ctx, release_env: :inherit)
      output = File.read!(ctx.dump)

      assert output =~ "RELEASE_COOKIE=#{ctx.cookie}"
      assert output =~ @release_path
    end
  end
end
