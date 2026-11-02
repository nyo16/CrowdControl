defmodule CrowdControl.TelemetryTest do
  # async: false -- :telemetry handlers are global, so a handler attached here
  # would also see events from any test running alongside. Events are still
  # matched on this test's own store_key, for the same reason.
  use ExUnit.Case, async: false

  alias CrowdControl.Backend.Mock
  alias CrowdControl.{SdkMcp, Session, TestHelpers}

  @events [
    [:crowd_control, :session, :start],
    [:crowd_control, :session, :stop],
    [:crowd_control, :session, :exception],
    [:crowd_control, :turn, :start],
    [:crowd_control, :turn, :stop],
    [:crowd_control, :backend, :provision, :start],
    [:crowd_control, :backend, :provision, :stop],
    [:crowd_control, :backend, :provision, :exception],
    [:crowd_control, :control, :decision]
  ]

  setup do
    id = "telemetry-test-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, @events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  def forward(event, measurements, metadata, test),
    do: send(test, {:event, event, measurements, metadata})

  def defer(_request, _context), do: :defer
  def allow(request, _context), do: {:allow, request["input"]}
  def echo(_args), do: {:ok, "ran"}

  defp line(map), do: JSON.encode!(map) <> "\n"

  defp result(subtype, cost, extra \\ %{}) do
    line(
      Map.merge(
        %{
          "type" => "result",
          "subtype" => subtype,
          "is_error" => subtype != "success",
          "total_cost_usd" => cost
        },
        extra
      )
    )
  end

  defp can_use_tool(id) do
    line(%{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => "Bash",
        "input" => %{"command" => "ls"}
      }
    })
  end

  test "a session through its turns emits start/stop pairs with per-turn cost and error kind" do
    init = line(%{"type" => "system", "subtype" => "init", "session_id" => "s1"})

    ctl =
      start_supervised!(
        {Mock, events: [{:stdout_data, init}, {:stdout_data, result("success", 0.5)}]}
      )

    {:ok, pid} =
      Session.start_link(
        backend: {Mock, mock: ctl},
        executable: "claude",
        prompt: "one",
        timeout: 10_000
      )

    key = :sys.get_state(pid).store_key

    assert_receive {:event, [:crowd_control, :backend, :provision, :start], %{system_time: _},
                    %{store_key: ^key, backend: Mock}}

    assert_receive {:event, [:crowd_control, :backend, :provision, :stop], %{duration: _},
                    %{store_key: ^key, result: :ok}}

    assert_receive {:event, [:crowd_control, :session, :start], %{system_time: _},
                    %{store_key: ^key, backend: Mock, agent: CrowdControl.Agent.ClaudeCode}}

    assert_receive {:event, [:crowd_control, :turn, :start], _, %{store_key: ^key, turn: 1}}

    assert_receive {:event, [:crowd_control, :turn, :stop], %{duration: duration},
                    %{store_key: ^key, turn: 1} = stop},
                   2_000

    assert is_integer(duration) and duration >= 0
    assert %{cost_usd: 0.5, turn_cost_usd: 0.5, subtype: "success", error_kind: nil} = stop

    # total_cost_usd is cumulative, so the second turn costs the difference.
    :ok = Session.send_prompt(pid, "two")
    Mock.push_events(ctl, [{:stdout_data, result("success", 0.75)}])

    assert_receive {:event, [:crowd_control, :turn, :stop], _,
                    %{store_key: ^key, turn: 2} = stop},
                   2_000

    assert %{cost_usd: 0.75, turn_cost_usd: 0.25, error_kind: nil} = stop

    :ok = Session.send_prompt(pid, "three")

    Mock.push_events(ctl, [
      {:stdout_data,
       result("error_during_execution", 0.75, %{"terminal_reason" => "aborted_tools"})}
    ])

    assert_receive {:event, [:crowd_control, :turn, :stop], _,
                    %{store_key: ^key, turn: 3} = stop},
                   2_000

    assert %{subtype: "error_during_execution", error_kind: :aborted, turn_cost_usd: +0.0} = stop

    :ok = Session.stop(pid)

    assert_receive {:event, [:crowd_control, :session, :stop], %{duration: _},
                    %{store_key: ^key, status: :completed}}

    refute_received {:event, [:crowd_control, :session, :exception], _, %{store_key: ^key}}
  end

  @tag :capture_log
  test "a crashed session emits exception instead of stop" do
    Process.flag(:trap_exit, true)
    # A backend whose write raises: the session crashes in handle_call, and
    # terminate/2 runs.
    ctl = start_supervised!({Mock, events: [], fail: %{write: {:raise, "transport bug"}}})

    {:ok, pid} =
      Session.start_link(backend: {Mock, mock: ctl}, executable: "claude", timeout: 10_000)

    key = :sys.get_state(pid).store_key

    assert {{%RuntimeError{message: "transport bug"}, _stack}, _call} =
             catch_exit(Session.send_prompt(pid, "hi"))

    assert_receive {:EXIT, ^pid, {%RuntimeError{}, _stack}}, 2_000

    assert_receive {:event, [:crowd_control, :session, :exception], _,
                    %{store_key: ^key, kind: :exit, reason: {%RuntimeError{}, _}}}

    refute_received {:event, [:crowd_control, :session, :stop], _, %{store_key: ^key}}
    assert Mock.destroy_count(ctl) == 1
  end

  test "a stray message no longer crashes the session" do
    ctl = start_supervised!({Mock, events: []})

    {:ok, pid} =
      Session.start_link(backend: {Mock, mock: ctl}, executable: "claude", timeout: 10_000)

    send(pid, :unexpected)
    assert Session.get_status(pid) == :starting
    assert Mock.destroy_count(ctl) == 0

    TestHelpers.stop_session(pid)
  end

  test "a failed provision is reported by the span" do
    Process.flag(:trap_exit, true)
    ctl = start_supervised!({Mock, events: [], fail: %{provision: :quota}})

    assert {:error, :quota} =
             Session.start_link(backend: {Mock, mock: ctl}, executable: "claude", timeout: 10_000)

    assert_receive {:event, [:crowd_control, :backend, :provision, :stop], _,
                    %{backend: Mock, result: :error}}
  end

  test "every permission decision is reported once, with its source" do
    ctl = start_supervised!({Mock, events: []})

    {:ok, pid} =
      Session.start_link(
        backend: {Mock, mock: ctl},
        executable: "claude",
        timeout: 10_000,
        permission_timeout: 200,
        can_use_tool: {__MODULE__, :defer, []}
      )

    key = :sys.get_state(pid).store_key
    Mock.push_events(ctl, [{:stdout_data, can_use_tool("d-respond")}])
    TestHelpers.wait_until(fn -> match?({:ok, [_]}, Session.pending_requests(pid)) end)
    :ok = Session.respond(pid, "d-respond", {:deny, "no"})

    assert_receive {:event, [:crowd_control, :control, :decision], _,
                    %{
                      store_key: ^key,
                      request_id: "d-respond",
                      tool_name: "Bash",
                      behavior: :deny,
                      source: :respond
                    }}

    Mock.push_events(ctl, [
      {:stdout_data, can_use_tool("d-cancel")},
      {:stdout_data, line(%{"type" => "control_cancel_request", "request_id" => "d-cancel"})}
    ])

    assert_receive {:event, [:crowd_control, :control, :decision], _,
                    %{request_id: "d-cancel", behavior: :cancelled, source: :cancel}},
                   2_000

    Mock.push_events(ctl, [{:stdout_data, can_use_tool("d-timeout")}])

    assert_receive {:event, [:crowd_control, :control, :decision], _,
                    %{request_id: "d-timeout", behavior: :deny, source: :timeout}},
                   2_000

    TestHelpers.stop_session(pid)

    # A fresh Mock: the stopped session's reader still polls the old one.
    ctl = start_supervised!({Mock, events: [{:stdout_data, can_use_tool("d-callback")}]})

    {:ok, pid} =
      Session.start_link(
        backend: {Mock, mock: ctl},
        executable: "claude",
        timeout: 10_000,
        can_use_tool: {__MODULE__, :allow, []}
      )

    assert_receive {:event, [:crowd_control, :control, :decision], _,
                    %{request_id: "d-callback", behavior: :allow, source: :callback}},
                   2_000

    for id <- ~w(d-respond d-cancel d-timeout d-callback) do
      refute_received {:event, [:crowd_control, :control, :decision], _, %{request_id: ^id}}
    end

    TestHelpers.stop_session(pid)
  end

  @tag :capture_log
  test "a gate refusal and an over-cap request are reported as decisions too" do
    server = SdkMcp.tool_server("app", [%{name: "echo", call: {__MODULE__, :echo, []}}])
    ctl = start_supervised!({Mock, events: []})

    {:ok, pid} =
      Session.start_link(
        backend: {Mock, mock: ctl},
        executable: "claude",
        timeout: 10_000,
        max_pending_control: 1,
        can_use_tool: {__MODULE__, :defer, []},
        sdk_mcp_servers: %{"app" => server}
      )

    key = :sys.get_state(pid).store_key

    tool_call = %{
      "type" => "control_request",
      "request_id" => "d-gate",
      "request" => %{
        "subtype" => "mcp_message",
        "server_name" => "app",
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{}}
        }
      }
    }

    Mock.push_events(ctl, [{:stdout_data, line(tool_call)}])

    assert_receive {:event, [:crowd_control, :control, :decision], _,
                    %{
                      store_key: ^key,
                      request_id: "d-gate",
                      tool_name: "mcp__app__echo",
                      behavior: :deny,
                      source: :gate
                    }},
                   2_000

    Mock.push_events(ctl, [
      {:stdout_data, can_use_tool("d-held")},
      {:stdout_data, can_use_tool("d-cap")}
    ])

    assert_receive {:event, [:crowd_control, :control, :decision], _,
                    %{request_id: "d-cap", tool_name: "Bash", behavior: :deny, source: :cap}},
                   2_000

    refute_received {:event, [:crowd_control, :control, :decision], _, %{request_id: "d-held"}}

    TestHelpers.stop_session(pid)
  end
end
