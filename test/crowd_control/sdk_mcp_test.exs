defmodule CrowdControl.SdkMcpTest do
  use ExUnit.Case, async: true

  alias CrowdControl.SdkMcp

  doctest SdkMcp

  def echo(%{"text" => text}), do: {:ok, text}

  def blocks(_args),
    do: {:ok, [%{"type" => "text", "text" => "a"}, %{"type" => "text", "text" => "b"}]}

  def refuse(_args, reason), do: {:error, reason}
  def boom(_args), do: raise("tool bug")
  def junk(_args), do: :what

  defp server do
    SdkMcp.tool_server("app", [
      %{
        name: "echo",
        description: "Echo text",
        input_schema: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}},
        call: {__MODULE__, :echo, []},
        idempotent: true
      },
      %{name: "blocks", call: {__MODULE__, :blocks, []}},
      %{name: "refuse", call: {__MODULE__, :refuse, ["not today"]}},
      %{name: "boom", call: {__MODULE__, :boom, []}},
      %{name: "junk", call: {__MODULE__, :junk, []}}
    ])
  end

  defp call(name, arguments, id \\ 7) do
    SdkMcp.handle(server(), %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end

  describe "tool_server/2" do
    test "fills defaults" do
      assert %SdkMcp{name: "app", tools: [_ | _] = tools} = server()
      blocks = Enum.find(tools, &(&1.name == "blocks"))

      assert blocks.description == ""
      assert blocks.input_schema == %{"type" => "object", "properties" => %{}}
      assert blocks.idempotent == false
    end

    test "refuses a fun, a missing call and a duplicate name" do
      assert_raise ArgumentError, ~r/MFA/, fn ->
        SdkMcp.tool_server("app", [%{name: "t", call: fn _ -> :ok end}])
      end

      assert_raise ArgumentError, ~r/:call/, fn -> SdkMcp.tool_server("app", [%{name: "t"}]) end

      assert_raise ArgumentError, ~r/duplicate/, fn ->
        SdkMcp.tool_server("app", [
          %{name: "t", call: {__MODULE__, :echo, []}},
          %{name: "t", call: {__MODULE__, :echo, []}}
        ])
      end

      assert_raise ArgumentError, fn -> SdkMcp.tool_server("", []) end
    end
  end

  describe "handle/2" do
    test "initialize echoes the client's protocol version and names the server" do
      reply =
        SdkMcp.handle(server(), %{
          "jsonrpc" => "2.0",
          "id" => 0,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}
        })

      assert %{"jsonrpc" => "2.0", "id" => 0, "result" => result} = reply
      assert result["protocolVersion"] == "2025-03-26"
      assert result["serverInfo"] == %{"name" => "app", "version" => "1.0.0"}
      assert result["capabilities"] == %{"tools" => %{}}
    end

    test "a notification gets an empty acknowledgement" do
      assert SdkMcp.handle(server(), %{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             }) ==
               %{"jsonrpc" => "2.0", "result" => %{}}
    end

    test "ping" do
      assert %{"id" => 1, "result" => %{}} =
               SdkMcp.handle(server(), %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    end

    test "tools/list describes every tool in MCP's shape" do
      assert %{"id" => 2, "result" => %{"tools" => tools}} =
               SdkMcp.handle(server(), %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      assert Enum.map(tools, & &1["name"]) == ["echo", "blocks", "refuse", "boom", "junk"]

      assert %{"description" => "Echo text", "inputSchema" => %{"type" => "object"}} =
               hd(tools)
    end

    test "tools/call with a good tool name returns its content" do
      assert call("echo", %{"text" => "hi"}) == %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "result" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
             }

      assert %{"result" => %{"content" => [_, _]}} = call("blocks", %{})
    end

    test "a tool error is a result the model sees" do
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => "not today"}]}} =
               call("refuse", %{})
    end

    test "tools/call with a bad tool name is a JSON-RPC error" do
      assert %{"id" => 7, "error" => %{"code" => -32_602, "message" => message}} =
               call("nope", %{})

      assert message =~ "nope"
    end

    test "a crashing or misbehaving tool is -32603, and a crash is logged with its stacktrace" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{"error" => %{"code" => -32_603, "message" => "tool boom crashed"}} =
                   call("boom", %{})
        end)

      assert log =~ "SDK MCP tool boom crashed"
      assert log =~ "(RuntimeError) tool bug"
      assert log =~ "sdk_mcp_test.exs"

      assert %{"error" => %{"code" => -32_603}} = call("junk", %{})
    end

    test "an unknown method is -32601 and a malformed message -32600" do
      assert %{"id" => 9, "error" => %{"code" => -32_601}} =
               SdkMcp.handle(server(), %{
                 "jsonrpc" => "2.0",
                 "id" => 9,
                 "method" => "resources/list"
               })

      assert %{"error" => %{"code" => -32_600}} = SdkMcp.handle(server(), %{"id" => 1})
    end
  end

  test "idempotent?/2 is false only for a tools/call of a non-idempotent tool" do
    call = fn name -> %{"method" => "tools/call", "params" => %{"name" => name}} end

    assert SdkMcp.idempotent?(server(), call.("echo"))
    refute SdkMcp.idempotent?(server(), call.("blocks"))
    refute SdkMcp.idempotent?(server(), call.("missing"))
    assert SdkMcp.idempotent?(server(), %{"method" => "tools/list"})
  end
end
