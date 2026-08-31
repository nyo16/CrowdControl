defmodule Sandboxd.ApplicationTest do
  # Boots and stops the real application, so nothing else may be running.
  use ExUnit.Case, async: false

  @env ~w(CC_SANDBOXD_TOKEN CC_SANDBOXD_PORT CC_SANDBOXD_BIND CC_SANDBOXD_CAPTURE)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    dir = Path.join(System.tmp_dir!(), "sandboxd_app_#{:erlang.unique_integer([:positive])}")

    on_exit(fn ->
      Application.stop(:sandboxd)

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf(dir)
    end)

    Enum.each(@env, &System.delete_env/1)
    System.put_env("CC_SANDBOXD_CAPTURE", Path.join(dir, "out.jsonl"))
    System.put_env("CC_SANDBOXD_PORT", "0")

    {:ok, dir: dir}
  end

  describe "boot (blocker: an unauthenticated remote-exec endpoint)" do
    test "refuses to start without CC_SANDBOXD_TOKEN" do
      # Not a warning that degrades into an open endpoint: a hard failure.
      assert boot_error() =~ "CC_SANDBOXD_TOKEN is not set"
    end

    test "refuses to start with an empty CC_SANDBOXD_TOKEN" do
      System.put_env("CC_SANDBOXD_TOKEN", "")
      assert boot_error() =~ "CC_SANDBOXD_TOKEN is not set"
    end
  end

  describe "boot (happy path)" do
    setup do
      System.put_env("CC_SANDBOXD_TOKEN", "a-real-token")
      :ok
    end

    test "starts, serves an unauthenticated /v1/health, and requires the token elsewhere" do
      assert :ok = Application.start(:sandboxd)

      port = listening_port()

      assert {200, body} = get(port, "/v1/health")
      assert Jason.decode!(body) == %{"ok" => true}

      assert {401, ""} = get(port, "/v1/status")
      assert {200, status_body} = get(port, "/v1/status", "authorization: Bearer a-real-token")
      assert Jason.decode!(status_body)["started"] == false
    end

    test "creates the capture file's directory", %{dir: dir} do
      assert :ok = Application.start(:sandboxd)
      assert File.dir?(dir)
    end

    test "rejects a non-IP bind address" do
      System.put_env("CC_SANDBOXD_BIND", "0.0.0.0.0")
      assert boot_error() =~ "CC_SANDBOXD_BIND must be an IP address"
    end

    test "rejects a non-numeric port" do
      System.put_env("CC_SANDBOXD_PORT", "http")
      assert boot_error() =~ "CC_SANDBOXD_PORT must be an integer"
    end

    test "binds loopback by default, so the agent port is never routable by accident" do
      assert :ok = Application.start(:sandboxd)

      assert {:ok, {{127, 0, 0, 1}, _port}} =
               ThousandIsland.listener_info(bandit_listener())
    end

    test "CC_SANDBOXD_BIND widens the listener for the Docker provider's published port" do
      # A published port is forwarded from *outside* the container, so the agent
      # must listen on the container's own external interface for it to arrive.
      # Widening is explicit and per-provider; nothing here makes it routable.
      System.put_env("CC_SANDBOXD_BIND", "0.0.0.0")

      assert :ok = Application.start(:sandboxd)

      assert {:ok, {{0, 0, 0, 0}, _port}} =
               ThousandIsland.listener_info(bandit_listener())
    end
  end

  # Application.start/1 wraps a raise from start/2 as
  # {:error, {:bad_return, {{mod, :start, args}, {:EXIT, {exception, stack}}}}}.
  defp boot_error do
    assert {:error, {:bad_return, {_mfa, {:EXIT, {%RuntimeError{message: message}, _stack}}}}} =
             Application.start(:sandboxd)

    message
  end

  defp listening_port do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit_listener())
    port
  end

  defp bandit_listener do
    Supervisor.which_children(Sandboxd.Supervisor)
    |> Enum.find_value(fn
      {_, pid, :supervisor, [Bandit]} -> pid
      _ -> nil
    end)
    |> then(fn pid -> pid || raise "no Bandit listener under Sandboxd.Supervisor" end)
  end

  # A raw HTTP/1.1 request over :gen_tcp. :httpc would need :inets on Mix's code
  # path, and sandboxd deliberately ships no HTTP client to add it for.
  defp get(port, path, extra_header \\ nil) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    header = if extra_header, do: extra_header <> "\r\n", else: ""

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n#{header}\r\n"
      )

    response = recv_all(socket, "")
    :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _] = String.split(head, "\r\n")
    [_version, status, _reason] = String.split(status_line, " ", parts: 3)

    {String.to_integer(status), body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> raise "recv failed: #{inspect(reason)}"
    end
  end
end
