defmodule Sandboxd.RouterTest do
  use Sandboxd.SandboxCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Sandboxd.Capture
  alias Sandboxd.Router

  @token "router-test-token"

  setup do
    previous = Sandboxd.Auth.token()
    Sandboxd.Auth.put_token(@token)
    on_exit(fn -> Sandboxd.Auth.put_token(previous) end)
    :ok
  end

  describe "GET /v1/health (blocker: a readiness probe that leaks state)" do
    test "needs no token, because a provider polls it before any token works" do
      conn = Router.call(conn(:get, "/v1/health"), [])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"ok" => true}
    end

    test "returns nothing but ok, even once a CLI is running and captured" do
      :ok = Capture.append("secrets-in-the-capture")

      conn = Router.call(conn(:get, "/v1/health"), [])

      body = conn.resp_body
      assert Jason.decode!(body) == %{"ok" => true}
      refute body =~ "bytes"
      refute body =~ "secrets"
      refute body =~ @token
    end
  end

  describe "authentication coverage (blocker: one unauthenticated route)" do
    test "every route except health is behind the token" do
      routes = [
        {:post, "/v1/exec"},
        {:post, "/v1/stdin"},
        {:get, "/v1/stream"},
        {:get, "/v1/status"},
        {:put, "/v1/files/tmp/x"},
        {:post, "/v1/shutdown"},
        {:get, "/v1/does-not-exist"}
      ]

      for {method, path} <- routes do
        conn = Router.call(conn(method, path), [])
        assert conn.status == 401, "#{method} #{path} answered #{conn.status}, not 401"
        assert conn.resp_body == ""
      end
    end

    test "auth runs before body parsing, so an unauthorized body is never decoded" do
      # A 400 here instead of a 401 would mean the parser saw the body first.
      conn =
        conn(:post, "/v1/exec", "not json at all")
        |> put_req_header("content-type", "application/json")
        |> Router.call([])

      assert conn.status == 401
    end
  end

  describe "POST /v1/exec (blocker: two processes behind one byte cursor)" do
    test "starts the CLI and answers ok" do
      assert %{status: 200} = post_json("/v1/exec", %{executable: "/bin/echo", args: ["hi"]})
      assert await_bytes(3) >= 3
    end

    test "a second exec is 409, not a second process" do
      assert %{status: 200} = post_json("/v1/exec", %{executable: "/bin/echo", args: ["one"]})

      conn = post_json("/v1/exec", %{executable: "/bin/echo", args: ["two"]})
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "already_executed"}
    end

    test "a second exec is still 409 after the first CLI has exited" do
      assert %{status: 200} = post_json("/v1/exec", %{executable: "/bin/echo", args: ["one"]})
      await_final()

      assert %{status: 409} = post_json("/v1/exec", %{executable: "/bin/echo", args: ["two"]})
    end

    test "rejects a missing or non-string executable" do
      assert %{status: 400} = post_json("/v1/exec", %{args: ["x"]})
      assert %{status: 400} = post_json("/v1/exec", %{executable: 42})
      assert %{status: 400} = post_json("/v1/exec", %{executable: ""})
    end

    test "rejects args that are not a list of strings" do
      assert %{status: 400} = post_json("/v1/exec", %{executable: "/bin/echo", args: "hi"})
      assert %{status: 400} = post_json("/v1/exec", %{executable: "/bin/echo", args: [1, 2]})
    end

    test "rejects env that is not an object of strings" do
      assert %{status: 400} = post_json("/v1/exec", %{executable: "/bin/echo", env: ["A=1"]})
      assert %{status: 400} = post_json("/v1/exec", %{executable: "/bin/echo", env: %{"A" => 1}})
    end
  end

  describe "POST /v1/stdin (blocker: a truncated or mangled prompt)" do
    test "409 before any exec, rather than silently dropping the write" do
      conn = post_json("/v1/stdin", %{data: Base.encode64("hello\n")})
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "not_started"}
    end

    test "rejects a non-base64 payload" do
      assert %{status: 400} = post_json("/v1/stdin", %{data: "not base64 !!!"})
      assert %{status: 400} = post_json("/v1/stdin", %{})
    end

    test "round-trips arbitrary bytes through the live CLI" do
      assert %{status: 200} = post_json("/v1/exec", %{executable: "/bin/cat", args: []})

      payload = <<0, 1, 2, 254, 255>> <> "and some text\n"
      assert %{status: 200} = post_json("/v1/stdin", %{data: Base.encode64(payload)})

      await_bytes(byte_size(payload))
      # wait_ms bounded: /bin/cat is still alive, so an unbounded stream would
      # sit on the default 25s idle wait after draining the bytes it asked for.
      assert Capture.stream(0, wait_ms: 50) |> Enum.join() =~ "and some text"
    end
  end

  describe "GET /v1/stream (blocker: a resume that duplicates a byte)" do
    test "serves the capture from a 0-indexed offset" do
      :ok = Capture.append("abcdefghij")
      :ok = Capture.finalize()

      assert stream_body("/v1/stream") == "abcdefghij"
      assert stream_body("/v1/stream?offset=0") == "abcdefghij"
      assert stream_body("/v1/stream?offset=3") == "defghij"
      assert stream_body("/v1/stream?offset=10") == ""
    end

    test "an offset past the end is empty, not an error" do
      :ok = Capture.append("abc")
      :ok = Capture.finalize()

      assert stream_body("/v1/stream?offset=999") == ""
    end

    test "rejects a negative or non-numeric offset" do
      assert %{status: 400} = get_authed("/v1/stream?offset=-1")
      assert %{status: 400} = get_authed("/v1/stream?offset=abc")
      assert %{status: 400} = get_authed("/v1/stream?offset=1.5")
    end

    test "ends the response when the CLI exits mid-stream" do
      assert %{status: 200} = post_json("/v1/exec", %{executable: "/bin/cat", args: []})

      task = Task.async(fn -> stream_body("/v1/stream") end)
      Process.sleep(50)

      assert %{status: 200} = post_json("/v1/stdin", %{data: Base.encode64("mid-stream\n")})
      await_bytes(11)
      # Killing the CLI finalizes the capture, which is what releases the
      # stream: without it the client parks on a process that can never write.
      :ok = Sandboxd.Exec.shutdown()

      assert Task.await(task, 5_000) =~ "mid-stream"
    end
  end

  describe "GET /v1/status (blocker: a client that spins instead of parking)" do
    test "reports the pre-exec state" do
      body = get_authed("/v1/status") |> json_body()

      assert body == %{"alive" => false, "exit_status" => nil, "bytes" => 0, "started" => false}
    end

    test "reports bytes and the exit status after the CLI finishes" do
      assert %{status: 200} = post_json("/v1/exec", %{executable: "/bin/echo", args: ["hey"]})
      await_final()

      body = get_authed("/v1/status") |> json_body()
      assert body["started"] == true
      assert body["alive"] == false
      assert body["exit_status"] == 0
      assert body["bytes"] == 4
    end

    test "a wait_ms long-poll returns the current status when it times out" do
      started = System.monotonic_time(:millisecond)
      body = get_authed("/v1/status?wait_ms=80") |> json_body()
      elapsed = System.monotonic_time(:millisecond) - started

      assert body["bytes"] == 0
      # Not alive, so it must not park at all: parking here would make a client
      # polling a finished sandbox pay the full wait on every request.
      assert elapsed < 80
    end

    test "a wait_ms long-poll returns as soon as new bytes arrive" do
      assert %{status: 200} = post_json("/v1/exec", %{executable: "/bin/cat", args: []})

      task = Task.async(fn -> get_authed("/v1/status?wait_ms=5000") |> json_body() end)
      Process.sleep(50)
      assert %{status: 200} = post_json("/v1/stdin", %{data: Base.encode64("woken\n")})

      body = Task.await(task, 3_000)
      assert body["bytes"] >= 6
    end

    test "rejects a wait_ms above the ceiling or non-numeric" do
      assert %{status: 400} = get_authed("/v1/status?wait_ms=600000")
      assert %{status: 400} = get_authed("/v1/status?wait_ms=soon")
      assert %{status: 400} = get_authed("/v1/status?wait_ms=-5")
    end
  end

  describe "PUT /v1/files (blocker: path traversal into the sandbox's own files)" do
    setup %{capture_dir: dir} do
      {:ok, target_dir: Path.join(dir, "files")}
    end

    test "writes the body at 0600 by default", %{target_dir: dir} do
      path = Path.join(dir, "config.yml")
      assert %{status: 200} = put_file(path, "provider: test\n")

      assert File.read!(path) == "provider: test\n"
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "honours an explicit octal mode", %{target_dir: dir} do
      path = Path.join(dir, "script.sh")
      assert %{status: 200} = put_file(path <> "?mode=0755", "#!/bin/sh\n")

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o755
    end

    test "creates intermediate directories", %{target_dir: dir} do
      path = Path.join([dir, "deep", "nested", "models.yml"])
      assert %{status: 200} = put_file(path, "x")

      assert File.exists?(path)
    end

    test "rejects .. segments rather than normalizing them" do
      # A caller with a legitimate absolute path never needs `..` to express it,
      # so this is refused, not helpfully resolved.
      for path <- ["/tmp/../etc/passwd", "/tmp/a/../../etc/passwd", "/../etc/passwd"] do
        conn = put_file(path, "pwned")
        assert conn.status == 400, "#{path} was not rejected"
        assert json_body(conn)["error"] =~ ".."
      end
    end

    test "rejects a single-dot segment" do
      assert %{status: 400} = put_file("/tmp/./x", "x")
    end

    test "rejects an empty path" do
      conn = conn(:put, "/v1/files") |> authorize() |> Router.call([])
      assert conn.status in [400, 404]
    end

    test "rejects a non-octal mode", %{target_dir: dir} do
      assert %{status: 400} = put_file(Path.join(dir, "x") <> "?mode=rwx", "x")
      assert %{status: 400} = put_file(Path.join(dir, "x") <> "?mode=999", "x")
      assert %{status: 400} = put_file(Path.join(dir, "x") <> "?mode=7777", "x")
    end

    test "safe_path/1 is the single gate, and it is total" do
      assert {:ok, "/tmp/x"} = Router.safe_path(["tmp", "x"])
      assert {:error, _} = Router.safe_path([])
      assert {:error, _} = Router.safe_path(["tmp", "..", "etc"])
      assert {:error, _} = Router.safe_path(["tmp", "."])
      assert {:error, _} = Router.safe_path(["tmp", "x\0y"])
    end
  end

  describe "unknown routes" do
    test "answer 404 once authenticated" do
      conn = get_authed("/v1/nope")
      assert conn.status == 404
      assert json_body(conn) == %{"error" => "not_found"}
    end
  end

  # --- Helpers ---

  defp authorize(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp post_json(path, payload) do
    conn(:post, path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> authorize()
    |> Router.call([])
  end

  defp get_authed(path) do
    conn(:get, path) |> authorize() |> Router.call([])
  end

  defp put_file(path, body) do
    conn(:put, "/v1/files" <> path, body)
    |> put_req_header("content-type", "application/octet-stream")
    |> authorize()
    |> Router.call([])
  end

  defp stream_body(path) do
    conn = get_authed(path)
    assert conn.status == 200
    conn.resp_body
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)
end
