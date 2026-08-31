defmodule Sandboxd.AuthTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Sandboxd.Auth

  @token "an-hmac-derived-token_with-urlsafe-chars"

  setup do
    previous = Auth.token()
    Auth.put_token(@token)
    on_exit(fn -> Auth.put_token(previous) end)
    :ok
  end

  describe "bearer comparison (blocker: a forgeable or timing-leaked token)" do
    test "accepts the exact token" do
      refute call("Bearer " <> @token).halted
    end

    test "accepts a lowercase scheme, since HTTP schemes are case-insensitive" do
      refute call("bearer " <> @token).halted
    end

    test "accepts the token in x-cc-authorization, for proxied transports" do
      conn =
        conn(:get, "/v1/status")
        |> put_req_header("x-cc-authorization", "Bearer " <> @token)
        |> Auth.call([])

      refute conn.halted
    end

    test "rejects a wrong token" do
      assert %{status: 401, halted: true} = call("Bearer wrong-token")
    end

    test "rejects a token that is a prefix of the real one" do
      assert %{status: 401} = call("Bearer " <> binary_part(@token, 0, 10))
    end

    test "rejects a token that merely starts with the real one" do
      assert %{status: 401} = call("Bearer " <> @token <> "extra")
    end

    test "rejects a missing header" do
      assert %{status: 401} = Auth.call(conn(:get, "/v1/status"), [])
    end

    test "rejects a non-bearer scheme" do
      assert %{status: 401} = call("Basic #{Base.encode64("user:pass")}")
    end

    test "rejects a bare token with no scheme" do
      assert %{status: 401} = call(@token)
    end
  end

  describe "no configured token (blocker: an open remote-exec endpoint)" do
    test "rejects everything, including a request presenting no token" do
      Auth.put_token(nil)

      assert %{status: 401} = Auth.call(conn(:get, "/v1/status"), [])
      assert %{status: 401} = call("Bearer anything")
      assert %{status: 401} = call("Bearer ")
    end

    test "rejects everything when the token is empty rather than absent" do
      Auth.put_token("")

      assert %{status: 401} = call("Bearer ")
      assert %{status: 401} = call("Bearer x")
    end
  end

  describe "401 responses (blocker: an oracle for guessing the token)" do
    test "have an empty body, so no header tells an attacker which half is wrong" do
      for header <- ["Bearer wrong", "Basic abc", "Bearer "] do
        assert %{status: 401, resp_body: ""} = call(header)
      end

      assert %{status: 401, resp_body: ""} = Auth.call(conn(:get, "/v1/status"), [])
    end

    test "leak nothing about the expected token" do
      %{resp_body: body} = conn = call("Bearer wrong")
      refute body =~ @token
      refute inspect(conn.resp_headers) =~ @token
    end
  end

  defp call(header_value) do
    conn(:get, "/v1/status")
    |> put_req_header("authorization", header_value)
    |> Auth.call([])
  end
end
