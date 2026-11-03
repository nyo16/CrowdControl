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

  def deny(_request, _context), do: {:deny, "no"}

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

  # What Mox and Ecto sandbox allowances look up from inside the callback.
  def report_callers(request, context, test) do
    send(test, {:callers, context.request_id, Process.get(:"$callers")})
    {:allow, request["input"]}
  end

  def echo(%{"text" => text}, test) do
    send(test, {:tool_ran, text})
    {:ok, text}
  end

  def big(_args), do: {:ok, String.duplicate("x", 4_096)}

  # An allow that also grants an allow rule for the tool, for the session.
  def allow_granting(request, context, test) do
    send(test, {:asked, context.request_id, request})
    rule = %{"type" => "addRules", "behavior" => "allow", "destination" => "session"}
    {:allow, request["input"], [Map.put(rule, "rules", [%{"toolName" => request["tool_name"]}])]}
  end

  # Decisions of the right shape that JSON cannot carry (W-1).
  def unencodable_input(_request, _context), do: {:allow, %{"x" => {:a, 1}}}
  def unencodable_perms(request, _context), do: {:allow, request["input"], [[type: "addRules"]]}
  def unencodable_hook(_request, _context), do: {:ok, %{"x" => {:a, 1}}}
  def tuple_tool(_args), do: {:ok, [%{"type" => "text", "text" => {:t}}]}

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

  # What Claude Code asks before it calls an SDK tool.
  defp mcp_permission_frame(id, server, tool, input) do
    %{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => "mcp__#{server}__#{tool}",
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

  # Callback extra_args are persisted, so a pid is refused there; callbacks
  # reach the test process by a registered name instead.
  defp me do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        name

      _unregistered ->
        name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
        Process.register(self(), name)
        name
    end
  end

  describe "turn timer" do
    test "pauses while a permission request is pending and resumes with the remainder" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl,
          timeout: 1_000,
          interrupt_grace: 0,
          can_use_tool: {__MODULE__, :defer, [me()]}
        )

      Session.subscribe(pid)
      Process.sleep(100)
      Mock.push_events(ctl, [{:stdout_data, line(can_use_tool_frame("p1"))}])
      assert_receive {:asked, "p1", _}, 2_000

      state = :sys.get_state(pid)
      assert state.timeout_ref == nil
      remaining = state.control.paused_remaining_ms
      assert remaining > 0 and remaining < 1_000

      # Well past the whole 1_000 ms deadline: paused, so nothing fires.
      Process.sleep(1_100)
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
          can_use_tool: {__MODULE__, :defer, [me()]}
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
          interrupt_grace: 2_000,
          can_use_tool: {__MODULE__, :defer, [me()]}
        )

      Session.subscribe(pid)
      TestHelpers.wait_until(fn -> requests(ctl, "interrupt") != [] end)

      Mock.push_events(ctl, [{:stdout_data, result_line(%{"terminal_reason" => "aborted_tools"})}])

      assert_receive {:crowd_control, ^pid, {:result, _, _}}, 1_000

      # Past the grace period: the result disarmed it.
      refute_receive {:crowd_control, ^pid, {:timeout, _}}, 2_200
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
          can_use_tool: {__MODULE__, :defer, [me()]}
        )

      Session.subscribe(pid)
      assert_receive {:crowd_control, ^pid, {:timeout, :session_expired}}, 2_000
      assert [_interrupt] = requests(ctl, "interrupt")
      assert Mock.destroy_count(ctl) == 1
    end

    test "a prompt accepted during the interrupt grace cancels the grace (G4)" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl,
          timeout: 100,
          interrupt_grace: 300,
          can_use_tool: {__MODULE__, :defer, [me()]}
        )

      Session.subscribe(pid)
      TestHelpers.wait_until(fn -> requests(ctl, "interrupt") != [] end)

      # A permission request is open, so the new turn starts paused: only the
      # old grace timer could still destroy the session.
      push(ctl, can_use_tool_frame("held"))
      assert_receive {:asked, "held", _}, 1_000
      :ok = Session.send_prompt(pid, "next")

      refute_receive {:crowd_control, ^pid, {:timeout, _}}, 600
      assert Mock.destroy_count(ctl) == 0

      TestHelpers.stop_session(pid)
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
      # expire/1 destroys before it broadcasts, so this cannot race.
      assert Mock.destroy_count(ctl) == 1
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
        start(ctl, timeout: 60_000, can_use_tool: {__MODULE__, :block, [me()]})

      key = :sys.get_state(pid).store_key
      Mock.push_events(ctl, [{:stdout_data, line(can_use_tool_frame("r1"))}])

      # The callback only runs after the request is on record.
      assert_receive {:asked, "r1", first_callback}, 2_000
      assert {:ok, %{control: %{pending: %{{"r1", 0} => _}}}} = Store.get(key)
      callback_ref = Process.monitor(first_callback)

      # A crash: no terminate/2, so the record survives with the request in it.
      # The blocked callback dies with its session, so after reattach only the
      # second copy can answer (W-2).
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      assert_receive {:DOWN, ^callback_ref, :process, ^first_callback, :killed}, 2_000
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
            can_use_tool: {__MODULE__, :allow, [me()]}
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

    # The captured request waits for the CLI's list; each fallback lets the
    # persisted set stand, so it is dispatched rather than withdrawn.
    defp reattach_with_captured_request(id, extra_opts \\ []) do
      key = unique_key()
      ctl = start_supervised!({Mock, events: [{:stdout_data, line(can_use_tool_frame(id))}]})

      record =
        Store.build(
          key: key,
          backend: Mock,
          handle: Mock.handle(ctl, key),
          byte_offset: 0,
          buffer: "",
          opts:
            [
              agent: ClaudeCode,
              executable: "claude",
              timeout: 60_000,
              can_use_tool: {__MODULE__, :allow, [me()]}
            ] ++ extra_opts
        )

      {:ok, pid} = Session.start_reattached(record)
      TestHelpers.wait_until(fn -> map_size(:sys.get_state(pid).control.pending) == 1 end)
      refute_received {:asked, ^id, _}
      {ctl, pid}
    end

    defp assert_persisted_set_stands(ctl, pid, id) do
      assert_receive {:asked, ^id, _}, 2_000
      TestHelpers.wait_until(fn -> answers(ctl, id) != [] end)
      assert [%{"behavior" => "allow"}] = answers(ctl, id)
      refute :sys.get_state(pid).control.reconciling
      TestHelpers.stop_session(pid)
    end

    test "an initialize error after reattach keeps the persisted requests" do
      {ctl, pid} = reattach_with_captured_request("f1")

      Mock.push_events(ctl, [
        {:stdout_data,
         line(%{
           "type" => "control_response",
           "response" => %{
             "subtype" => "error",
             "request_id" => ClaudeCode.init_request_id(),
             "error" => "boom"
           }
         })}
      ])

      assert_persisted_set_stands(ctl, pid, "f1")
    end

    test "an initialize reply without pending_permission_requests keeps the persisted requests" do
      {ctl, pid} = reattach_with_captured_request("f2")

      Mock.push_events(ctl, [
        {:stdout_data,
         line(%{
           "type" => "control_response",
           "response" => %{
             "subtype" => "success",
             "request_id" => ClaudeCode.init_request_id(),
             "response" => %{"session_state" => "idle"}
           }
         })}
      ])

      assert_persisted_set_stands(ctl, pid, "f2")
    end

    test "no initialize reply after reattach falls back to the persisted requests" do
      {ctl, pid} = reattach_with_captured_request("f3", reattach_reply_timeout: 200)
      assert_persisted_set_stands(ctl, pid, "f3")
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
            can_use_tool: {__MODULE__, :defer, [me()]}
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
          %{name: "safe", call: {__MODULE__, :echo, [me()]}, idempotent: true},
          %{name: "unsafe", call: {__MODULE__, :echo, [me()]}}
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
            hooks: %{"PreToolUse" => [%{hooks: [{__MODULE__, :hook, [me()]}]}]},
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
            turn_deadline_at: System.system_time(:millisecond) + 5_000,
            paused_remaining_ms: nil
          }
        )

      {:ok, pid} = Session.start_reattached(record)
      left = Process.read_timer(:sys.get_state(pid).timeout_ref)
      # Far below a 60_000 restart, and an integer: `false` would mean it fired.
      assert is_integer(left) and left > 0 and left <= 5_000

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
      {:ok, pid} = start(ctl, timeout: 10_000, can_use_tool: {__MODULE__, :defer, [me()]})
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
                 can_use_tool: {__MODULE__, :defer, [me()]},
                 env: %{"FAKE_CC_VERSION" => "2.1.0"}
               )
    end

    test "exactly the minimum passes, at start and at system/init" do
      {:ok, local} =
        Session.start_link(
          executable: TestHelpers.fake_control_cli_path(),
          can_use_tool: {__MODULE__, :defer, [me()]},
          env: %{"FAKE_CC_VERSION" => CrowdControl.CLI.min_version()}
        )

      TestHelpers.stop_session(local)

      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 10_000, can_use_tool: {__MODULE__, :defer, [me()]})
      Session.subscribe(pid)
      Mock.push_events(ctl, [{:stdout_data, init_line("2.1.268")}])

      assert_receive {:crowd_control, ^pid, {:system_init, _}}, 2_000
      refute_received {:crowd_control, ^pid, {:error, _}}
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end

    test "a pre-release of the minimum is below it" do
      assert CrowdControl.CLI.min_version() == "2.1.268"

      assert {:error, {:cli_version, "2.1.268-beta.1", "2.1.268"}} =
               Session.start_link(
                 executable: TestHelpers.fake_control_cli_path(),
                 can_use_tool: {__MODULE__, :defer, [me()]},
                 env: %{"FAKE_CC_VERSION" => "2.1.268-beta.1"}
               )
    end

    test "an unparsable version passes the gate with a warning (D8)" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, local} =
            Session.start_link(
              executable: TestHelpers.fake_control_cli_path(),
              can_use_tool: {__MODULE__, :defer, [me()]},
              env: %{"FAKE_CC_VERSION" => "garbage"}
            )

          TestHelpers.stop_session(local)
        end)

      assert log =~ "Could not read the Claude Code version"

      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 10_000, can_use_tool: {__MODULE__, :defer, [me()]})
      Session.subscribe(pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Mock.push_events(ctl, [{:stdout_data, init_line("not.a.version")}])
          assert_receive {:crowd_control, ^pid, {:system_init, _}}, 2_000
          # The warning is logged before the broadcast, in the session process.
          :sys.get_state(pid)
        end)

      assert log =~ ~s(Unparsable Claude Code version "not.a.version")
      refute_received {:crowd_control, ^pid, {:error, _}}
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end
  end

  describe "SDK MCP servers" do
    test "a tool call is answered with the server's mcp_response" do
      server = SdkMcp.tool_server("app", [%{name: "echo", call: {__MODULE__, :echo, [me()]}}])
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

      TestHelpers.wait_until(fn -> answers(ctl, "m3") != [] end)

      # The full answer was refused (one :write call never recorded); only the
      # error that replaced it reached the CLI.
      assert [%{"mcp_response" => fallback}] = answers(ctl, "m3")
      assert Enum.count(Mock.calls(ctl), &(&1 == :write)) == length(Mock.writes(ctl)) + 1

      assert %{"id" => 3, "error" => %{"code" => -32_603}} = fallback
      refute_received {:crowd_control, ^pid, {:error, _}}

      TestHelpers.stop_session(pid)
    end

    test "the fake CLI's own MCP initialize and a tool call are both answered" do
      log = Path.join(System.tmp_dir!(), "cc-fake-mcp-#{Store.new_key()}.log")
      on_exit(fn -> File.rm(log) end)
      server = SdkMcp.tool_server("app", [%{name: "echo", call: {__MODULE__, :echo, [me()]}}])

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

  describe "what the store keeps" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    defp init_line do
      line(%{"type" => "system", "subtype" => "init", "session_id" => "s"})
    end

    defp hook_frame(id) do
      %{
        "type" => "control_request",
        "request_id" => id,
        "request" => %{
          "subtype" => "hook_callback",
          "callback_id" => "hook_PreToolUse_0_0",
          "input" => %{"hook_event_name" => "PreToolUse"}
        }
      }
    end

    test "no credential, service env or file content reaches the record (B-1)" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        Session.start_link(
          executable: "claude",
          timeout: 60_000,
          backend:
            {Mock,
             mock: ctl,
             api_key: "k-secret",
             session_token: "ccst_x-secret",
             services: [
               %{
                 name: "b",
                 image: "browser:dev",
                 env: %{"T" => "s-secret"},
                 files: [%{path: "/etc/b.conf", content: "file-secret"}]
               }
             ],
             provider: {CrowdControl.FakeProvider, api_key: "p-secret", region: "eu"}}
        )

      key = :sys.get_state(pid).store_key
      Mock.push_events(ctl, [{:stdout_data, init_line()}])
      TestHelpers.wait_until(fn -> match?({:ok, %{session_id: "s"}}, Store.get(key)) end)

      {:ok, record} = Store.get(key)
      stored = :erlang.term_to_binary(record)

      for secret <- ~w(k-secret ccst_x-secret s-secret file-secret p-secret) do
        assert :binary.match(stored, secret) == :nomatch, "#{secret} reached the store"
      end

      # Everything else survives: a reattach rebuilds the session from it.
      assert {Mock, config} = record.opts[:backend]
      assert config[:mock] == ctl
      assert [%{name: "b", image: "browser:dev"} = service] = config[:services]
      refute Map.has_key?(service, :env) or Map.has_key?(service, :files)
      assert config[:provider] == {CrowdControl.FakeProvider, region: "eu"}

      TestHelpers.stop_session(pid)
    end

    test "control opts given inside backend: survive reattach (W-3)" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        Session.start_link(
          executable: "claude",
          timeout: 60_000,
          backend:
            {Mock,
             mock: ctl,
             api_key: "k-secret",
             hooks: %{"PreToolUse" => [%{hooks: [{__MODULE__, :hook, [me()]}]}]}}
        )

      key = :sys.get_state(pid).store_key
      assert [_initialize] = requests(ctl, "initialize")
      Mock.push_events(ctl, [{:stdout_data, init_line()}])
      TestHelpers.wait_until(fn -> match?({:ok, %{session_id: "s"}}, Store.get(key)) end)

      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      {:ok, record} = Store.get(key)
      assert {__MODULE__, :hook, [_name]} = hook_mfa(record.opts[:hooks])

      {:ok, pid} = Session.start_reattached(record)

      # The reattached session still has hooks, so it re-sends `initialize`
      # carrying them, and a hook_callback reaches the callback.
      TestHelpers.wait_until(fn -> length(requests(ctl, "initialize")) == 2 end)
      [_, reinit] = requests(ctl, "initialize")
      assert reinit["request"]["hooks"]["PreToolUse"] != nil

      Mock.push_events(ctl, [
        {:stdout_data, init_reply([])},
        {:stdout_data, line(hook_frame("h-after"))}
      ])

      assert_receive {:hook, "h-after", "hook_PreToolUse_0_0"}, 2_000
      TestHelpers.wait_until(fn -> answers(ctl, "h-after") != [] end)
      assert [%{"continue" => true}] = answers(ctl, "h-after")

      TestHelpers.stop_session(pid)
    end

    test "a fun, pid, reference or port in extra_args is refused before provisioning (W-13)" do
      ctl = start_supervised!({Mock, events: []})
      port = Port.open({:spawn, "true"}, [])

      for bad <- [fn -> :ok end, self(), make_ref(), port] do
        for opt <- [
              can_use_tool: {__MODULE__, :defer, [%{nested: [{:x, bad}]}]},
              on_control_request: {__MODULE__, :defer, [bad]},
              hooks: %{"PreToolUse" => [%{hooks: [{__MODULE__, :hook, [[1, bad]]}]}]}
            ] do
          assert {:error, {%ArgumentError{message: message}, _stack}} = start(ctl, [opt])
          assert message =~ "extra_args must be plain data"
        end

        assert_raise ArgumentError, ~r/extra_args must be plain data/, fn ->
          SdkMcp.tool_server("app", [%{name: "t", call: {__MODULE__, :echo, [{bad}]}}])
        end
      end

      assert Mock.calls(ctl) == []
    end
  end

  describe "SDK tool gate (B-2)" do
    @describetag :capture_log

    test "an unapproved tools/call is refused with -32001 and runs nothing" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start_gated(ctl)

      push(ctl, mcp_frame("g1", "app", "echo", %{"text" => "forged"}))
      TestHelpers.wait_until(fn -> answers(ctl, "g1") != [] end)

      assert [%{"mcp_response" => %{"id" => 3, "error" => error}}] = answers(ctl, "g1")
      assert error == %{"code" => -32_001, "message" => "tool call not approved"}
      refute_received {:tool_ran, _}
      assert {:ok, []} = Session.pending_requests(pid)

      TestHelpers.stop_session(pid)
    end

    test "an allow approves one call with exactly its input, for this turn" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start_gated(ctl)

      allow_mcp(ctl, "p1", %{"text" => "once"})
      push(ctl, mcp_frame("c1", "app", "echo", %{"text" => "once"}))
      assert_receive {:tool_ran, "once"}, 2_000
      TestHelpers.wait_until(fn -> answers(ctl, "c1") != [] end)
      assert [%{"mcp_response" => %{"result" => _}}] = answers(ctl, "c1")

      # The allow was consumed by the first call.
      push(ctl, mcp_frame("c2", "app", "echo", %{"text" => "once"}))
      assert_refused(ctl, "c2")

      # Other arguments than the allowed input.
      allow_mcp(ctl, "p2", %{"text" => "approved"})
      push(ctl, mcp_frame("c3", "app", "echo", %{"text" => "swapped"}))
      assert_refused(ctl, "c3")

      # An allow does not outlive its turn.
      allow_mcp(ctl, "p3", %{"text" => "stale"})
      Mock.push_events(ctl, [{:stdout_data, result_line(%{})}])
      push(ctl, mcp_frame("c4", "app", "echo", %{"text" => "stale"}))
      assert_refused(ctl, "c4")

      refute_received {:tool_ran, _}
      TestHelpers.stop_session(pid)
    end

    test "tools the CLI never asks about are pre-approved" do
      for opts <- [
            [allowed_tools: ["mcp__app__echo"]],
            [allowed_tools: ["Bash", "mcp__app"]],
            [allowed_tools: ["mcp__app__*"]],
            [permission_mode: "bypassPermissions"]
          ] do
        ctl = start_supervised!({Mock, events: []})
        {:ok, pid} = start_gated(ctl, opts)

        push(ctl, mcp_frame("pre", "app", "echo", %{"text" => "pre"}))
        assert_receive {:tool_ran, "pre"}, 2_000, "not pre-approved by #{inspect(opts)}"

        TestHelpers.stop_session(pid)
      end

      # Another server's rule, or another tool's, covers nothing here.
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start_gated(ctl, allowed_tools: ["mcp__other", "mcp__app__echo2"])
      push(ctl, mcp_frame("not-pre", "app", "echo", %{"text" => "no"}))
      assert_refused(ctl, "not-pre")
      TestHelpers.stop_session(pid)
    end

    test "an addRules allow pre-approves the tool for the rest of the session" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start_gated(ctl, can_use_tool: {__MODULE__, :allow_granting, [me()]})
      key = :sys.get_state(pid).store_key

      allow_mcp(ctl, "grant", %{"text" => "first"})
      assert [%{"updatedPermissions" => [%{"type" => "addRules"}]}] = answers(ctl, "grant")
      Mock.push_events(ctl, [{:stdout_data, result_line(%{})}])

      # A later turn, other arguments, more than once: the CLI no longer asks.
      for {id, text} <- [{"r1", "a"}, {"r2", "b"}] do
        push(ctl, mcp_frame(id, "app", "echo", %{"text" => text}))
        assert_receive {:tool_ran, ^text}, 2_000
      end

      # The grant is persisted: a reattached session still honours it.
      {:ok, %{control: %{gate: gate}}} = Store.get(key)
      assert MapSet.member?(gate.granted_tools, "mcp__app__echo")

      TestHelpers.stop_session(pid)
    end

    test "an acknowledged set_permission_mode to bypassPermissions pre-approves" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start_gated(ctl)

      task = Task.async(fn -> Session.set_permission_mode(pid, "bypassPermissions") end)
      TestHelpers.wait_until(fn -> requests(ctl, "set_permission_mode") != [] end)
      [%{"request_id" => id}] = requests(ctl, "set_permission_mode")

      push(ctl, %{
        "type" => "control_response",
        "response" => %{"subtype" => "success", "request_id" => id, "response" => %{}}
      })

      assert {:ok, %{}} = Task.await(task)

      push(ctl, mcp_frame("bypass", "app", "echo", %{"text" => "bypass"}))
      assert_receive {:tool_ran, "bypass"}, 2_000

      TestHelpers.stop_session(pid)
    end

    test "the fake CLI asks for mcp__<server>__<tool> and calls it only after an allow" do
      for {callback, ran?} <- [
            {{__MODULE__, :allow, [me()]}, true},
            {{__MODULE__, :deny, []}, false}
          ] do
        {:ok, pid} =
          Session.start_link(
            executable: TestHelpers.fake_control_cli_path(),
            timeout: 15_000,
            can_use_tool: callback,
            sdk_mcp_servers: %{"app" => echo_server()},
            env: %{"FAKE_CC_MODE" => "mcp_permission"}
          )

        Session.subscribe(pid)
        :ok = Session.send_prompt(pid, "use the tool")
        assert_receive {:crowd_control, ^pid, {:result, "success", result}}, 5_000

        if ran? do
          assert_receive {:asked, _id, %{"tool_name" => "mcp__app__echo"}}
          assert_receive {:tool_ran, "hi"}

          assert %{"mcp_response" => %{"result" => %{"content" => [%{"text" => "hi"}]}}} =
                   JSON.decode!(result["result"])
        else
          assert result["result"] == "denied: no"
          refute_received {:tool_ran, _}
        end

        TestHelpers.stop_session(pid)
      end
    end
  end

  describe "pending-request cap (B-2)" do
    @describetag :capture_log

    test "past max_pending_control a request is answered at once and never kept" do
      server = SdkMcp.tool_server("app", [%{name: "echo", call: {__MODULE__, :echo, [me()]}}])
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl,
          timeout: 10_000,
          max_pending_control: 1,
          can_use_tool: {__MODULE__, :defer, [me()]},
          sdk_mcp_servers: %{"app" => server},
          hooks: %{"PreToolUse" => [%{hooks: [{__MODULE__, :hook, [me()]}]}]}
        )

      push(ctl, can_use_tool_frame("k1"))
      assert_receive {:asked, "k1", _}, 2_000

      push(ctl, can_use_tool_frame("k2"))
      push(ctl, mcp_frame("k3", "app", "echo", %{"text" => "over"}, 9))
      push(ctl, hook_frame("k4"))
      TestHelpers.wait_until(fn -> responses(ctl, "k4") != [] end)

      assert [%{"behavior" => "deny", "message" => "too many pending control requests"}] =
               answers(ctl, "k2")

      assert [%{"mcp_response" => %{"id" => 9, "error" => %{"code" => -32_603}}}] =
               answers(ctl, "k3")

      assert [%{"subtype" => "error", "error" => "too many pending control requests"}] =
               responses(ctl, "k4")

      refute_received {:asked, "k2", _}
      refute_received {:tool_ran, _}
      refute_received {:hook, "k4", _}

      assert {:ok, [%{request_id: "k1"}]} = Session.pending_requests(pid)
      {:ok, %{control: %{pending: pending}}} = Store.get(:sys.get_state(pid).store_key)
      assert [{"k1", _offset}] = Map.keys(pending)

      TestHelpers.stop_session(pid)
    end

    test "a flood of 1,000 forged requests leaves at most 64 pending, logged once" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 10_000, can_use_tool: {__MODULE__, :defer, [me()]})
      flood = Enum.map_join(1..1_000, &line(can_use_tool_frame("f#{&1}")))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Mock.push_events(ctl, [{:stdout_data, flood}])
          TestHelpers.wait_until(fn -> length(Mock.writes(ctl)) >= 1 + 936 end)
          :sys.get_state(pid)
        end)

      assert {:ok, pending} = Session.pending_requests(pid)
      assert length(pending) == 64
      assert map_size(:sys.get_state(pid).control.pending) == 64

      denied = for id <- 65..1_000, do: answers(ctl, "f#{id}")
      assert Enum.all?(denied, &match?([%{"behavior" => "deny"}], &1))
      assert length(Regex.scan(~r/refusing more this turn/, log)) == 1
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end
  end

  describe "answers JSON cannot carry (W-1)" do
    @describetag :capture_log

    test "an unencodable permission decision becomes a deny and the session lives" do
      for callback <- [:unencodable_input, :unencodable_perms] do
        ctl = start_supervised!({Mock, events: []})
        {:ok, pid} = start(ctl, timeout: 10_000, can_use_tool: {__MODULE__, callback, []})

        push(ctl, can_use_tool_frame("u1"))
        TestHelpers.wait_until(fn -> answers(ctl, "u1") != [] end)

        assert [%{"behavior" => "deny", "message" => "unencodable decision"}] = answers(ctl, "u1")
        assert Process.alive?(pid)
        assert Mock.destroy_count(ctl) == 0

        TestHelpers.stop_session(pid)
      end
    end

    test "an unencodable hook output becomes an error response" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl,
          timeout: 10_000,
          hooks: %{"PreToolUse" => [%{hooks: [{__MODULE__, :unencodable_hook, []}]}]}
        )

      push(ctl, hook_frame("u2"))
      TestHelpers.wait_until(fn -> responses(ctl, "u2") != [] end)

      assert [%{"subtype" => "error", "error" => "unencodable decision"}] = responses(ctl, "u2")
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end

    test "an SDK tool returning a tuple becomes a JSON-RPC error" do
      server = SdkMcp.tool_server("app", [%{name: "tuple", call: {__MODULE__, :tuple_tool, []}}])
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 10_000, sdk_mcp_servers: %{"app" => server})

      push(ctl, mcp_frame("u3", "app", "tuple", %{}))
      TestHelpers.wait_until(fn -> answers(ctl, "u3") != [] end)

      assert [%{"mcp_response" => %{"id" => 3, "error" => error}}] = answers(ctl, "u3")
      assert error == %{"code" => -32_603, "message" => "tool returned an unencodable result"}
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end

    test "respond/3 with an unencodable decision is refused and leaves the request open" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 10_000, can_use_tool: {__MODULE__, :defer, [me()]})

      push(ctl, can_use_tool_frame("u4"))
      assert_receive {:asked, "u4", _}, 2_000

      bad = {:allow, %{"pid" => self()}}
      assert {:error, {:invalid_decision, ^bad}} = Session.respond(pid, "u4", bad)
      assert answers(ctl, "u4") == []
      assert {:ok, [%{request_id: "u4", status: :deferred}]} = Session.pending_requests(pid)

      assert :ok = Session.respond(pid, "u4", {:allow, %{"command" => "ls"}})
      assert [%{"behavior" => "allow"}] = answers(ctl, "u4")
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end

    test "a host control request JSON cannot carry is refused, not a crash" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 10_000, can_use_tool: {__MODULE__, :defer, [me()]})

      request = %{"subtype" => "set_model", "model" => {:not, :json}}
      assert {:error, {:invalid_request, ^request}} = Session.control(pid, request)
      assert Process.alive?(pid)

      TestHelpers.stop_session(pid)
    end
  end

  describe "callback lifetime (W-2, G6)" do
    test "a callback blocked when its session is killed dies with it" do
      Process.flag(:trap_exit, true)
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 60_000, can_use_tool: {__MODULE__, :block, [me()]})

      push(ctl, can_use_tool_frame("w2"))
      assert_receive {:asked, "w2", callback}, 2_000
      ref = Process.monitor(callback)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^callback, :killed}, 2_000
    end

    test "respond/3 racing a running callback: the first answer wins" do
      ctl = start_supervised!({Mock, events: []})
      {:ok, pid} = start(ctl, timeout: 60_000, can_use_tool: {__MODULE__, :block, [me()]})

      # respond/3 first: the still-running callback is cancelled, so its
      # answer can never land.
      push(ctl, can_use_tool_frame("race1"))
      assert_receive {:asked, "race1", callback}, 2_000
      ref = Process.monitor(callback)
      assert :ok = Session.respond(pid, "race1", {:deny, "a human said no"})
      assert_receive {:DOWN, ^ref, :process, ^callback, _reason}, 2_000
      assert [%{"behavior" => "deny", "message" => "a human said no"}] = answers(ctl, "race1")

      # The callback first: the late respond/3 is a no-op.
      push(ctl, can_use_tool_frame("race2"))
      assert_receive {:asked, "race2", callback}, 2_000
      send(callback, {:decide, {:allow, %{"command" => "ls"}}})
      TestHelpers.wait_until(fn -> answers(ctl, "race2") != [] end)
      assert :ok = Session.respond(pid, "race2", {:deny, "too late"})
      assert [%{"behavior" => "allow"}] = answers(ctl, "race2")

      TestHelpers.stop_session(pid)
    end

    test "a callback runs with the session in its $callers (S-A1)" do
      ctl = start_supervised!({Mock, events: []})

      {:ok, pid} =
        start(ctl, timeout: 60_000, can_use_tool: {__MODULE__, :report_callers, [me()]})

      push(ctl, can_use_tool_frame("callers"))
      assert_receive {:callers, "callers", callers}, 2_000
      assert [_task, ^pid | _] = callers

      TestHelpers.stop_session(pid)
    end
  end

  describe "teardown budget (B-3)" do
    # A Kubernetes destroy can wait out Pod termination graces; stop/1 used to
    # give up after 10 s while the destroy carried on inside the session.
    @tag timeout: 30_000
    test "stop/1 waits for a destroy slower than the old 10 s call timeout" do
      ctl = start_supervised!({Mock, events: [], destroy_delay: 10_500})
      {:ok, pid} = start(ctl, timeout: 60_000)
      ref = Process.monitor(pid)

      {elapsed_us, result} = :timer.tc(fn -> Session.stop(pid) end)

      assert result == :ok
      assert elapsed_us >= 10_500_000
      assert Mock.destroy_count(ctl) == 1
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  defp push(ctl, frame), do: Mock.push_events(ctl, [{:stdout_data, line(frame)}])

  defp echo_server,
    do: SdkMcp.tool_server("app", [%{name: "echo", call: {__MODULE__, :echo, [me()]}}])

  defp start_gated(ctl, opts \\ []) do
    start(
      ctl,
      Keyword.merge(
        [
          timeout: 10_000,
          can_use_tool: {__MODULE__, :allow, [me()]},
          sdk_mcp_servers: %{"app" => echo_server()}
        ],
        opts
      )
    )
  end

  # The CLI asks about the SDK tool and the callback allows `input`.
  defp allow_mcp(ctl, id, input) do
    push(ctl, mcp_permission_frame(id, "app", "echo", input))
    assert_receive {:asked, ^id, %{"tool_name" => "mcp__app__echo"}}, 2_000
    TestHelpers.wait_until(fn -> answers(ctl, id) != [] end)
  end

  defp assert_refused(ctl, id) do
    TestHelpers.wait_until(fn -> answers(ctl, id) != [] end)
    assert [%{"mcp_response" => %{"error" => %{"code" => -32_001}}}] = answers(ctl, id)
  end

  # Every control_response for `id`, success or error.
  defp responses(ctl, id) do
    for %{"type" => "control_response", "response" => %{"request_id" => ^id} = r} <-
          decoded_writes(ctl),
        do: r
  end

  defp hook_mfa(%{"PreToolUse" => [%{hooks: [mfa]}]}), do: mfa
end
