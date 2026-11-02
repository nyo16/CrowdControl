defmodule CrowdControl.SessionControlTest do
  # Control-protocol mechanics driven through Backend.Mock, so every frame the
  # CLI "sends" is scripted and every frame the session writes is recorded:
  # the turn timer (A8), reattach recovery (A9) and SDK MCP answers (A10).
  use ExUnit.Case, async: true

  alias CrowdControl.Agent.ClaudeCode
  alias CrowdControl.Backend.Mock
  alias CrowdControl.{SdkMcp, Session, Store, TestHelpers}

  # --- callbacks: apply(m, f, [request, context | extra]) ---

  def defer(request, context, test) do
    send(test, {:asked, context.request_id, request})
    :defer
  end

  def allow(request, context, test) do
    send(test, {:asked, context.request_id, request})
    {:allow, request["input"]}
  end

  # Blocks until the test decides, like a callback waiting on a human.
  def block(_request, context, test) do
    send(test, {:asked, context.request_id, self()})

    receive do
      {:decide, decision} -> decision
    end
  end

  def hook(request, context, test) do
    send(test, {:hook, context.request_id, request["callback_id"]})
    {:ok, %{"continue" => true}}
  end

  def echo(%{"text" => text}, test) do
    send(test, {:tool_ran, text})
    {:ok, text}
  end

  def big(_args), do: {:ok, String.duplicate("x", 4_096)}

  # --- frames ---

  defp line(map), do: JSON.encode!(map) <> "\n"

  defp can_use_tool_frame(id, input \\ %{"command" => "ls"}) do
    %{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => "Bash",
        "input" => input,
        "tool_use_id" => "toolu_" <> id
      }
    }
  end

  defp mcp_frame(id, server, tool, args, jsonrpc_id \\ 3) do
    %{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{
        "subtype" => "mcp_message",
        "server_name" => server,
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => jsonrpc_id,
          "method" => "tools/call",
          "params" => %{"name" => tool, "arguments" => args}
        }
      }
    }
  end

  defp init_reply(pending) do
    line(%{
      "type" => "control_response",
      "response" => %{
        "subtype" => "success",
        "request_id" => ClaudeCode.init_request_id(),
        "response" => %{"session_state" => if(pending == [], do: "idle", else: "requires_action")},
        "pending_permission_requests" => pending,
        "pending_user_dialog_requests" => []
      }
    })
  end

  defp result_line(extra) do
    line(Map.merge(%{"type" => "result", "subtype" => "success", "is_error" => false}, extra))
  end

  # --- recorded writes ---

  defp decoded_writes(ctl), do: Enum.map(Mock.writes(ctl), &JSON.decode!/1)

  defp answers(ctl, id) do
    for %{"type" => "control_response", "response" => %{"request_id" => ^id} = r} <-
          decoded_writes(ctl),
        do: r["response"]
  end

  defp requests(ctl, subtype) do
    for %{"type" => "control_request", "request" => %{"subtype" => ^subtype}} = frame <-
          decoded_writes(ctl),
        do: frame
  end

  defp start(ctl, opts) do
    Session.start_link(Keyword.merge([backend: {Mock, mock: ctl}, executable: "claude"], opts))
  end

  defp unique_key, do: "ctl-" <> Store.new_key()

  describe "turn timer" do
    test "pauses while a permission request is pending and resumes with the remainder" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl,
          timeout: 400,
          interrupt_grace: 0,
          can_use_tool: {__MODULE__, :defer, [self()]}
        )

      Session.subscribe(pid)
      Process.sleep(100)
      Mock.push_events(ctl, [{:stdout_data, line(can_use_tool_frame("p1"))}])
      assert_receive {:asked, "p1", _}, 2_000

      state = :sys.get_state(pid)
      assert state.timeout_ref == nil
      remaining = state.control.paused_remaining_ms
      assert remaining > 0 and remaining < 400

      # Well past the whole 400 ms deadline: paused, so nothing fires.
      Process.sleep(500)
      refute_received {:crowd_control, ^pid, {:timeout, _}}
      assert Mock.destroy_count(ctl) == 0

      :ok = Session.respond(pid, "p1", {:allow, %{"command" => "ls"}})
      state = :sys.get_state(pid)
      assert state.control.paused_remaining_ms == nil
      left = Process.read_timer(state.timeout_ref)
      assert left <= remaining and left > remaining - 100

      assert_receive {:crowd_control, ^pid, {:timeout, :session_expired}}, remaining + 1_000
    end

    test "permission_timeout denies the request and never destroys" do
      ctl = start_supervised!({Mock, events: [{:stdout_data, line(can_use_tool_frame("p2"))}]})

      {:ok, pid} =
        start(ctl,
          timeout: 10_000,
          permission_timeout: 50,
          can_use_tool: {__MODULE__, :defer, [self()]}
        )

      TestHelpers.wait_until(fn -> answers(ctl, "p2") != [] end)

      assert [%{"behavior" => "deny", "message" => "permission timed out"}] = answers(ctl, "p2")
      assert {:ok, []} = Session.pending_requests(pid)
      assert Mock.destroy_count(ctl) == 0
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end

    test "a deadline interrupts first, and a result within the grace keeps the sandbox" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl,
          timeout: 100,
          interrupt_grace: 300,
          can_use_tool: {__MODULE__, :defer, [self()]}
        )

      Session.subscribe(pid)
      TestHelpers.wait_until(fn -> requests(ctl, "interrupt") != [] end)

      Mock.push_events(ctl, [{:stdout_data, result_line(%{"terminal_reason" => "aborted_tools"})}])

      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 1_000

      # Past the grace period: the result disarmed it.
      Process.sleep(500)
      refute_received {:crowd_control, ^pid, {:timeout, _}}
      assert Mock.destroy_count(ctl) == 0
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end

    test "a deadline with no result within the grace destroys" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl,
          timeout: 100,
          interrupt_grace: 100,
          can_use_tool: {__MODULE__, :defer, [self()]}
        )

      Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:timeout, :session_expired}}, 2_000
      assert [_interrupt] = requests(ctl, "interrupt")
      assert Mock.destroy_count(ctl) == 1
    end

    test "omp keeps destroying at the deadline" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        Session.start_link(
          backend: {Mock, mock: ctl},
          agent: :omp,
          executable: "omp",
          timeout: 100,
          interrupt_grace: 5_000
        )

      Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:timeout, :session_expired}}, 1_000
      assert requests(ctl, "interrupt") == []
    end
  end

  describe "reattach recovery" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "a persisted, unanswered request is re-surfaced exactly once, then answered" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl, timeout: 60_000, can_use_tool: {__MODULE__, :block, [self()]})

      key = :sys.get_state(pid).store_key
      Mock.push_events(ctl, [{:stdout_data, line(can_use_tool_frame("r1"))}])

      # The callback only runs after the request is on record.
      assert_receive {:asked, "r1", first_task}, 2_000
      assert {:ok, %{control: %{pending: %{{"r1", 0} => _}}}} = Store.get(key)

      # A crash: no terminate/2, so the record survives with the request in it.
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      Process.exit(first_task, :kill)
      {:ok, record} = Store.get(key)

      {:ok, pid} = Session.start_reattached(record)
      TestHelpers.wait_until(fn -> length(requests(ctl, "initialize")) == 2 end)

      # The CLI still holds it, so it is dispatched again -- once.
      Mock.push_events(ctl, [{:stdout_data, init_reply([can_use_tool_frame("r1")])}])
      assert_receive {:asked, "r1", second_task}, 2_000
      refute_receive {:asked, "r1", _}, 200

      send(second_task, {:decide, {:allow, %{"command" => "ls"}}})
      TestHelpers.wait_until(fn -> answers(ctl, "r1") != [] end)
      assert [%{"behavior" => "allow"}] = answers(ctl, "r1")
      assert {:ok, %{control: %{pending: pending}}} = Store.get(key)
      assert pending == %{}

      TestHelpers.stop_session(pid)
    end

    test "a request replayed from the capture (crash before persist) runs its callback once" do
      key = unique_key()
      ctl = start_supervised!({Mock, events: [{:stdout_data, line(can_use_tool_frame("r2"))}]})

      record =
        Store.build(
          key: key,
          backend: Mock,
          handle: Mock.handle(ctl, key),
          byte_offset: 0,
          buffer: "",
          opts: [
            agent: ClaudeCode,
            executable: "claude",
            timeout: 60_000,
            can_use_tool: {__MODULE__, :allow, [self()]}
          ]
        )

      {:ok, pid} = Session.start_reattached(record)

      # Permission requests wait for the CLI's own list before dispatching.
      TestHelpers.wait_until(fn -> map_size(:sys.get_state(pid).control.pending) == 1 end)
      refute_received {:asked, "r2", _}

      # The reply lists the same request: deduped by id, not dispatched twice.
      Mock.push_events(ctl, [{:stdout_data, init_reply([can_use_tool_frame("r2")])}])
      assert_receive {:asked, "r2", _}, 2_000
      refute_receive {:asked, "r2", _}, 200

      TestHelpers.wait_until(fn -> answers(ctl, "r2") != [] end)
      assert [_one] = answers(ctl, "r2")

      TestHelpers.stop_session(pid)
    end

    test "a persisted request the CLI no longer lists is withdrawn" do
      key = unique_key()
      ctl = start_supervised!({Mock, events: []})
      entry = %{subtype: "can_use_tool", request: can_use_tool_frame("gone")["request"]}

      record =
        Store.build(
          key: key,
          backend: Mock,
          handle: Mock.handle(ctl, key),
          opts: [
            executable: "claude",
            timeout: 60_000,
            can_use_tool: {__MODULE__, :defer, [self()]}
          ],
          control: %{
            pending: %{{"gone", 10} => Map.put(entry, :status, :deferred)},
            turn_deadline_at: nil,
            paused_remaining_ms: 30_000
          }
        )

      {:ok, pid} = Session.start_reattached(record)
      Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:control_request, "gone", "can_use_tool", _}}, 1_000

      Mock.push_events(ctl, [{:stdout_data, init_reply([])}])
      assert_receive {:crowd_control, ^pid, {:control_cancelled, "gone"}}, 2_000
      assert {:ok, []} = Session.pending_requests(pid)

      # Nothing blocks the turn any more, so the paused remainder runs again.
      state = :sys.get_state(pid)
      assert is_reference(state.timeout_ref)
      assert Process.read_timer(state.timeout_ref) <= 30_000

      TestHelpers.stop_session(pid)
    end

    test "persisted hooks are re-dispatched; MCP calls only when idempotent" do
      key = unique_key()
      ctl = start_supervised!({Mock, events: []})

      server =
        SdkMcp.tool_server("app", [
          %{name: "safe", call: {__MODULE__, :echo, [self()]}, idempotent: true},
          %{name: "unsafe", call: {__MODULE__, :echo, [self()]}}
        ])

      hook_request = %{"subtype" => "hook_callback", "callback_id" => "hook_PreToolUse_0_0"}
      safe = mcp_frame("m-safe", "app", "safe", %{"text" => "again"}, 4)["request"]
      unsafe = mcp_frame("m-unsafe", "app", "unsafe", %{"text" => "never"}, 5)["request"]

      record =
        Store.build(
          key: key,
          backend: Mock,
          handle: Mock.handle(ctl, key),
          opts: [
            executable: "claude",
            timeout: 60_000,
            hooks: %{"PreToolUse" => [%{hooks: [{__MODULE__, :hook, [self()]}]}]},
            sdk_mcp_servers: %{"app" => server}
          ],
          control: %{
            pending: %{
              {"h1", 0} => %{subtype: "hook_callback", request: hook_request, status: :dispatched},
              {"m-safe", 100} => %{subtype: "mcp_message", request: safe, status: :dispatched},
              {"m-unsafe", 200} => %{subtype: "mcp_message", request: unsafe, status: :received}
            },
            turn_deadline_at: nil,
            paused_remaining_ms: nil
          }
        )

      {:ok, pid} = Session.start_reattached(record)

      assert_receive {:hook, "h1", "hook_PreToolUse_0_0"}, 2_000
      assert_receive {:tool_ran, "again"}, 2_000
      refute_receive {:tool_ran, "never"}, 200

      TestHelpers.wait_until(fn -> answers(ctl, "m-unsafe") != [] end)

      assert [%{"mcp_response" => %{"id" => 5, "error" => error}}] = answers(ctl, "m-unsafe")
      assert error == %{"code" => -32_603, "message" => "host restarted; call state unknown"}
      assert [%{"mcp_response" => %{"id" => 4, "result" => _}}] = answers(ctl, "m-safe")
      assert [%{"continue" => true}] = answers(ctl, "h1")

      TestHelpers.stop_session(pid)
    end

    test "the turn deadline survives reattach instead of restarting" do
      key = unique_key()
      ctl = start_supervised!({Mock, events: []})

      record =
        Store.build(
          key: key,
          backend: Mock,
          handle: Mock.handle(ctl, key),
          opts: [executable: "claude", timeout: 60_000],
          control: %{
            pending: %{},
            turn_deadline_at: System.system_time(:millisecond) + 300,
            paused_remaining_ms: nil
          }
        )

      {:ok, pid} = Session.start_reattached(record)
      left = Process.read_timer(:sys.get_state(pid).timeout_ref)
      assert left > 0 and left <= 300

      TestHelpers.stop_session(pid)
    end
  end

  describe "CLI version gate" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    defp init_line(version) do
      line(%{
        "type" => "system",
        "subtype" => "init",
        "session_id" => "s",
        "claude_code_version" => version
      })
    end

    test "system/init below the minimum stops a control session with a typed error" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 10_000, can_use_tool: {__MODULE__, :defer, [self()]})
      Session.subscribe(pid)
      Mock.push_events(ctl, [{:stdout_data, init_line("2.1.200")}])

      assert_receive {:crowd_control, ^pid, {:error, {:cli_version, "2.1.200", "2.1.268"}}}, 2_000
      assert_receive {:EXIT, ^pid, :normal}, 2_000
      assert Mock.destroy_count(ctl) == 1
    end

    test "a session without control features does not care" do
      ctl = start_supervised!({Mock, events: [{:stdout_data, init_line("2.1.200")}]})
      {:ok, pid} = start(ctl, timeout: 10_000)
      Session.subscribe(pid)

      assert_receive {:crowd_control, ^pid, {:system_init, _}}, 2_000
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end

    test "a local CLI below the minimum fails the start, before spawning" do
      assert {:error, {:cli_version, "2.1.0", "2.1.268"}} =
               Session.start_link(
                 executable: TestHelpers.fake_control_cli_path(),
                 can_use_tool: {__MODULE__, :defer, [self()]},
                 env: %{"FAKE_CC_VERSION" => "2.1.0"}
               )
    end
  end

  describe "SDK MCP servers" do
    test "a tool call is answered with the server's mcp_response" do
      server = SdkMcp.tool_server("app", [%{name: "echo", call: {__MODULE__, :echo, [self()]}}])
      frame = mcp_frame("m1", "app", "echo", %{"text" => "hi"})
      ctl = start_supervised!({Mock, events: [{:stdout_data, line(frame)}]})

      {:ok, pid} = start(ctl, timeout: 10_000, sdk_mcp_servers: %{"app" => server})

      assert_receive {:tool_ran, "hi"}, 2_000
      TestHelpers.wait_until(fn -> answers(ctl, "m1") != [] end)

      assert [%{"mcp_response" => response}] = answers(ctl, "m1")

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 3,
               "result" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
             }

      TestHelpers.stop_session(pid)
    end

    test "an unknown server is a JSON-RPC error, not silence" do
      ctl =
        start_supervised!(
          {Mock, events: [{:stdout_data, line(mcp_frame("m2", "nope", "x", %{}))}]}
        )

      server = SdkMcp.tool_server("app", [])
      {:ok, pid} = start(ctl, timeout: 10_000, sdk_mcp_servers: %{"app" => server})

      TestHelpers.wait_until(fn -> answers(ctl, "m2") != [] end)
      assert [%{"mcp_response" => %{"error" => %{"code" => -32_601}}}] = answers(ctl, "m2")

      TestHelpers.stop_session(pid)
    end

    test "a response too large for the transport becomes a JSON-RPC error" do
      server = SdkMcp.tool_server("app", [%{name: "big", call: {__MODULE__, :big, []}}])
      frame = mcp_frame("m3", "app", "big", %{})

      ctl =
        start_supervised!({Mock, events: [{:stdout_data, line(frame)}], max_write_bytes: 1_024})

      {:ok, pid} = start(ctl, timeout: 10_000, sdk_mcp_servers: %{"app" => server})
      Session.subscribe(pid)

      TestHelpers.wait_until(fn -> length(answers(ctl, "m3")) == 2 end)

      # The refused full answer, then the error that replaced it.
      assert [%{"mcp_response" => %{"result" => _}}, %{"mcp_response" => fallback}] =
               answers(ctl, "m3")

      assert %{"id" => 3, "error" => %{"code" => -32_603}} = fallback
      refute_received {:crowd_control, ^pid, {:error, _}}

      TestHelpers.stop_session(pid)
    end

    test "the fake CLI's own MCP initialize and a tool call are both answered" do
      log = Path.join(System.tmp_dir!(), "cc-fake-mcp-#{Store.new_key()}.log")
      on_exit(fn -> File.rm(log) end)
      server = SdkMcp.tool_server("app", [%{name: "echo", call: {__MODULE__, :echo, [self()]}}])

      {:ok, pid} =
        Session.start_link(
          executable: TestHelpers.fake_control_cli_path(),
          timeout: 15_000,
          sdk_mcp_servers: %{"app" => server},
          env: %{"FAKE_CC_MODE" => "mcp", "FAKE_CC_LOG" => log}
        )

      Session.subscribe(pid)
      :ok = Session.send_prompt(pid, "use the tool")

      assert_receive {:crowd_control, ^pid, {:result, "success", result}}, 5_000
      assert_receive {:tool_ran, "hi"}

      assert %{"mcp_response" => %{"id" => 3, "result" => %{"content" => [%{"text" => "hi"}]}}} =
               JSON.decode!(result["result"])

      # The MCP handshake the CLI sent unprompted after `initialize` (id 0).
      written = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert Enum.any?(written, fn
               %{
                 "type" => "control_response",
                 "response" => %{"response" => %{"mcp_response" => r}}
               } ->
                 r["id"] == 0 and r["result"]["serverInfo"]["name"] == "app"

               _other ->
                 false
             end)

      TestHelpers.stop_session(pid)
    end
  end
end
